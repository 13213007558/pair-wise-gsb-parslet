require 'set'

# Computes an optimal edit script between two ordered, rooted trees.
#
# The basic operations are insertion, deletion and replacement. Deleting a
# node never implicitly deletes its children; they are promoted into the
# deleted node's position in their parent's child sequence. Correspondingly,
# an insertion may adopt a consecutive run of existing child subtrees.
#
# Node identity is positional, not value based. Every node receives a unique
# source or target pre-order id, so repeated labels or values can never be
# bound merely because they are equal.
module Parslet
  def self.tree_diff(source, target, options = {}, &block)
    TreeDiff.tree_diff(source, target, options, &block)
  end
end

class Parslet::TreeDiff
  # A canonical node. Inputs may also be hashes with +label+, +value+ and
  # +children+ keys or objects that respond to those three methods.
  Node = Struct.new(:label, :value, :children) do
    def initialize(label = nil, value = nil, children = [])
      super(label, value, Array(children))
    end

    def [](key)
      public_send(key)
    end
  end

  Result = Struct.new(:cost, :script)

  IndexedNode = Struct.new(
    :object, :label, :value, :children, :parent,
    :id, :post, :leftmost_post
  )

  # Returns the minimum cost and a replayable edit script.
  #
  # +delete_cost+ and +insert_cost+ receive the canonical source or target
  # node. +replace_cost+ receives a canonical source/target pair. Every cost
  # callback must return a non-negative number. With no callbacks, each structural edit
  # costs one and replacement is free when label and value are unchanged.
  #
  # Script operations are plain hashes with source/target pre-order ids. A
  # delete always records <code>children: :promote</code>. An insert records
  # the final parent, child index and the matched source children it adopts.
  # These are basic edits only; recognizing an insertion plus deletion as a
  # move is deliberately left to later post-processing.
  def self.tree_diff(source, target, options = {}, &block)
    new(source, target, options, &block).call
  end

  def self.diff(source, target, options = {}, &block)
    tree_diff(source, target, options, &block)
  end

  # Applies a script and returns the replayed canonical tree.
  # The source object is not modified.
  def self.replay(source, script)
    Replayer.new(source, script).call
  end

  def initialize(source, target, options, &block)
    @source = build_tree(source)
    @target = build_tree(target)

    @delete_cost = options.fetch(:delete_cost, UNIT_COST)
    @insert_cost = options.fetch(:insert_cost, UNIT_COST)
    @replace_cost = options[:replace_cost] || block || DEFAULT_REPLACE_COST

    ensure_callable(:delete_cost, @delete_cost)
    ensure_callable(:insert_cost, @insert_cost)
    ensure_callable(:replace_cost, @replace_cost)

    @tables = {}
  end

  def call
    return Result.new(0, []) if @source.nil? && @target.nil?

    if @source.nil?
      script = @target.nodes.sort_by(&:id).map { |node| insert_operation(node, {}) }
      return Result.new(script.sum { |operation| operation_cost(operation) }, script)
    end

    if @target.nil?
      script = @source.nodes.sort_by(&:post).map { |node| delete_operation(node) }
      return Result.new(script.sum { |operation| operation_cost(operation) }, script)
    end

    compute
    script = build_script
    Result.new(script.sum { |operation| operation_cost(operation) }, script)
  end

  private

  UNIT_COST = ->(node) { 1 }
  DEFAULT_REPLACE_COST = ->(source, target) {
    source.label == target.label && source.value == target.value ? 0 : 1
  }

  def build_tree(root)
    return nil if root.nil?

    nodes = []
    id = 0

    visit = lambda do |object, parent|
      canonical = canonical_node(object)
      node = IndexedNode.new(canonical, canonical.label,
        canonical.value, [], parent)
      node.id = id
      id += 1

      canonical.children.each do |child|
        node.children << visit.call(child, node)
      end

      nodes << node
      node
    end

    indexed_root = visit.call(root, nil)
    assign_postorder(indexed_root)
    IndexedTree.new(nodes, indexed_root)
  end

  def canonical_node(object)
    if object.is_a?(Hash)
      unless object.key?(:label) && object.key?(:value) && object.key?(:children)
        raise ArgumentError, 'a hash node needs :label, :value and :children keys'
      end
      return Node.new(object[:label], object[:value], object[:children].dup)
    end

    if object.respond_to?(:label) &&
       object.respond_to?(:value) &&
       object.respond_to?(:children)
      return Node.new(object.label, object.value, object.children.dup)
    end

    raise ArgumentError, "cannot treat #{object.inspect} as a tree node"
  end

  def assign_postorder(root)
    post = 0

    assign = lambda do |node|
      node.children.each { |child| assign.call(child) }
      node.post = post
      node.leftmost_post = node.children.empty? ? node.post : node.children.first.leftmost_post
      post += 1
    end

    assign.call(root)
  end

  def compute
    @source.keyroots.each do |source_keyroot|
      @target.keyroots.each do |target_keyroot|
        compute_keyroot_pair(source_keyroot, target_keyroot)
      end
    end
  end

  def compute_keyroot_pair(source_keyroot, target_keyroot)
    source_start = source_keyroot.leftmost_post
    target_start = target_keyroot.leftmost_post
    source_size = source_keyroot.post - source_start + 1
    target_size = target_keyroot.post - target_start + 1

    costs = Array.new(source_size + 1) { Array.new(target_size + 1, 0) }
    decisions = Array.new(source_size + 1) { Array.new(target_size + 1) }

    (source_start..source_keyroot.post).each do |source_post|
      local_source = source_post - source_start + 1
      costs[local_source][0] = costs[local_source - 1][0] +
        delete_cost_for(@source.by_post[source_post])
      decisions[local_source][0] = [:delete, source_post]
    end

    (target_start..target_keyroot.post).each do |target_post|
      local_target = target_post - target_start + 1
      costs[0][local_target] = costs[0][local_target - 1] +
        insert_cost_for(@target.by_post[target_post])
      decisions[0][local_target] = [:insert, target_post]
    end

    (source_start..source_keyroot.post).each do |source_post|
      source_node = @source.by_post[source_post]
      local_source = source_post - source_start + 1

      (target_start..target_keyroot.post).each do |target_post|
        target_node = @target.by_post[target_post]
        local_target = target_post - target_start + 1
        candidates = []

        candidates << [
          costs[local_source - 1][local_target] + delete_cost_for(source_node),
          [:delete, source_post]
        ]
        candidates << [
          costs[local_source][local_target - 1] + insert_cost_for(target_node),
          [:insert, target_post]
        ]

        if source_node.leftmost_post == source_start &&
           target_node.leftmost_post == target_start
          match_cost = costs[local_source - 1][local_target - 1] +
            replace_cost_for(source_node, target_node)
          candidates << [
            match_cost, [:match, source_post, target_post]
          ]
        else
          before_source = source_node.leftmost_post - source_start
          before_target = target_node.leftmost_post - target_start
          match_cost = costs[before_source][before_target] +
            subtree_distance(source_node, target_node)
          candidates << [
            match_cost,
            [:subtree, source_post, target_post, before_source, before_target]
          ]
        end

        cost, decision = candidates.min_by(&:first)
        costs[local_source][local_target] = cost
        decisions[local_source][local_target] = decision

        if source_node.leftmost_post == source_start &&
           target_node.leftmost_post == target_start
          @source.treedist[source_post] ||= {}
          @source.treedist[source_post][target_post] = cost

          @source.tree_trace[source_post] ||= {}
          @source.tree_trace[source_post][target_post] ||= {
            :key => [source_keyroot.post, target_keyroot.post],
            :source_start => source_start,
            :target_start => target_start
          }
        end
      end
    end

    @tables[[source_keyroot.post, target_keyroot.post]] = {
      :source_start => source_start,
      :target_start => target_start,
      :costs => costs,
      :decisions => decisions
    }
  end

  def subtree_distance(source_node, target_node)
    distance = @source.treedist.dig(source_node.post, target_node.post)
    return distance unless distance.nil?
    raise("missing subtree distance for #{source_node.post},#{target_node.post}")
  end

  def build_script
    matches = trace_root_matches
    matched_target = {}
    matches.each { |source_node, target_node| matched_target[target_node] = source_node }

    deletions = @source.nodes.reject { |node| matches.key?(node) }.
      sort_by(&:post).
      map { |node| delete_operation(node) }

    replacements = matches.select { |source_node, target_node|
      source_node.label != target_node.label ||
        source_node.value != target_node.value ||
        replace_cost_for(source_node, target_node) > 0
    }.sort_by { |source_node, _| source_node.id }.
      map { |source_node, target_node|
        replace_operation(source_node, target_node)
      }

    insertions = @target.nodes.reject { |node| matched_target.key?(node) }.
      sort_by(&:id).
      map { |node| insert_operation(node, matched_target) }

    deletions + replacements + insertions
  end

  def trace_root_matches
    matches = Set.new
    trace(@source.root.post, @target.root.post, matches)
    matches.each_with_object({}) do |(source_post, target_post), pairs|
      pairs[@source.by_post.fetch(source_post)] = @target.by_post.fetch(target_post)
    end
  end

  def trace(source_post, target_post, matches)
    reference = @source.tree_trace.dig(source_post, target_post) ||
      raise("missing trace for #{source_post},#{target_post}")
    trace_in_table(source_post, target_post, reference.fetch(:key),
      reference.fetch(:source_start), reference.fetch(:target_start), matches)
  end

  def trace_in_table(source_post, target_post, key, source_start,
                    target_start, matches)
    table = @tables.fetch(key)
    decisions = table.fetch(:decisions)

    until source_post < source_start && target_post < target_start
      local_source = source_post < source_start ? 0 :
        source_post - source_start + 1
      local_target = target_post < target_start ? 0 :
        target_post - target_start + 1
      decision = decisions[local_source][local_target]

      case decision.first
      when :delete
        source_post -= 1
      when :insert
        target_post -= 1
      when :match
        matches << [decision[1], decision[2]]
        source_post = decision[1] - 1
        target_post = decision[2] - 1
      when :subtree
        trace(decision[1], decision[2], matches)
        source_post = source_start + decision[3] - 1
        target_post = target_start + decision[4] - 1
      else
        raise "unknown tree diff decision #{decision.inspect}"
      end
    end
  end

  def delete_operation(node)
    {
      :op => :delete,
      :source_id => source_ref(node.id),
      :children => :promote
    }
  end

  def replace_operation(source_node, target_node)
    {
      :op => :replace,
      :source_id => source_ref(source_node.id),
      :target_id => target_ref(target_node.id),
      :label => target_node.label,
      :value => target_node.value
    }
  end

  def insert_operation(node, matched_target)
    parent = node.parent
    parent_id = if parent.nil?
      nil
    elsif matched_target.key?(parent)
      source_ref(matched_target.fetch(parent).id)
    else
      target_ref(parent.id)
    end

    adopted_children = node.children.select { |child|
      matched_target.key?(child)
    }.map { |child|
      source_ref(matched_target.fetch(child).id)
    }

    {
      :op => :insert,
      :target_id => target_ref(node.id),
      :parent_id => parent_id,
      :index => parent.nil? ? 0 : parent.children.index(node),
      :label => node.label,
      :value => node.value,
      :child_ids => adopted_children
    }
  end

  def source_ref(id)
    "source:#{id}"
  end

  def target_ref(id)
    "target:#{id}"
  end

  def operation_cost(operation)
    case operation[:op]
    when :delete
      delete_cost_for(@source.by_id.fetch(node_id(operation[:source_id])))
    when :insert
      insert_cost_for(@target.by_id.fetch(node_id(operation[:target_id])))
    when :replace
      replace_cost_for(
        @source.by_id.fetch(node_id(operation[:source_id])),
        @target.by_id.fetch(node_id(operation[:target_id]))
      )
    end
  end

  def node_id(reference)
    Integer(reference.split(':', 2).last, 10)
  end

  def ensure_callable(name, callable)
    return if callable.respond_to?(:call)
    raise ArgumentError, "#{name} must respond to #call"
  end

  def delete_cost_for(node)
    cost = @delete_cost.call(node.object)
    ensure_non_negative_cost(:delete_cost, cost)
  end

  def insert_cost_for(node)
    cost = @insert_cost.call(node.object)
    ensure_non_negative_cost(:insert_cost, cost)
  end

  def replace_cost_for(source, target)
    cost = @replace_cost.call(source.object, target.object)
    ensure_non_negative_cost(:replace_cost, cost)
  end

  def ensure_non_negative_cost(name, cost)
    return cost if cost.is_a?(Numeric) && cost >= 0
    raise ArgumentError, "#{name} returned a negative or non-numeric cost"
  end
