require 'spec_helper'

def tree_node(label, value = nil, children = [])
  { :label => label, :value => value, :children => children }
end

describe Parslet::TreeDiff do
  let(:node_class) { Parslet::TreeDiff::Node }

  def replay(source, result)
    described_class.replay(source, result.script)
  end

  describe 'script semantics' do
    it 'deletes an internal node by promoting its children' do
      source = tree_node(:wrap, nil, [
        tree_node(:kept, 1),
        tree_node(:removed, nil, [tree_node(:promoted, 2)]),
        tree_node(:tail, 3)
      ])
      target = tree_node(:wrap, nil, [
        tree_node(:kept, 1), tree_node(:promoted, 2), tree_node(:tail, 3)
      ])

      result = Parslet.tree_diff(source, target)

      expect(result.cost).to eq(1)
      expect(result.script).to eq([
        {
          :op => :delete,
          :source_id => 'source:2',
          :children => :promote
        }
      ])
      expect(replay(source, result)).to eq(
        node_class.new(:wrap, nil, [
          node_class.new(:kept, 1),
          node_class.new(:promoted, 2),
          node_class.new(:tail, 3)
        ])
      )
    end

    it 'inserts an internal node by adopting consecutive children' do
      source = tree_node(:root, nil, [tree_node(:a), tree_node(:b)])
      target = tree_node(:root, nil, [
        tree_node(:group, nil, [tree_node(:a), tree_node(:b)])
      ])

      result = Parslet.tree_diff(source, target)

      expect(result.cost).to eq(1)
      expect(result.script).to eq([
        {
          :op => :insert,
          :target_id => 'target:1',
          :parent_id => 'source:0',
          :index => 0,
          :label => :group,
          :value => nil,
          :child_ids => ['source:1', 'source:2']
        }
      ])
      expect(replay(source, result)).to eq(
        node_class.new(:root, nil, [
          node_class.new(:group, nil, [
            node_class.new(:a), node_class.new(:b)
          ])
        ])
      )
    end

    it 'uses caller supplied label and value replacement costs' do
      source = tree_node(:a, 'old')
      target = tree_node(:b, 'new')
      replacement = ->(left, right) {
        (left[:label] != right[:label] ? 3 : 0) +
          (left[:value] != right[:value] ? 5 : 0)
      }
      result = Parslet.tree_diff(
        source, target,
        :delete_cost => ->(_) { 10 },
        :insert_cost => ->(_) { 10 },
        :replace_cost => replacement
      )

      expect(result.cost).to eq(8)
      expect(result.script.first.fetch(:label)).to eq(:b)
      expect(result.script.first.fetch(:value)).to eq('new')
      expect(replay(source, result)).to eq(node_class.new(:b, 'new'))
    end

    it 'uses separate insertion and deletion callbacks' do
      source = tree_node(:root, nil, [tree_node(:x)])
      target = tree_node(:root, nil, [tree_node(:y)])
      result = Parslet.tree_diff(
        source, target,
        :delete_cost => ->(tree) { tree[:label] == :x ? 2 : 10 },
        :insert_cost => ->(tree) { tree[:label] == :y ? 4 : 10 },
        :replace_cost => ->(left, right) {
          left[:label] == right[:label] &&
            left[:value] == right[:value] ? 0 : 100
        }
      )

      expect(result.cost).to eq(6)
      expect(result.script.map { |operation| operation[:op] }).
        to contain_exactly(:delete, :insert)
    end
  end

  describe 'repeated subtrees' do
    it 'does not bind duplicate leaves only by equal value' do
      source = tree_node(:root, 'same', [tree_node(:x), tree_node(:y), tree_node(:x)])
      target = tree_node(:root, 'same', [tree_node(:y), tree_node(:x), tree_node(:x)])
      expensive_indels = {
        :delete_cost => ->(_) { 10 },
        :insert_cost => ->(_) { 10 }
      }

      result = Parslet.tree_diff(source, target, expensive_indels)

      expect(result.cost).to eq(2)
      replacements = result.script.select do |operation|
        operation[:op] == :replace
      end
      expect(replacements.map { |operation| operation[:source_id] }).
        to eq(['source:1', 'source:2'])
      expect(replacements.map { |operation| operation[:target_id] }).
        to eq(['target:1', 'target:2'])
      expect(replay(source, result)).to eq(
        node_class.new(:root, 'same', [
          node_class.new(:y), node_class.new(:x), node_class.new(:x)
        ])
      )
    end

    it 'keeps moves out of the basic edit-distance proof' do
      source = tree_node(:root, nil, [tree_node(:same), tree_node(:moved)])
      target = tree_node(:root, nil, [tree_node(:moved), tree_node(:same)])
      result = Parslet.tree_diff(
        source, target,
        :delete_cost => ->(_) { 10 },
        :insert_cost => ->(_) { 10 }
      )

      expect(result.script.map { |operation| operation[:op] }).
        to all(eq(:replace))
      expect(result.cost).to eq(2)
    end
  end

  describe 'optimal distance on enumerable small trees' do
    labels = [:a, :b]

    compositions = lambda do |size|
      next [[]] if size.zero?
      (1..size).flat_map do |first|
        compositions.call(size - first).map { |tail| [first] + tail }
      end
    end

    trees = {}
    forests = lambda do |size|
      next [[]] if size.zero?
      compositions.call(size).flat_map do |parts|
        parts.map { |part| trees.fetch(part) }.reduce([[]]) do |choices, options|
          choices.product(options).map { |prefix, option| prefix + [option] }
        end
      end
    end

    (1..3).each do |size|
      trees[size] = labels.product(forests.call(size - 1)).map do |label, children|
        tree_node(label, nil, children)
      end
    end
    forest_states = [[]] + (1..3).flat_map { |size| forests.call(size) }

    let(:rooted_trees) { [nil] + (1..3).flat_map { |size| trees.fetch(size) } }

    it 'matches an exhaustive forest shortest path and replays exactly' do
      # This test is intentionally exhaustive: every pair has at most three
      # nodes, so every promote-delete, replace and insertion can be enumerated.
      expect(rooted_trees.size).to eq(23)
      edge_map = {}
      exhaustive_distances = Hash.new(Float::INFINITY)
      forest_states.each do |forest|
        exhaustive_distances[[forest, forest]] = 0
        edge_map[forest] = exhaustive_transitions(forest, labels)
      end
      forest_states.each do |forest|
        edge_map.fetch(forest).each do |next_forest|
          exhaustive_distances[[forest, next_forest]] = 1
        end
      end
      forest_states.each do |middle|
        forest_states.each do |left|
          left_distance = exhaustive_distances[[left, middle]]
          next if left_distance.infinite?
          forest_states.each do |right|
            candidate = left_distance + exhaustive_distances[[middle, right]]
            if candidate < exhaustive_distances[[left, right]]
              exhaustive_distances[[left, right]] = candidate
            end
          end
        end
      end

      rooted_trees.each do |source|
        rooted_trees.each do |target|
          result = Parslet.tree_diff(source, target)
          replayed = described_class.replay(source, result.script)
          expected = target.nil? ? nil : node_class.new(
            target.fetch(:label), target.fetch(:value),
            target.fetch(:children).map { |child| node_class.new(
              child.fetch(:label), child.fetch(:value),
              child.fetch(:children).map { |grandchild|
                node_class.new(grandchild.fetch(:label),
                  grandchild.fetch(:value))
              }
            ) }
          )
          brute_force = exhaustive_distances.fetch([
            source.nil? ? [] : [source],
            target.nil? ? [] : [target]
          ])

          expect(result.cost).to eq(brute_force)
          expect(replayed).to eq(expected)
        end
      end
    end
  end

