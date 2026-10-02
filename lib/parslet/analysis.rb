# Static, read-only analysis of parslet grammars.
#
# The checker answers two questions without ever parsing a single character
# of input:
#
# * Can a repetition body succeed without consuming input? Unbounded
#   repetitions (#repeat with no upper bound) loop forever in that case:
#
#     str('').repeat            # hangs at parse time
#     str('a').maybe.repeat     # hangs as well
#
# * Can a rule be re-entered before any input is consumed? Such left
#   recursion (direct or mutual) never makes progress:
#
#     rule(:a) { a >> str('b') | str('c') }
#
# Matching the empty string is NOT an error by itself. Optional branches
# (#maybe) and empty alternatives are perfectly fine as long as nothing
# repeats them without bound and no recursion passes through them.
#
# Dynamic atoms (Parslet::Atoms::Dynamic) cannot be analysed statically and
# are reported as unknown. You can teach the checker about them by passing
# summaries:
#
#   report = Parslet::Analysis.check(parser, summaries: {
#     dynamic: { nullable: false },    # default for all dynamic atoms
#     some_atom => { nullable: true }, # a specific atom instance
#     thing: { nullable: false },      # a named atom, str('x').as(:thing)
#   })
#
# The analysis is read-only: it walks the atom graph and evaluates rule
# bodies (which is grammar construction, not parsing), but never applies an
# atom to input.
#
# Example:
#
#   report = Parslet::Analysis.check(MyParser.new)
#   report.ok?        # => false
#   puts report       # findings with rule chains from the entry rule
#
module Parslet::Analysis
  # Runs all checks on +entry+, which may be a Parslet::Parser instance or
  # any parslet atom. Returns an Analysis::Report.
  #
  def self.check(entry, summaries: {})
    Checker.new(summaries).check(entry)
  end

  # A single problem (or suspected problem) found by the checker.
  #
  class Finding
    # :empty_repetition, :empty_infix or :left_recursion
    attr_reader :kind
    # :definite (provably broken) or :unknown (depends on dynamic atoms)
    attr_reader :certainty
    # Rule names from the entry rule to the risk location.
    attr_reader :chain
    # The atom at the risk location (nil for left recursion).
    attr_reader :atom
    attr_reader :message

    def initialize(kind, certainty, chain, atom, message)
      @kind = kind
      @certainty = certainty
      @chain = chain
      @atom = atom
      @message = message
    end

    def error?
      certainty == :definite
    end

    def unknown?
      certainty == :unknown
    end

    def to_s
      location = chain.empty? ? '(root)' : chain.map(&:to_s).join(' -> ')
      "[#{kind}] #{location}: #{message}"
    end
  end

  # The result of an analysis run.
  #
  class Report
    include Enumerable

    attr_reader :findings

    def initialize(findings)
      @findings = findings
    end

    def each(&block)
      findings.each(&block)
    end

    # True when no definite problem was found. Unknowns (dynamic atoms the
    # checker could not reason about) do not count as errors.
    #
    def ok?
      findings.none?(&:error?)
    end

    def errors
      findings.select(&:error?)
    end

    def unknowns
      findings.select(&:unknown?)
    end

    def empty?
      findings.empty?
    end

    def to_s
      return 'Parslet::Analysis: no issues found.' if findings.empty?

      header = "Parslet::Analysis: #{errors.size} error(s), " +
        "#{unknowns.size} unknown(s):"
      ([header] + findings.map { |f| "  #{f}" }).join("\n")
    end
  end

  # Walks the atom graph of a grammar and computes nullability and
  # call-graph information used by the checks. Nothing here ever applies an
  # atom to input; only grammar construction code (rule blocks, scope
  # blocks) is evaluated.
  #
  class Checker
    Atoms = Parslet::Atoms

    def initialize(summaries)
      @atom_summaries = {}.compare_by_identity
      @name_summaries = {}
      @dynamic_summary = nil

      (summaries || {}).each do |key, value|
        case key
        when :dynamic
          @dynamic_summary = value
        when Symbol
          @name_summaries[key] = value
        else
          @atom_summaries[key] = value
        end
      end

      @scope_cache = {}.compare_by_identity
    end

    def check(entry)
      @entry = entry
      @entry_atom = entry.is_a?(Parslet::Parser) ? entry.root : entry

      # Collect all entities (rules) reachable from the entry atom.
      @entities = []
      @entity_set = {}.compare_by_identity
      walk(@entry_atom, []) do |atom, _chain|
        register_entity(atom) if atom.is_a?(Atoms::Entity)
      end

      compute_nullability
      compute_calls

      findings = []
      findings.concat(repetition_findings)
      findings.concat(recursion_findings)
      Report.new(findings)
    end

    private

    # --- graph walking ---------------------------------------------------

    def register_entity(entity)
      return if @entity_set.key?(entity)

      @entity_set[entity] = true
      @entities << entity
    end

    # Visits every atom of the grammar exactly once, carrying the chain of
    # rule names from the entry down to the atom.
    #
    def walk(atom, chain, seen = {}.compare_by_identity, &block)
      return if atom.nil? || seen.key?(atom)

      seen[atom] = true
      yield atom, chain

      case atom
      when Atoms::Entity
        walk(atom.parslet, chain + [atom.name], seen, &block)
      when Atoms::Sequence
        atom.parslets.each { |p| walk(p, chain, seen, &block) }
      when Atoms::Alternative
        atom.alternatives.each { |p| walk(p, chain, seen, &block) }
      when Atoms::Repetition
        walk(atom.parslet, chain, seen, &block)
      when Atoms::Named, Atoms::Ignored, Atoms::Capture
        walk(atom.parslet, chain, seen, &block)
      when Atoms::Lookahead
        walk(atom.bound_parslet, chain, seen, &block)
      when Atoms::Scope
        walk(scope_parslet(atom), chain, seen, &block)
      when Atoms::Infix
        walk(atom.element, chain, seen, &block)
        atom.operations.each { |op, _, _| walk(op, chain, seen, &block) }
      when Parslet::Parser
        walk(atom.root, chain, seen, &block)
      end
    end

    def scope_parslet(scope)
      return @scope_cache[scope] if @scope_cache.key?(scope)

      @scope_cache[scope] =
        begin
          scope.block.call
        rescue StandardError, NotImplementedError
          nil
        end
    end

    def summary_for(atom)
      @atom_summaries[atom] ||
        (atom.is_a?(Atoms::Dynamic) ? @dynamic_summary : nil)
    end

    # --- nullability -----------------------------------------------------
    #
    # Two fixpoints are computed for every rule:
    #
    # * :def  - definitely nullable (unknown constructs count as false)
    # * :poss - possibly nullable  (unknown constructs count as true)
    #
    # Together they form a tri-state per atom: true / false / :unknown.
    #
    def compute_nullability
      @nullable = {
        def: {}.compare_by_identity,
        poss: {}.compare_by_identity
      }

      # :def starts at false and only grows; :poss starts at true and only
      # shrinks. Both converge in at most #entities iterations.
      [@entities.size + 1, 1].max.times do
        changed = false
        @entities.each do |entity|
          d = nullable(entity.parslet, :def, {}.compare_by_identity)
          p = nullable(entity.parslet, :poss, {}.compare_by_identity)
          changed = true if @nullable[:def][entity] != d
          changed = true if @nullable[:poss].fetch(entity, true) != p
          @nullable[:def][entity] = d
          @nullable[:poss][entity] = p
        end
        break unless changed
      end
    end

    def entity_nullable(entity, mode)
      if mode == :def
        @nullable[:def][entity] || false
      else
        @nullable[:poss].fetch(entity, true)
      end
    end

    # Boolean nullability in one of the two modes. Unknown atom types and
    # unsummarised dynamic atoms fall back to the mode default.
    #
    def nullable(atom, mode, memo)
      return memo[atom] if memo.key?(atom)

      result =
        case atom
        when Atoms::Str
          atom.str.empty?
        when Atoms::Re
          false
        when Atoms::Lookahead
          true
        when Atoms::Repetition
          atom.min == 0 || nullable(atom.parslet, mode, memo)
        when Atoms::Sequence
          atom.parslets.all? { |p| nullable(p, mode, memo) }
        when Atoms::Alternative
          atom.alternatives.any? { |a| nullable(a, mode, memo) }
        when Atoms::Named
          name_summary = @name_summaries[atom.name]
          if name_summary && name_summary.key?(:nullable)
            name_summary[:nullable]
          else
            nullable(atom.parslet, mode, memo)
          end
        when Atoms::Ignored, Atoms::Capture
          nullable(atom.parslet, mode, memo)
        when Atoms::Entity
          entity_nullable(atom, mode)
        when Atoms::Dynamic
          summary = summary_for(atom)
          if summary && summary.key?(:nullable)
            summary[:nullable]
          else
            mode == :poss
          end
        when Atoms::Scope
          inner = scope_parslet(atom)
          inner ? nullable(inner, mode, memo) : (mode == :poss)
        when Atoms::Infix
          nullable(atom.element, mode, memo)
        when Parslet::Parser
          nullable(atom.root, mode, memo)
        else
          mode == :poss
        end

      memo[atom] = result
    end

    # Tri-state nullability: true, false or :unknown.
    #
    def nullability(atom)
      return true if nullable(atom, :def, {}.compare_by_identity)

      nullable(atom, :poss, {}.compare_by_identity) ? :unknown : false
    end

    # --- calls-before-consumption relation -------------------------------
    #
    # calls(atom) is the set of rules that can be entered from +atom+
    # before any input has been consumed. In :def mode only definitely
    # nullable prefixes are crossed; :poss mode also crosses unknown ones,
    # yielding a superset of edges.
    #
    def compute_calls
      @calls_def = {}.compare_by_identity
      @calls_poss = {}.compare_by_identity
      @entities.each do |entity|
        @calls_def[entity] = calls(entity.parslet, :def)
        @calls_poss[entity] = calls(entity.parslet, :poss)
      end
      @entry_calls_poss = calls(@entry_atom, :poss)
    end

    def calls(atom, mode, set = {}.compare_by_identity)
      case atom
      when Atoms::Entity
        set[atom] = true
      when Atoms::Sequence
        atom.parslets.each do |p|
          calls(p, mode, set)
          break unless nullable(p, mode, {}.compare_by_identity)
        end
      when Atoms::Alternative
        atom.alternatives.each { |a| calls(a, mode, set) }
      when Atoms::Repetition
        calls(atom.parslet, mode, set)
      when Atoms::Named, Atoms::Ignored, Atoms::Capture
        calls(atom.parslet, mode, set)
      when Atoms::Lookahead
        # Lookahead applies its bound atom at the current position.
        calls(atom.bound_parslet, mode, set)
      when Atoms::Scope
        inner = scope_parslet(atom)
        calls(inner, mode, set) if inner
      when Atoms::Infix
        calls(atom.element, mode, set)
      when Parslet::Parser
        calls(atom.root, mode, set)
      end
      set
    end

    # --- checks ------------------------------------------------------------

    def repetition_findings
      findings = []

      walk(@entry_atom, []) do |atom, chain|
        case atom
        when Atoms::Repetition
          # Only unbounded repetitions can loop forever; bounded ones
          # (including #maybe) always terminate.
          next unless atom.max.nil?

          case nullability(atom.parslet)
          when true
            findings << Finding.new(
              :empty_repetition, :definite, chain, atom,
              'repetition body ' + atom.parslet.inspect + ' can succeed ' \
              'without consuming input; this unbounded repetition can ' \
              'loop forever')
          when :unknown
            findings << Finding.new(
              :empty_repetition, :unknown, chain, atom,
              'repetition body ' + atom.parslet.inspect + ' contains a ' \
              'dynamic atom or unknown construct that might match the ' \
              'empty string; pass a summary to Analysis.check(..., ' \
              'summaries: ...) to resolve this')
          end
        when Atoms::Infix
          finding = infix_finding(atom, chain)
          findings << finding if finding
        end
      end

      findings
    end

    # An infix expression loops forever when both its element and one of
    # its operators can match the empty string.
    #
    def infix_finding(atom, chain)
      element_state = nullability(atom.element)
      return nil if element_state == false

      op_states = atom.operations.map { |op, _, _| nullability(op) }
      worst_op =
        if op_states.include?(true)
          true
        elsif op_states.include?(:unknown)
          :unknown
        end
      return nil if worst_op.nil?

      if worst_op == true && element_state == true
        Finding.new(
          :empty_infix, :definite, chain, atom,
          'both the element and an operator of this infix expression can ' \
          'match the empty string; precedence climbing can loop forever')
      else
        Finding.new(
          :empty_infix, :unknown, chain, atom,
          'the element and an operator of this infix expression might ' \
          'both match the empty string (dynamic atom or unknown ' \
          'construct involved); pass a summary to Analysis.check(..., ' \
          'summaries: ...) to resolve this')
      end
    end

    def recursion_findings
      findings = []

      definite_sccs = cyclic_components(@calls_def)
      possible_sccs = cyclic_components(@calls_poss)
      definite_keys = definite_sccs.map { |scc| component_key(scc) }

      definite_sccs.each do |scc|
        findings << recursion_finding(scc, @calls_def, :definite)
      end
      possible_sccs.each do |scc|
        next if definite_keys.include?(component_key(scc))

        findings << recursion_finding(scc, @calls_poss, :unknown)
      end

      findings
    end

    def recursion_finding(scc, graph, certainty)
      cycle = cycle_order(scc, graph)

      # Prepend the rule chain from the entry to the cycle, if the cycle
      # is reachable through calls-before-consumption edges.
      path = path_to(scc, @entry_calls_poss.keys, @calls_poss) || []
      if path.any? && (idx = cycle[0..-2].index(path.last))
        nodes = cycle[0..-2]
        rotated = nodes[idx..-1] + nodes[0...idx]
        cycle = rotated + [rotated.first]
        chain = (path[0..-2] + cycle).map(&:name)
      else
        chain = cycle.map(&:name)
      end

      description = chain.join(' -> ')
      message =
        if certainty == :definite
          'rule(s) can be re-entered before any input is consumed (' \
          "#{description}); this left recursion can loop forever"
        else
          'rule(s) might be re-entered before any input is consumed (' \
          "#{description}); a dynamic atom or unknown construct on this " \
          'path keeps the analysis from deciding - pass a summary to ' \
          'Analysis.check(..., summaries: ...) to resolve this'
        end

      Finding.new(:left_recursion, certainty, chain, nil, message)
    end

    # --- graph algorithms --------------------------------------------------

    def component_key(scc)
      scc.map(&:object_id).sort
    end

    # All strongly connected components of the graph that form a cycle,
    # i.e. have more than one member or a self loop.
    #
    def cyclic_components(graph)
      strongly_connected_components(graph).select do |component|
        component.size > 1 ||
          (graph[component.first] || {}).key?(component.first)
      end
    end

    # Tarjan's algorithm. Graph maps nodes to hashes whose keys are the
    # successors.
    #
    def strongly_connected_components(graph)
      @tarjan_index = 0
      @tarjan_indices = {}.compare_by_identity
      @tarjan_lowlink = {}.compare_by_identity
      @tarjan_stack = []
      @tarjan_on_stack = {}.compare_by_identity
      components = []

      graph.each_key do |node|
        next if @tarjan_indices.key?(node)

        strong_connect(node, graph, components)
      end

      components
    end

    def strong_connect(node, graph, components)
      @tarjan_indices[node] = @tarjan_index
      @tarjan_lowlink[node] = @tarjan_index
      @tarjan_index += 1
      @tarjan_stack.push(node)
      @tarjan_on_stack[node] = true

      (graph[node] || {}).each_key do |succ|
        if !@tarjan_indices.key?(succ)
          strong_connect(succ, graph, components)
          @tarjan_lowlink[node] =
            [@tarjan_lowlink[node], @tarjan_lowlink[succ]].min
        elsif @tarjan_on_stack[succ]
          @tarjan_lowlink[node] =
            [@tarjan_lowlink[node], @tarjan_indices[succ]].min
        end
      end

      return unless @tarjan_lowlink[node] == @tarjan_indices[node]

      component = []
      loop do
        member = @tarjan_stack.pop
        @tarjan_on_stack.delete(member)
        component << member
        break if member.equal?(node)
      end
      components << component
    end

    # Orders the members of a cyclic component into a cycle, returning to
    # the starting node. Used for display only.
    #
    def cycle_order(scc, graph)
      start = scc.first
      return [start, start] if scc.size == 1

      order = [start]
      current = start
      scc.size.times do
        nxt = (graph[current].keys & scc).first
        break unless nxt

        order << nxt
        break if nxt.equal?(start)

        current = nxt
      end
      order
    end

    # Breadth-first search from +starts+ to any node in +targets+ over
    # +graph+. Returns the path (including the target) or nil.
    #
    def path_to(targets, starts, graph)
      previous = {}.compare_by_identity
      queue = []
      starts.each do |start|
        previous[start] = nil
        queue << start
      end

      until queue.empty?
        current = queue.shift

        if targets.include?(current)
          path = [current]
          path.unshift(previous[path.first]) while previous[path.first]
          return path
        end

        (graph[current] || {}).each_key do |succ|
          next if previous.key?(succ)

          previous[succ] = current
          queue << succ
        end
      end

      nil
    end
  end
end