end

class Parslet::TreeDiff::IndexedTree
  attr_reader :nodes, :root, :by_post, :by_id, :keyroots,
    :treedist, :tree_trace

  def initialize(nodes, root)
    @nodes = nodes
    @root = root
    @by_post = nodes.each_with_object({}) { |node, map| map[node.post] = node }
    @by_id = nodes.each_with_object({}) { |node, map| map[node.id] = node }
    @keyroots = nodes.select { |node|
      node.parent.nil? || node.parent.children.first.equal?(node) == false
    }.sort_by(&:post)
    @treedist = {}
    @tree_trace = {}
  end
end

class Parslet::TreeDiff::Replayer
  def initialize(source, script)
    @script = script
    @nodes = {}
    @parent = {}
    @roots = []
    @next_source_id = 0
    add_runtime_tree(source, nil, @roots) unless source.nil?
  end

  def call
    @script.each { |operation| dispatch(operation) }

    @roots.first
  end

  def dispatch(operation)
    case operation.fetch(:op)
    when :delete
      apply_delete(operation)
    when :replace
      apply_replace(operation)
    when :insert
      apply_insert(operation)
    else
      raise ArgumentError, "unknown operation #{operation.fetch(:op).inspect}"
    end
  end

  private

  def add_runtime_tree(object, parent, siblings)
    label, value, children = node_attributes(object)
    node = Parslet::TreeDiff::Node.new(label, value)
    id = @next_source_id
    @next_source_id += 1
    @nodes["source:#{id}"] = node
    @parent[node.object_id] = parent
    siblings << node

    children.each do |child|
      add_runtime_tree(child, node, node.children)
    end

    node
  end

  def node_attributes(object)
    if object.is_a?(Hash)
      [object.fetch(:label), object.fetch(:value), object.fetch(:children)]
    elsif object.respond_to?(:label) &&
          object.respond_to?(:value) &&
          object.respond_to?(:children)
      [object.label, object.value, object.children]
    else
      raise ArgumentError, "cannot treat #{object.inspect} as a tree node"
    end
  end

  def apply_delete(operation)
    unless operation.fetch(:children) == :promote
      raise ArgumentError, 'only children: :promote deletion is supported'
    end

    node = fetch_node(operation.fetch(:source_id))
    siblings = siblings_of(node)
    position = siblings.index { |child| child.equal?(node) }
    children = node.children.dup
    siblings.delete_at(position)
    siblings.insert(position, *children)
    parent_node = @parent.fetch(node.object_id)
    children.each { |child| @parent[child.object_id] = parent_node }
  end

  def apply_replace(operation)
    node = fetch_node(operation.fetch(:source_id))
    node.label = operation.fetch(:label)
    node.value = operation.fetch(:value)
    @nodes[operation.fetch(:target_id)] = node
  end

  def apply_insert(operation)
    node = Parslet::TreeDiff::Node.new(
      operation.fetch(:label), operation.fetch(:value)
    )
    @nodes[operation.fetch(:target_id)] = node
    children = operation.fetch(:child_ids).map { |id| fetch_node(id) }

    operation.fetch(:child_ids).each do |id|
      child = fetch_node(id)
      current_parent = @parent.fetch(child.object_id)
      siblings = current_parent.nil? ? @roots : current_parent.children
      position = siblings.index { |sibling| sibling.equal?(child) }
      siblings.delete_at(position) unless position.nil?
      @parent[child.object_id] = node
    end
    node.children.replace(children)

    parent_id = operation[:parent_id]
    parent = parent_id.nil? ? nil : fetch_node(parent_id)
    siblings = parent.nil? ? @roots : parent.children
    index = operation.fetch(:index)
    unless index >= 0 && index <= siblings.size
      raise ArgumentError, "insert index #{index} is out of range"
    end

    siblings.insert(index, node)
    @parent[node.object_id] = parent
  end

  def fetch_node(id)
    @nodes.fetch(id) do
      raise KeyError, "unknown tree node id #{id.inspect}"
    end
  end

  def siblings_of(node)
    parent = @parent.fetch(node.object_id)
    parent.nil? ? @roots : parent.children
  end

end