end

# Small-tree transition enumeration used by the optimality proof below.
def exhaustive_transitions(forest, labels)
  transitions = []

  forest.each_index do |index|
    deleted = forest.dup
    removed = deleted.delete_at(index)
    deleted.insert(index, *removed.fetch(:children))
    transitions << deleted
  end

  labels.each do |label|
    (0..forest.size).each do |index|
      inserted = forest.dup
      inserted.insert(index, tree_node(label))
      transitions << inserted
    end

    forest.each_index do |start|
      1.upto(forest.size - start) do |length|
        wrapped = forest.dup
        wrapped[start, length] = [
          tree_node(label, nil, forest[start, length])
        ]
        transitions << wrapped
      end
    end
  end

  forest.each_with_index do |tree, index|
    internal_insertions(tree, labels).each do |replacement|
      replaced = forest.dup
      replaced[index] = replacement
      transitions << replaced
    end
    internal_deletions(tree).each do |replacement|
      replaced = forest.dup
      replaced[index] = replacement
      transitions << replaced
    end
    internal_wraps(tree, labels).each do |replacement|
      replaced = forest.dup
      replaced[index] = replacement
      transitions << replaced
    end
    internal_relabels(tree, labels).each do |replacement|
      replaced = forest.dup
      replaced[index] = replacement
      transitions << replaced
    end
  end

  transitions.select { |candidate| tree_count(candidate) <= 3 }
end

def internal_deletions(tree)
  children = tree.fetch(:children)
  transitions = []

  children.each_index do |index|
    removed = children.fetch(index)
    updated = children.dup
    updated.delete_at(index)
    updated.insert(index, *removed.fetch(:children))
    transitions << tree.merge(:children => updated)
  end

  children.each_with_index do |child, index|
    internal_deletions(child).each do |replacement|
      updated = children.dup
      updated[index] = replacement
      transitions << tree.merge(:children => updated)
    end
  end

  transitions
end

def internal_wraps(tree, labels)
  children = tree.fetch(:children)
  transitions = []

  children.each_index do |start|
    1.upto(children.size - start) do |length|
      labels.each do |label|
        updated = children.dup
        updated[start, length] = [
          tree_node(label, nil, children[start, length])
        ]
        transitions << tree.merge(:children => updated)
      end
    end
  end

  children.each_with_index do |child, index|
    internal_wraps(child, labels).each do |replacement|
      updated = children.dup
      updated[index] = replacement
      transitions << tree.merge(:children => updated)
    end
  end

  transitions
end

def internal_relabels(tree, labels)
  transitions = labels.reject { |label| label == tree.fetch(:label) }.map do |label|
    tree.merge(:label => label)
  end

  tree.fetch(:children).each_with_index do |child, index|
    internal_relabels(child, labels).each do |replacement|
      updated = tree.fetch(:children).dup
      updated[index] = replacement
      transitions << tree.merge(:children => updated)
    end
  end

  transitions
end

def internal_insertions(tree, labels)
  children = tree.fetch(:children)
  transitions = []

  labels.each do |label|
    (0..children.size).each do |index|
      updated = children.dup
      updated.insert(index, tree_node(label))
      transitions << tree.merge(:children => updated)
    end
  end

  children.each_with_index do |child, index|
    internal_insertions(child, labels).each do |replacement|
      updated = children.dup
      updated[index] = replacement
      transitions << tree.merge(:children => updated)
    end
  end

  transitions
end

def tree_count(forest)
  forest.sum { |tree| 1 + tree_count(tree.fetch(:children)) }
end
