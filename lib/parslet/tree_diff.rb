# Tree comparison for parse output.
#
# Parslet produces ordered trees (see Parslet::Parser#parse). Comparing two
# such parses asks: what is the cheapest sequence of node edits that turns
# the first tree into the second? This file answers that question with the
# exact ordered-tree edit distance (the classic forest dynamic program) and
# returns the minimum-cost edit script alongside the optimum.
#
# Reference: Zhang & Shasha (1989), "Simple Fast Algorithms for the Editing
# Distance Between Trees and Related Problems". The recurrence used here is
# the standard forest edit distance, evaluated directly (without keyroot
# compression) so that the backtrace is easy to audit.
#
#   differ = Parslet::TreeDiff::Differ.new
#   result = differ.diff(source_tree, target_tree)
#   result.distance   # optimal edit cost
#   result.operations # replayable [:delete, :insert, :replace] script
    #   result.replay # => a tree structurally equal to the target
#
# == Edit operations
#
# * delete removes a node and *promotes* its children into the node's own
#   position in the parent's child list. Children are never deleted
#   implicitly: every removed node pays its own delete. Deleting the last
#   remaining root leaves an empty intermediate forest.
# * insert adds a node. The replay assembler attaches the node's target
#   children (survivors and previously inserted subtrees) in one step, so
#   the basic alphabet stays the three unit edits while replay still yields
#   the exact target tree.
# * replace changes the label/value of one matched node; children stay.
#
# A move is deliberately not a basic edit. See Result#operations_with_moves
# for explicitly heuristic post-processing that never changes the proven
# optimum.
#
require 'set'

