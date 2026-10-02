require 'set'

require 'parslet'

module Parslet
  # Read-only grammar analysis. The analyzer never applies an atom to sample
  # input and does not call blocks wrapped by Parslet.dynamic.
  #
  # Dynamic atoms are treated as unknown unless the caller supplies a summary.
  # A summary uses :nullable, :consuming and :failable booleans; nil means
  # unknown. A callable summary provider receives each dynamic atom.
  module Lint
    Behavior = Struct.new(:nullable, :consuming, :failable)

    class Finding
      attr_reader :kind, :chain, :atom, :blockers

      def initialize(kind, chain, atom, blockers=[])
        @kind = kind
        @chain = chain
        @atom = atom
        @blockers = blockers
      end

      def certain?
        blockers.empty?
      end

      def severity
        certain? ? :error : :warning
      end

      def message
        case kind
        when :empty_repetition
          "repetition can repeatedly succeed without consuming input: #{atom.inspect}"
        when :unknown_repetition
          "repetition body has unknown nullability: #{atom.inspect}"
        when :nonprogress_recursion
          "recursive rule path can return to the same rule without consuming input: #{chain.join(' -> ')}"
        when :unknown_recursion
          "recursive rule path may return to the same rule without consuming input: #{chain.join(' -> ')}"
        else
          kind.to_s
        end
      end
    end

    class Result
      attr_reader :findings

      def initialize(findings)
        @findings = findings
      end

      def errors
        findings.select { |finding| finding.severity == :error }
      end

      def warnings
        findings.select { |finding| finding.severity == :warning }
      end

      def ok?
        errors.empty?
      end
    end

    Edge = Struct.new(:source, :target, :certain, :blockers)

    class Analyzer
      def initialize(dynamic_summaries={})
        @dynamic_summaries = dynamic_summaries
        @rules = {}
        @edges = []
        @repetitions = []
        @behaviors = {}
        @entry_chains = []
        @parser = nil
      end

      def analyze(atom)
        enumerate(atom, [], [])
        analyze_behaviors
        build_edges
        analyze_repetitions
        analyze_recursion

        Result.new((@repetitions + @cycles).sort_by { |finding| [finding.severity.to_s, finding.chain, finding.kind.to_s] })
      end

      private

      def enumerate(atom, stack, chain)
        case atom
        when Atoms::Entity
          enumerate_entity(atom, stack, chain)
        when Parser
          if stack.empty?
            @parser = atom
            enumerate_entity(atom.root, stack, chain)
          else
            enumerate_entity(atom.root, stack, chain)
            add_entry_chain(atom.root, chain + [atom.root.name])
          end
        when Atoms::Sequence
          atom.parslets.each do |child|
            enumerate(child, stack, chain)
          end
        when Atoms::Alternative
          atom.alternatives.each do |child|
            enumerate(child, stack, chain)
          end
        when Atoms::Repetition
          enumerate(atom.parslet, stack, chain)
          @repetitions << [atom, stack.dup] if atom.max.nil?
        when Atoms::Named, Atoms::Capture, Atoms::Ignored
          enumerate(atom.parslet, stack, chain)
        when Atoms::Lookahead
          enumerate(atom.bound_parslet, stack, chain)
        when Atoms::Scope
          enumerate(atom.block.call, stack, chain)
        when Atoms::Infix
          enumerate(atom.element, stack, chain)
          atom.operations.each do |operation, _precedence, _associativity|
            enumerate(operation, stack, chain)
          end
        when Atoms::Dynamic
          # Dynamic blocks intentionally remain opaque.
        end
      end

      def enumerate_entity(entity, stack, chain)
        name = entity.name
        target_chain = chain + [name]

        if @rules[entity.object_id].nil?
          @rules[entity.object_id] = entity
          @entry_chains << [entity, target_chain]
        end

        return if stack.include?(entity)

        enumerate(entity.block.call, stack + [entity], target_chain)
      end

      def analyze_behaviors
        pending = @rules.values
        pending.each do |entity|
          @behaviors[entity.object_id] ||= unknown_behavior
        end

        changed = true
        while changed
          changed = false
          pending.each do |entity|
            behavior = behavior_for(entity.block.call)
            unless behavior == @behaviors[entity.object_id]
              @behaviors[entity.object_id] = behavior
              changed = true
            end
          end
        end
      end

      def build_edges
        @edges = []
        processed = Set.new

        loop do
          analyze_behaviors
          @edges = []
          @rules.values.each do |entity|
            enumerate_edges(entity.block.call, [entity], [entity.name], true, true)
          end
          new_rules = @rules.values.reject { |entity| processed.include?(entity.object_id) }
          break if new_rules.empty?

          new_rules.each do |entity|
            processed << entity.object_id
          end
        end
      end

      def enumerate_edges(atom, stack, chain, reachable, recursion_enabled)
        return if reachable == false

        case atom
        when Atoms::Entity
          add_edge(stack.last, atom, reachable)
        when Parser
          add_edge(stack.last, atom.root, reachable)
        when Atoms::Sequence
          prefix = true
          atom.parslets.each do |child|
            enumerate_edges(child, stack, chain, tri_and(prefix, reachable), recursion_enabled)
            prefix = tri_and(prefix, behavior_for(child).nullable)
          end
        when Atoms::Alternative
          guard = true
          atom.alternatives.each do |child|
            enumerate_edges(child, stack, chain, tri_and(guard, reachable), recursion_enabled)
            guard = tri_and(guard, behavior_for(child).failable)
          end
        when Atoms::Repetition
          enumerate_repetition_edges(atom.parslet, stack, chain, reachable)
        when Atoms::Named, Atoms::Capture, Atoms::Ignored
          enumerate_edges(atom.parslet, stack, chain, reachable, recursion_enabled)
        when Atoms::Lookahead
          enumerate_edges(atom.bound_parslet, stack, chain, reachable, recursion_enabled)
        when Atoms::Scope
          enumerate_edges(atom.block.call, stack, chain, reachable, recursion_enabled)
        when Atoms::Infix
          enumerate_edges(atom.element, stack, chain, reachable, recursion_enabled)
          atom.operations.each do |operation, _precedence, _associativity|
            enumerate_edges(
              operation,
              stack,
              chain,
              tri_and(behavior_for(atom.element).nullable, reachable),
              recursion_enabled)
          end
        when Atoms::Dynamic
          if recursion_enabled
            zero_progress = tri_and(dynamic_behavior(atom).nullable, reachable)
            unless zero_progress == false
              dynamic_targets(atom, stack.last).each do |target|
                add_edge(stack.last, target, zero_progress)
                add_entry_chain(target, chain + [target.name])
              end
            end
          end
        end
      end

      def enumerate_repetition_edges(atom, stack, chain, reachable)
        if atom.is_a?(Atoms::Dynamic)
          summary = dynamic_summary(atom)
          references = summary && (summary[:rules] || summary[:references])

          if references
            zero_progress = tri_and(dynamic_behavior(atom).nullable, reachable)
            Array(references).each do |reference|
              target = resolve_dynamic_reference(reference)
              if target
                add_edge(stack.last, target, zero_progress)
                add_entry_chain(target, chain + [target.name])
              end
            end
          end
        else
          enumerate_edges(atom, stack, chain, reachable, false)
        end
      end

      def dynamic_targets(dynamic, current_rule)
        summary = dynamic_summary(dynamic)
        references = summary && (summary[:rules] || summary[:references])

        if references.nil?
          [current_rule]
        else
          Array(references).map { |reference| resolve_dynamic_reference(reference) }.compact
        end
      end

      def resolve_dynamic_reference(reference)
        if reference.is_a?(Atoms::Entity)
          reference
        elsif reference.is_a?(Parser)
          reference.root
        else
          @rules.values.find { |rule| rule.name.to_sym == reference.to_sym } ||
            named_rule(reference)
        end
      end

      def named_rule(name)
        return unless @parser && @parser.respond_to?(name, true)

        entity = begin
          @parser.send(name)
        rescue NoMethodError
          return
        end
        return unless entity.is_a?(Atoms::Entity)
        existing = @rules.values.find { |rule| rule.name.to_sym == name.to_sym }
        return existing if existing

        @rules[entity.object_id] = entity
        enumerate(entity.block.call, [entity], [name])
        entity
      end

      def add_entry_chain(entity, chain)
        @entry_chains << [entity, chain] unless @entry_chains.any? do |entry, existing_chain|
          entry.equal?(entity) && existing_chain == chain
        end
      end

      def add_edge(source, target, reachable)
        @edges << Edge.new(
          source,
          target,
          reachable == true,
          reachable.nil? ? [target] : [])
      end

      def analyze_repetitions
        findings = []

        @repetitions.each do |repetition, stack|
          child_behavior = behavior_for(repetition.parslet)
          chain = stack.map(&:name) + immediate_entity_path(repetition.parslet)

          if child_behavior.nullable == true
            findings << Finding.new(:empty_repetition, chain, repetition)
          elsif child_behavior.nullable.nil?
            blockers = unknown_blockers(repetition.parslet).uniq
            findings << Finding.new(:unknown_repetition, chain, repetition, blockers)
          end
        end

        @repetitions = findings
      end

      def analyze_recursion
        @cycles = []
        seen = Set.new

        @entry_chains.each do |entry, entry_chain|
          find_cycles(entry, [entry], [], entry_chain, seen)
        end
      end

      def find_cycles(name, stack, edge_stack, entry_chain, seen)
        edges_for(name, stack, entry_chain).each do |edge|
          if stack.include?(edge.target)
            start = stack.index(edge.target)
            cycle_edges = edge_stack.drop(start) + [edge]
            key = cycle_key(cycle_edges)
            next if seen.include?(key)
            seen << key

            certain = cycle_edges.all?(&:certain)
            blockers = cycle_edges.flat_map(&:blockers).uniq
            kind = certain ? :nonprogress_recursion : :unknown_recursion
            cycle_chain = entry_chain[0...-1] + stack + [edge.target]
            cycle_chain = cycle_chain.map { |rule| rule.name.to_s.to_sym }
            @cycles << Finding.new(kind, cycle_chain, nil, blockers)
          else
            find_cycles(edge.target, stack + [edge.target], edge_stack + [edge], entry_chain, seen)
          end
        end
      end

      def cycle_key(edges)
        names = edges.map { |edge| edge.target.object_id }
        start = names.index(names.min)
        rotated_nodes = names.rotate(start)
        rotated_nodes.zip(rotated_nodes.rotate).map { |source, target| [source, target] }
      end

      def edges_for(name, stack, entry_chain)
        @edges.select do |edge|
          edge.source.equal?(name)
        end.uniq { |edge| [edge.target.object_id, edge.certain, edge.blockers.map(&:object_id)] }
      end

      def immediate_entity_path(atom)
        case atom
        when Atoms::Entity
          [atom.name]
        when Parser
          [atom.root.name]
        when Atoms::Named, Atoms::Capture, Atoms::Ignored
          immediate_entity_path(atom.parslet)
        when Atoms::Repetition
          immediate_entity_path(atom.parslet)
        else
          []
        end
      end

      def unknown_blockers(atom)
        case atom
        when Atoms::Dynamic
          [dynamic_summary(atom).nil? ? atom : nil].compact
        when Atoms::Entity, Parser
          behavior_for(atom).nullable.nil? ? [atom] : []
        when Atoms::Sequence
          atom.parslets.flat_map { |child| unknown_blockers(child) }
        when Atoms::Alternative
          atom.alternatives.flat_map { |child| unknown_blockers(child) }
        when Atoms::Repetition
          unknown_blockers(atom.parslet)
        when Atoms::Named, Atoms::Capture, Atoms::Ignored, Atoms::Lookahead
          unknown_blockers(child_atom(atom))
        when Atoms::Scope
          unknown_blockers(atom.block.call)
        when Atoms::Infix
          unknown_blockers(atom.element) +
            atom.operations.flat_map { |operation, _, _| unknown_blockers(operation) }
        else
          []
        end
      end

      def child_atom(atom)
        atom.is_a?(Atoms::Lookahead) ? atom.bound_parslet : atom.parslet
      end

      def behavior_for(atom)
        case atom
        when Atoms::Str
          empty = atom.str.empty?
          Behavior.new(empty, !empty, !empty)
        when Atoms::Re
          Behavior.new(false, true, true)
        when Atoms::Entity
          @behaviors[atom.object_id] || unknown_behavior
        when Parser
          behavior_for(atom.root)
        when Atoms::Sequence
          sequence_behavior(atom.parslets)
        when Atoms::Alternative
          alternative_behavior(atom.alternatives)
        when Atoms::Repetition
          repetition_behavior(atom)
        when Atoms::Named, Atoms::Capture, Atoms::Ignored
          behavior_for(atom.parslet)
        when Atoms::Lookahead
          lookahead_behavior(atom)
        when Atoms::Scope
          behavior_for(atom.block.call)
        when Atoms::Infix
          behavior_for(atom.element)
        when Atoms::Dynamic
          dynamic_behavior(atom)
        else
          unknown_behavior
        end
      end

      def sequence_behavior(children)
        nullable = three_and(children.map { |child| behavior_for(child).nullable })
        consuming = false
        prefix_nullable = true

        children.each do |child|
          behavior = behavior_for(child)
          consuming = three_or([
            consuming,
            tri_and(prefix_nullable, behavior.consuming)])
          prefix_nullable = three_and([prefix_nullable, behavior.nullable])
        end

        failable = three_or(children.map { |child| behavior_for(child).failable })
        Behavior.new(nullable, consuming, failable)
      end

      def alternative_behavior(alternatives)
        behaviors = alternatives.map { |child| behavior_for(child) }
        Behavior.new(
          three_or(behaviors.map(&:nullable)),
          three_or(behaviors.map(&:consuming)),
          three_and(behaviors.map(&:failable)))
      end

      def repetition_behavior(repetition)
        body = behavior_for(repetition.parslet)
        nullable = repetition.min == 0 ? true : body.nullable
        failable = repetition.min == 0 ? false : body.failable
        Behavior.new(nullable, body.consuming, failable)
      end

      def lookahead_behavior(lookahead)
        body = behavior_for(lookahead.bound_parslet)
        can_succeed = three_or([body.nullable, body.consuming])

        if lookahead.positive
          Behavior.new(can_succeed, false, body.failable)
        else
          Behavior.new(body.failable, false, can_succeed)
        end
      end

      def dynamic_behavior(dynamic)
        summary = dynamic_summary(dynamic)
        return unknown_behavior if summary.nil?

        Behavior.new(
          value_or_nil(summary[:nullable]),
          value_or_nil(summary[:consuming] || summary[:consumes]),
          value_or_nil(summary[:failable]))
      end

      def dynamic_summary(dynamic)
        direct_summary = @dynamic_summaries[dynamic] unless @dynamic_summaries.respond_to?(:call)
        direct_summary ||= @dynamic_summaries[dynamic.object_id] unless @dynamic_summaries.respond_to?(:call)

        block_summary = @dynamic_summaries[dynamic.block] unless @dynamic_summaries.respond_to?(:call)
        block_summary ||= @dynamic_summaries[dynamic.block.object_id] unless @dynamic_summaries.respond_to?(:call)

        summary = direct_summary || block_summary

        if summary.nil? && @dynamic_summaries.respond_to?(:call)
          summary = @dynamic_summaries.call(dynamic)
        end

        summary
      end

      def value_or_nil(value)
        value == true || value == false ? value : nil
      end

      def unknown_behavior
        Behavior.new(nil, nil, nil)
      end

      def three_and(values)
        return true if values.empty?
        return false if values.include?(false)
        return nil if values.include?(nil)
        true
      end

      def tri_and(left, right)
        three_and([left, right])
      end

      def three_or(values)
        return false if values.empty?
        return true if values.include?(true)
        return nil if values.include?(nil)
        false
      end
    end

    # Analyzes an atom or parser without parsing sample input. Dynamic atom
    # summaries may be a hash keyed by the atom/block/object id or a proc.
    def self.analyze(atom, dynamic_summaries={})
      Analyzer.new(dynamic_summaries).analyze(atom)
    end
  end

  # @see Lint.analyze
  def self.lint(atom, dynamic_summaries={})
    Lint.analyze(atom, dynamic_summaries)
  end

  class Parser
    def lint(dynamic_summaries={})
      Parslet.lint(self, dynamic_summaries)
    end
  end
end