module Parslet
  module TreeDiff
    # An ordered, labelled node. +label+ is the role/tag (the hash key in
    # parslet output), +value+ the payload (a Slice, String, ...), +children+
    # the ordered child nodes.
    Node = Struct.new(:label, :value, :children) do
      def initialize(label=nil, value=nil, children=nil)
        super(label, value, children || [])
      end

      def leaf?
        children.empty?
      end
    end

    # One edit step. +kind+ is :delete, :insert, :replace or :move. Node ids
    # are 1-based postorder positions within their tree; 0 marks the top of
    # the forest. +children_count+ records how many target children an
    # insert assembles (informational; the replayer rebuilds them by id).
    Edit = Struct.new(:kind, :source_id, :target_id, :parent_target_id,
                      :index, :label, :value, :children_count,
                      keyword_init: true)

    # Postorder layout of one tree. Indices run 1..#size; the subtree rooted
    # at +i+ occupies leftmost[i]..i.
    class IndexedTree
      attr_reader :node, :leftmost, :parent, :children, :size, :root,
                  :preorder_rank

      def initialize(root, single_cost)
        @root = root
        @single_cost = single_cost

        # Pass 1: preorder numbering gives every node a stable handle and
        # lets children know their parent's handle.
        @pre_node = [nil]
        @pre_children = [nil]
        @pre_parent = [0]
        enumerate_preorder(root, 0)
        @size = @pre_node.length - 1

        # Pass 2: postorder layout derived from the preorder tree.
        @node = [nil]
        @leftmost = [0]
        @parent = [0]
        @children = [nil]
        @prefix = [0.0]
        @preorder_rank = [0]
        @post_of_pre = [0] * (@size + 1)
        @pre_of_post = [0] * (@size + 1)
        @next_post = 1
        lay_out_postorder(1)
        (1..@size).each do |post|
          pre = @pre_of_post[post]
          parent_pre = @pre_parent[pre]
          @parent[post] = parent_pre == 0 ? 0 : @post_of_pre[parent_pre]
        end
        @id_of = {}
        (1..@size).each do |pre|
          @id_of[@pre_node[pre].object_id] = @post_of_pre[pre]
        end
      end

      def prefix_cost(i)
        @prefix[i]
      end

      def subtree_indices(i)
        (leftmost[i]..i).to_a
      end

      def id_of(node)
        @id_of[node.object_id]
      end

      def children_of(i)
        @children[i]
      end

      private

      def enumerate_preorder(node, parent_pre)
        pre = @pre_node.length
        @pre_node << node
        @pre_parent << parent_pre
        @pre_children << []
        node.children.each do |child|
          child_pre = enumerate_preorder(child, pre)
          @pre_children[pre] << child_pre
        end
        pre
      end

      def lay_out_postorder(pre)
        child_posts = @pre_children[pre].map { |child| lay_out_postorder(child) }
        post = @next_post
        @next_post += 1
        @node << @pre_node[pre]
        @parent << 0
        @children << child_posts
        @leftmost << (child_posts.empty? ? post : @leftmost[child_posts.first])
        @prefix << @prefix.last + @single_cost.call(@pre_node[pre])
        @preorder_rank << pre
        @post_of_pre[pre] = post
        @pre_of_post[post] = pre
        post
      end

    end

    # Computes exact ordered-tree edit distances and the replayable script.
    #
    # Costs are supplied by the caller. Each cost is either a constant or a
    # callable: +delete_cost+ and +insert_cost+ receive a Node, while
    # +replace_cost+ receives the matched source and target Nodes. Costs
    # must be non-negative numbers. The default replace cost is 0 for equal
    # label and value, 1 otherwise.
    #
    class Differ
      attr_reader :delete_cost, :insert_cost, :replace_cost, :move_cost

      def initialize(delete_cost: 1, insert_cost: 1, replace_cost: nil,
                     move_cost: 1)
        @delete_cost = as_cost(delete_cost)
        @insert_cost = as_cost(insert_cost)
        @replace_cost = replace_cost || method(:default_replace_cost)
        @move_cost = move_cost
      end

      # @return [Result]
      #
      def diff(source, target)
        source = build(source)
        target = build(target)
        indexed_source = IndexedTree.new(source, @delete_cost)
        indexed_target = IndexedTree.new(target, @insert_cost)

        table = {}
        fill(table, indexed_source, indexed_target, 0, indexed_source.size,
             0, indexed_target.size)

        trace = Trace.new
        backtrack(table, indexed_source, indexed_target, 0,
                  indexed_source.size, 0, indexed_target.size, trace)

        Result.new(self, indexed_source, indexed_target, trace,
                   table[[0, indexed_source.size, 0, indexed_target.size]])
      end

      # Coerces user trees into a Node. Accepted forms:
      #
      # * Parslet::TreeDiff::Node (returned unchanged)
      # * one-element hashes +{label=>payload}+ as produced by parslet, with
      #   a scalar payload or an array of child nodes
      # * explicit tuples +[label, value]+ or +[label, value, children]+
      # * plain scalar leaves
      #
      def build(tree)
        case tree
        when Node
          tree
        when Hash
          build_hash(tree)
        when Array
          build_array(tree)
        else
          Node.new(nil, tree, [])
        end
      end

      # Coerces raw parslet parse output. A bare array is treated as the
      # ordered children of an anonymous root (parslet encodes repetitions
      # as arrays).
      #
      def build_parslet(tree)
        return Node.new(nil, nil, []) if tree.nil?
        if tree.is_a?(Array)
          Node.new(nil, nil, tree.map { |child| build(child) })
        else
          build(tree)
        end
      end

      # Forest distance F(a,i,b,j) for source interval (a..i] and target
      # interval (b..j]; both intervals only ever span complete top-level
      # roots (boundaries lie on subtree borders, see the recursion).
      #
      def fill(table, s, t, a, i, b, j)
        key = [a, i, b, j]
        return table[key] if table.key?(key)

        value =
          if a >= i && b >= j
            0.0
          elsif a >= i
            t.prefix_cost(j) - t.prefix_cost(b)
          elsif b >= j
            s.prefix_cost(i) - s.prefix_cost(a)
          else
            nil
          end
        return table[key] = value unless value.nil?

        il = s.leftmost[i]
        jl = t.leftmost[j]

        choices = {
          delete: @delete_cost.call(s.node[i]) +
                  fill(table, s, t, a, i - 1, b, j),
          insert: @insert_cost.call(t.node[j]) +
                  fill(table, s, t, a, i, b, j - 1),
          match: @replace_cost.call(s.node[i], t.node[j]) +
                 fill(table, s, t, il - 1, i - 1, jl - 1, j - 1) +
                 fill(table, s, t, a, il - 1, b, jl - 1)
        }

        kind, best = choices.min_by { |_name, cost| cost }
        table[key] = best
        table[key + [:choice]] = kind
        best
      end

      def backtrack(table, s, t, a, i, b, j, trace)
        return if a >= i && b >= j

        if a >= i
          (b + 1..j).each { |k| trace.inserts << k }
          return
        end
        if b >= j
          (a + 1..i).each { |k| trace.deletes << k }
          return
        end

        case table[[a, i, b, j, :choice]]
        when :delete
          trace.deletes << i
          backtrack(table, s, t, a, i - 1, b, j, trace)
        when :insert
          trace.inserts << j
          backtrack(table, s, t, a, i, b, j - 1, trace)
        else
          trace.matches << [i, j]
          il, jl = s.leftmost[i], t.leftmost[j]
          backtrack(table, s, t, il - 1, i - 1, jl - 1, j - 1, trace)
          backtrack(table, s, t, a, il - 1, b, jl - 1, trace)
        end
      end

      private

      def as_cost(cost)
        return cost if cost.respond_to?(:call)
        value = cost.to_f
        ->(_node) { value }
      end

      def default_replace_cost(source_node, target_node)
        source_node.label == target_node.label &&
          source_node.value == target_node.value ? 0.0 : 1.0
      end

      def tag?(object)
        object.is_a?(Symbol) || object.is_a?(String)
      end

      def nodeish?(object)
        object.is_a?(Node) || object.is_a?(Hash) ||
          (object.is_a?(Array) && !object.empty? && tag?(object.first))
      end

      def tagged_array?(array)
        array.size == 2 && tag?(array.first) &&
          array.last.is_a?(Array) && array.last.all? { |e| nodeish?(e) }
      end

      def build_hash(hash)
        if hash.size == 1 && !hash.key?(:label)
          label, payload = hash.first
          Node.new(label, nil, tag_payload_children(payload))
        else
          Node.new(hash[:label], hash[:value],
                   Array(hash[:children]).map { |child| build(child) })
        end
      end

      def build_array(array)
        if tagged_array?(array)
          label, payload = array
          Node.new(label, nil, payload.map { |child| build(child) })
        elsif array.size.between?(2, 3) && tag?(array.first)
          label, value = array
          children = array.size == 3 ? Array(array[2]) : []
          Node.new(label, value, children.map { |child| build(child) })
        else
          raise ArgumentError,
            "cannot interpret #{array.inspect} as a tree; use " \
            "Parslet::TreeDiff::Node for unambiguous trees"
        end
      end

      def tag_payload_children(payload)
        case payload
        when Array
          payload.map { |child| build(child) }
        when nil
          []
        else
          [Node.new(nil, payload, [])]
        end
      end
    end

    # @api private
    # Raw backtrace result: sets of source ids (deletes), target ids
    # (inserts) and (source id, target id) matches.
    class Trace
      attr_reader :deletes, :inserts, :matches

      def initialize
        @deletes = []
        @inserts = []
        @matches = []
      end
    end

    # Outcome of Differ#diff: the optimal #distance, the mapping that proves
    # it and the replayable #operations. #operations_with_moves is an
    # optional alternative script that rewrites delete+insert pairs of equal
    # subtrees as explicit moves.
    #
    class Result
      attr_reader :differ, :source, :target, :distance, :moves

      def initialize(differ, source, target, trace, distance)
        @differ = differ
        @source = source
        @target = target
        @deletes = trace.deletes
        @inserts = trace.inserts
        @matches = trace.matches
        @distance = distance
        @moves = []
        detect_moves if differ.move_cost
      end

      # @return [Array<Integer>] postorder ids deleted in the source
      def deleted
        @deletes
      end

      # @return [Array<Integer>] postorder ids inserted in the target
      def inserted
        @inserts
      end

      # @return [Hash{Integer => Integer}] source id => target id for the
      #   optimal ordered mapping. Repeated equal nodes are distinguished by
      #   position, never bound by value identity.
      def mapping
        @mapping ||= Hash[@matches]
      end

      # Minimum-cost basic edit script. Replay order:
      #
      # 1. deletes, deepest/rightmost first (ids descending in postorder),
      #    each promoting its children into its place;
      # 2. replaces on surviving matched nodes;
      # 3. inserts, which the replayer assembles in target postorder.
      #
      # Replaying it with TreeDiff.apply yields the target tree exactly.
      #
      def operations
        @operations ||= build_operations
      end

      # Distance of the basic script with moves collapsed: each reported
      # move replaces one whole-subtree delete plus one whole-subtree insert
      # by one +move_cost+ edit. This number is a *lower* presentation cost,
      # not the edit distance; #distance remains the proven optimum.
      #
      def distance_with_moves
        distance - @moves.sum { |_si, _ti, saving| saving }
      end

      # Alternative script where paired equal subtrees are moved in one
      # :move edit instead of being deleted and re-inserted. The pairing is
      # an ordered, non-crossing alignment; it is heuristic post-processing
      # and does not claim optimality for the extended move alphabet.
      #
      def operations_with_moves
        moved_source = Set.new
        moved_target = Set.new
        @moves.each do |source_id, target_id, _saving|
          @source.subtree_indices(source_id).each { |i| moved_source << i }
          @target.subtree_indices(target_id).each { |i| moved_target << i }
        end

        ops = operations.reject do |edit|
          moved_source.include?(edit.source_id) ||
            moved_target.include?(edit.target_id)
        end

        move_edits = @moves.map do |source_id, target_id, _saving|
          target_parent = @target.parent[target_id]
          siblings = target_parent == 0 ? target_roots :
                       @target.children_of(target_parent)
          index = siblings.index(target_id)
          Edit.new(kind: :move, source_id: source_id, target_id: target_id,
                   parent_target_id: target_parent, index: index)
        end

        move_edits.sort_by { |edit| [edit.parent_target_id, edit.index] }
        ops + move_edits
      end

      # @api private
      def replay_with_moves
        Replayer.new(@source.root, @source, @target,
                     operations_with_moves, target_of_source: mapping,
                     moved_target_ids: @moves.map { |_s, t, _v| t }).run
      end

      # Replays #operations starting from the source; result is structurally
      # equal to the target.
      #
      def replay
        Replayer.new(@source.root, @source, @target, operations,
                     target_of_source: mapping).run
      end

      private

      def build_operations
        deletes = @deletes.sort.reverse.map do |id|
          Edit.new(kind: :delete, source_id: id)
        end

        replaces = @matches.map do |source_id, target_id|
          source_node = @source.node[source_id]
          target_node = @target.node[target_id]
          cost = @differ.replace_cost.call(source_node, target_node)
          next if cost == 0
          Edit.new(kind: :replace, source_id: source_id,
                   target_id: target_id, label: target_node.label,
                   value: target_node.value)
        end.compact

        inserts = build_insert_operations

        deletes + replaces + inserts
      end

      # Inserts name their target node, parent and final sibling index; the
      # Replayer performs the postorder assembly (collecting target children
      # from survivors and earlier inserted subtrees).
      #
      def build_insert_operations
        @inserts.sort.map do |id|
          node = @target.node[id]
          parent = @target.parent[id]
          parent_siblings = parent == 0 ? target_roots : @target.children_of(parent)
          Edit.new(kind: :insert, target_id: id,
                   parent_target_id: parent,
                   index: parent_siblings.index(id) || 0,
                   label: node.label, value: node.value,
                   children_count: @target.children_of(id).size)
        end
      end

      def target_roots
        (1..@target.size).select { |i| @target.parent[i] == 0 }
      end

      # Pair maximal fully-deleted source subtrees with maximal fully-
      # inserted target subtrees of identical shape using an ordered
      # non-crossing alignment (subsequence LCS over the candidate lists).
      #
      def detect_moves
        deleted = Set.new(@deletes)
        inserted = Set.new(@inserts)

        source_roots = maximal_subtree_roots(@source, deleted)
        target_roots = maximal_subtree_roots(@target, inserted)
        source_keys = source_roots.map { |id| subtree_key(@source, id) }
        target_keys = target_roots.map { |id| subtree_key(@target, id) }

        pairs = align(source_roots, source_keys, target_roots, target_keys)
        pairs.each do |source_id, target_id|
          saving = subtree_cost(@source, source_id, @differ.delete_cost) +
                   subtree_cost(@target, target_id, @differ.insert_cost) -
                   @differ.move_cost.to_f
          @moves << [source_id, target_id, saving] if saving > 0
        end
      end

      def maximal_subtree_roots(indexed, marked)
        (1..indexed.size).select do |id|
          marked.include?(id) &&
            (indexed.parent[id] == 0 || !marked.include?(indexed.parent[id])) &&
            # A move relocates a *whole* subtree: every descendant must be
            # deleted/inserted as well. A marked node with a surviving
            # descendant is not a move candidate (its survivor stays put).
            indexed.subtree_indices(id).all? { |descendant| marked.include?(descendant) }
        end
      end

      def subtree_key(indexed, id)
        node = indexed.node[id]
        [node.label, node.value,
         indexed.children_of(id).map { |child| subtree_key(indexed, child) }]
      end

      def subtree_cost(indexed, id, cost)
        indexed.subtree_indices(id).sum { |k| cost.call(indexed.node[k]) }
      end

      # Weighted LCS: equal-shaped candidates may pair, lists stay ordered so
      # bindings can never cross. Weight is the delete+insert cost saved.
      #
      def align(source_roots, source_keys, target_roots, target_keys)
        n = source_roots.size
        m = target_roots.size
        dp = Array.new(n + 1) { Array.new(m + 1, 0.0) }
        take = Array.new(n + 1) { Array.new(m + 1, false) }

        n.times do |x|
          m.times do |y|
            best = [dp[x][y + 1], dp[x + 1][y]].max
            if source_keys[x] == target_keys[y]
              weight = subtree_cost(@source, source_roots[x],
                                   @differ.delete_cost) +
                       subtree_cost(@target, target_roots[y],
                                   @differ.insert_cost)
              paired = dp[x][y] + weight
              if paired > best
                best = paired
                take[x + 1][y + 1] = true
              end
            end
            dp[x + 1][y + 1] = best
          end
        end

        pairs = []
        x, y = n, m
        while x > 0 && y > 0
          if take[x][y]
            pairs << [source_roots[x - 1], target_roots[y - 1]]
            x -= 1
            y -= 1
          elsif dp[x - 1][y] >= dp[x][y - 1]
            x -= 1
          else
            y -= 1
          end
        end
        pairs.reverse
      end
    end

    # @api private
    # Mutable replay node. Surviving nodes remember their source postorder
    # id; inserted nodes remember their target postorder id.
    Work = Struct.new(:label, :value, :children, :source_id, :target_id)

    # Applies an edit script (Result#operations or #operations_with_moves)
    # to a tree and returns the resulting Node. The given tree may be any
    # form accepted by Differ#build; when replaying a Result directly prefer
    # Result#replay, which already knows the postorder ids.
    #
    def self.apply(tree, operations, target_of_source: nil)
      differ = Differ.new
      node_tree = differ.build(tree)
      indexed = IndexedTree.new(node_tree, ->(_n) { 0 })
      Replayer.new(node_tree, indexed, nil, operations,
                   target_of_source: target_of_source || {}).run
    end

    # Convenience wrapper: diffs two trees with caller supplied costs.
    #
    def self.diff(source, target, delete_cost: 1, insert_cost: 1,
                  replace_cost: nil, move_cost: 1)
      Differ.new(delete_cost: delete_cost, insert_cost: insert_cost,
                 replace_cost: replace_cost, move_cost: move_cost).
        diff(source, target)
    end

    # @api private
    class Replayer
      def initialize(source_tree, indexed_source, indexed_target, operations,
                     target_of_source:, moved_target_ids: [])
        @source_tree = source_tree
        @indexed_source = indexed_source
        @indexed_target = indexed_target
        @operations = operations
        @target_of_source = target_of_source
        @moved_target_ids = Set.new(moved_target_ids)
      end

      def run
        @by_target = {}
        roots = [wrap(@source_tree)]

        # Separate inserts: they are replayed by target-tree assembly (see
        # #replay_inserts), which is robust for arbitrarily nested inserts.
        inserts = []
        moves = []
        @operations.each do |edit|
          case edit.kind
          when :delete
            delete(roots, edit.source_id)
          when :replace
            work = @by_source.fetch(edit.source_id)
            work.label = edit.label
            work.value = edit.value
            @by_target[edit.target_id] = work
          when :insert
            inserts << edit
          when :move
            moves << edit
          else
            raise ArgumentError, "unknown edit #{edit.kind.inspect}"
          end
        end
        # Moves are detached and published under their target id. A move
        # whose target parent survives is attached (and the child list is
        # normalized) before insert assembly, so assembly later moves the
        # whole, already correct subtree. A move under an inserted parent
        # stays at the forest top and is collected during that parent's
        # postorder assembly.
        moves.each do |edit|
          work = @by_source.fetch(edit.source_id)
          detach(roots, work)
          work.target_id = edit.target_id
          @by_target[edit.target_id] = work
          if edit.parent_target_id != 0 &&
             @by_target.key?(edit.parent_target_id) &&
             !insert_parent?(edit.parent_target_id, inserts)
            attach_and_order(roots, edit)
          elsif edit.parent_target_id == 0
            attach_and_order(roots, edit)
          end
        end
        replay_inserts(roots, inserts) unless inserts.empty?
        finalize_moves(roots, moves)

        unwrap(roots.one? ? roots.first : roots)
      end

      def insert_parent?(target_id, inserts)
        inserts.any? { |edit| edit.target_id == target_id }
      end

      def attach_and_order(roots, edit)
        work = @by_target.fetch(edit.target_id)
        parent_id = edit.parent_target_id
        slice = parent_id == 0 ? roots : @by_target.fetch(parent_id).children
        slice.delete_if { |entry| entry.equal?(work) }
        slice.insert([edit.index, slice.length].min, work)
        normalize(slice, parent_id)
      end

      def normalize(slice, parent_id)
        ordered = target_children_of(parent_id).map { |id| @by_target[id] }
        present = ordered.select { |work| slice.any? { |entry| entry.equal?(work) } }
        extras = slice.reject { |entry| present.any? { |work| work.equal?(entry) } }
        slice.replace(present + extras)
      end
      
      # Assembles inserted nodes from the postorder insert edits. For each
      # inserted node (parents after children), its target children are
      # collected in order from wherever they currently live - a surviving
      # matched subtree or a previously assembled inserted node - detached,
      # and attached; the node itself is then placed under its target parent
      # (which is either a survivor, a later assembled node, or the forest
      # top). This directly inverts the delete-promotion contract.
      #
      def replay_inserts(roots, inserts)
        pending = inserts.map { |edit| [edit.target_id, edit] }.to_h
        assembled = {}

        # Process in target postorder (children before parents).
        inserts.sort_by { |edit| edit.target_id }.each do |edit|
          id = edit.target_id
          target_children = target_children_of(id)
          collected = target_children.map do |child_id|
            work = @by_target.fetch(child_id)
            detach(roots, work)
            work
          end
          if collected.empty?
            work = Work.new(edit.label, edit.value, [], nil, id)
          else
            work = Work.new(edit.label, edit.value, collected, nil, id)
          end
          assembled[id] = work
          @by_target[id] = work
          place_inserted(roots, work, edit, pending, assembled)
        end
      end

      def target_children_of(target_id)
        if @indexed_target
          target_id == 0 ? target_roots_of(@indexed_target) :
            @indexed_target.children_of(target_id)
        else
          # Standalone TreeDiff.apply without a target index: inserts are
          # leaves only in that mode.
          []
        end
      end

      def target_roots_of(indexed)
        (1..indexed.size).select { |id| indexed.parent[id] == 0 }
      end

      # After assembly, moves whose target parent is matched (not assembled
      # above, since assembly only visits inserted nodes) still sit at the
      # forest top. Attach them and normalize each affected child list to
      # the exact target order.
      #
      def finalize_moves(roots, moves)
        affected = Set.new
        moves.each do |edit|
          work = @by_target.fetch(edit.target_id)
          next if contained_anywhere?(roots, work)
          parent_id = edit.parent_target_id
          affected << parent_id
          slice = parent_id == 0 ? roots : @by_target.fetch(parent_id).children
          slice << work
        end
        affected << 0 if moves.any? { |edit| edit.parent_target_id == 0 }
        affected.each do |parent_id|
          slice = parent_id == 0 ? roots : @by_target.fetch(parent_id).children
          ordered = target_children_of(parent_id).map { |id| @by_target[id] }
          extras = slice.reject { |entry| ordered.any? { |known| known.equal?(entry) } }
          slice.replace(ordered + extras)
        end
      end

      def contained_anywhere?(roots, wanted)
        roots.any? { |entry| entry &&
          (entry.equal?(wanted) || contained?(entry, wanted)) }
      end

      def contained?(node, wanted)
        node.children.any? { |child| child &&
          (child.equal?(wanted) || contained?(child, wanted)) }
      end

      def place_inserted(roots, work, edit, pending, assembled)
        parent_target_id = edit.parent_target_id
        if parent_target_id == 0
          roots.insert(edit.index, work)
        elsif assembled.key?(parent_target_id) || pending.key?(parent_target_id)
          # Parent is inserted (assembled now or assembled later); the
          # postorder collection above already consumed +work+ when it is a
          # declared target child, so nothing to do here. Defensively place
          # an orphan at the top.
          roots << work unless assembled.key?(parent_target_id) &&
            assembled.fetch(parent_target_id).children.include?(work)
        else
          # Parent survives: insert at the final target index among the
          # children already present (survivors and earlier inserts).
          children = @by_target.fetch(parent_target_id).children
          children.insert([edit.index, children.length].min, work)
        end
      end

      private

      def wrap(node)
        source_id = @indexed_source.id_of(node)
        children = node.children.map { |child| wrap(child) }
        work = Work.new(node.label, node.value, children, source_id, nil)
        @by_source ||= {}
        @by_source[source_id] = work
        target_id = @target_of_source[source_id]
        if target_id
          work.target_id = target_id
          @by_target ||= {}
          @by_target[target_id] = work
        end
        work
      end

      def unwrap(work)
        case work
        when Array
          work.map { |w| unwrap(w) }
        when Work
          Node.new(work.label, work.value, work.children.map { |c| unwrap(c) })
        end
      end

      def delete(roots, source_id)
        parent, index = locate(roots, source_id)
        work = parent.nil? ? roots[index] : parent.children[index]
        promoted = work.children
        if parent.nil?
          roots[index, 1] = promoted
        else
          parent.children[index, 1] = promoted
        end
      end

      def detach(roots, work)
        parent, index = locate_work(roots, work)
        if parent.nil?
          roots.delete_at(index)
        else
          parent.children.delete_at(index)
        end
      end

      def locate(roots, source_id)
        roots.each_with_index do |work, index|
          return [nil, index] if work.source_id == source_id
          found = locate_in(work, source_id)
          return found if found
        end
        raise "source node #{source_id} not found during replay"
      end

      def locate_in(work, source_id)
        work.children.each_with_index do |child, index|
          if child.source_id == source_id
            return [work, index]
          end
          found = locate_in(child, source_id)
          return found if found
        end
        nil
      end

      def locate_work(roots, wanted)
        roots.each_with_index do |work, index|
          return [nil, index] if work.equal?(wanted)
          found = locate_work_in(work, wanted)
          return found if found
        end
        raise "moved subtree not found"
      end

      def locate_work_in(work, wanted)
        work.children.each_with_index do |child, index|
          return [work, index] if child.equal?(wanted)
          found = locate_work_in(child, wanted)
          return found if found
        end
        nil
      end
    end
  end
end
