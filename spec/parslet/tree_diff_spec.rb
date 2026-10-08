require 'spec_helper'

module Parslet::TreeDiffSpec
  N = Parslet::TreeDiff::Node

  # Independent reference optimum for ordered-tree edit distance: enumerate
  # every ordered, ancestor-preserving node mapping and take the minimum
  # delete + insert + replace cost. This is exponential and used only on
  # small trees to certify the dynamic program's optimum.
  #
  def self.brute_force(source, target, differ)
    dc, ic, rc = differ.delete_cost, differ.insert_cost, differ.replace_cost
    sm = (1..source.size).to_a
    tm = (1..target.size).to_a
    best = Float::INFINITY

    valid = lambda do |mapping|
      keys = mapping.keys
      keys.each do |i|
        j = mapping[i]
        keys.each do |i2|
          next if i == i2
          j2 = mapping[i2]
          source_ancestor = (source.leftmost[i2]..i2).include?(i)
          target_ancestor = (target.leftmost[j2]..j2).include?(j)
          return false if source_ancestor != target_ancestor
        end
      end
      true
    end

    enumerate = lambda do |si, tj, mapping|
      if si.empty? || tj.empty?
        if valid.call(mapping)
          cost = (sm - mapping.keys).sum { |i| dc.call(source.node[i]) } +
                 (tm - mapping.values).sum { |j| ic.call(target.node[j]) } +
                 mapping.sum { |i, j| rc.call(source.node[i], target.node[j]) }
          best = cost if cost < best
        end
        return
      end
      enumerate.call(si[1..], tj[1..], mapping.merge(si.first => tj.first))
      enumerate.call(si[1..], tj, mapping)
      enumerate.call(si, tj[1..], mapping)
    end

    enumerate.call(sm, tm, {})
    best
  end

  def self.random_tree(size, labels, rng)
    return N.new(labels[rng.rand(labels.size)], nil, []) if size == 1
    root = N.new(labels[rng.rand(labels.size)], nil, [])
    child_count = rng.rand(1..[size - 1, 3].min)
    sizes = Array.new(child_count, 1)
    (size - 1 - child_count).times { sizes[rng.rand(child_count)] += 1 }
    root.children = sizes.map { |child_size| random_tree(child_size, labels, rng) }
    root
  end
end

describe Parslet::TreeDiff do
  let(:node) { Parslet::TreeDiff::Node }

  def tree(label, *children)
    Parslet::TreeDiff::Node.new(label, nil, children)
  end

  def leaf(value)
    Parslet::TreeDiff::Node.new(nil, value, [])
  end

  describe Parslet::TreeDiff::Differ do
    subject(:differ) { described_class.new }

    it 'is zero for identical trees' do
      t = tree(:f, leaf('a'), leaf('b'))
      expect(differ.diff(t, t).distance).to eq(0.0)
    end

    it 'charges one replacement for a relabelled leaf' do
      result = differ.diff(leaf('a'), leaf('b'))
      expect(result.distance).to eq(1.0)
      expect(result.operations.map(&:kind)).to eq([:replace])
    end

    it 'promotes children when their node is deleted' do
      # f(a) -> a: deleting f lifts a to the top, exactly one delete.
      result = differ.diff(tree(:f, leaf('a')), leaf('a'))
      expect(result.distance).to eq(1.0)
      edit = result.operations.first
      expect(edit.kind).to eq(:delete)
      expect(result.replay).to eq(leaf('a'))
    end

    it 'inserts a wrapper around a surviving child' do
      result = differ.diff(leaf('a'), tree(:f, leaf('a')))
      expect(result.distance).to eq(1.0)
      expect(result.replay).to eq(tree(:f, leaf('a')))
    end

    it 'keeps sibling order (swapping leaves costs two edits, not a match)' do
      source = tree(:f, leaf('a'), leaf('b'))
      target = tree(:f, leaf('b'), leaf('a'))
      result = differ.diff(source, target)
      expect(result.distance).to eq(2.0)
      expect(result.replay).to eq(target)
    end

    describe 'exhaustive optimum on enumerable small trees' do
      it 'matches brute force over random small trees with unit costs' do
        rng = Random.new(2026)
        400.times do
          source = Parslet::TreeDiffSpec.random_tree(rng.rand(1..6), %i[a b c], rng)
          target = Parslet::TreeDiffSpec.random_tree(rng.rand(1..6), %i[a b c], rng)
          differ = described_class.new
          result = differ.diff(source, target)
          indexed_source = Parslet::TreeDiff::IndexedTree.new(source, differ.delete_cost)
          indexed_target = Parslet::TreeDiff::IndexedTree.new(target, differ.insert_cost)
          optimum = Parslet::TreeDiffSpec.brute_force(indexed_source, indexed_target, differ)
          expect(result.distance).to eq(optimum)
          expect(result.replay).to eq(target)
        end
      end

      it 'matches brute force with caller supplied node-dependent costs' do
        rng = Random.new(99)
        delete_cost = ->(n) { n.leaf? ? 1.0 : 2.0 }
        insert_cost = ->(n) { n.leaf? ? 1.5 : 3.0 }
        replace_cost = ->(a, b) { a.label == b.label ? 0.0 : 5.0 }
        300.times do
          source = Parslet::TreeDiffSpec.random_tree(rng.rand(1..6), %i[a b c d], rng)
          target = Parslet::TreeDiffSpec.random_tree(rng.rand(1..6), %i[a b c d], rng)
          differ = described_class.new(delete_cost: delete_cost,
                                      insert_cost: insert_cost,
                                      replace_cost: replace_cost)
          result = differ.diff(source, target)
          indexed_source = Parslet::TreeDiff::IndexedTree.new(source, delete_cost)
          indexed_target = Parslet::TreeDiff::IndexedTree.new(target, insert_cost)
          optimum = Parslet::TreeDiffSpec.brute_force(indexed_source, indexed_target, differ)
          expect(result.distance).to eq(optimum)
          expect(result.replay).to eq(target)
        end
      end
    end

    describe 'repeated leaves are bound by position, not value' do
      # r( g(x), h(x) )  ->  r( h(x), g(x) )
      #
      # The two x leaves are equal. The ordered optimum keeps each x in its
      # own branch and replaces the g/h labels (2 edits). A routine that
      # binds nodes purely by equal value would pair the two x leaves across
      # branches and then delete+insert the surrounding subtrees, paying
      # 2 * (delete subtree + insert subtree) = 6.
      #
      let(:source) do
        tree(:r, tree(:g, leaf('x')), tree(:h, leaf('x')))
      end
      let(:target) do
        tree(:r, tree(:h, leaf('x')), tree(:g, leaf('x')))
      end

      it 'keeps position and finds the cost-2 optimum' do
        result = differ.diff(source, target)
        expect(result.distance).to eq(2.0)
        expect(result.mapping.values).to match_array(result.mapping.keys)
        # Each x stays under the same ordinal branch position.
        expect(result.replay).to eq(target)
      end

      it 'beats the 6-edit value-greedy delete/insert script' do
        result = differ.diff(source, target)
        greedy_value_cost = 2 * (1 + 1 + 1)
        expect(result.distance).to be < greedy_value_cost
      end

      it 'is certified by the exhaustive mapping search' do
        indexed_source = Parslet::TreeDiff::IndexedTree.new(source, differ.delete_cost)
        indexed_target = Parslet::TreeDiff::IndexedTree.new(target, differ.insert_cost)
        optimum = Parslet::TreeDiffSpec.brute_force(indexed_source, indexed_target, differ)
        expect(differ.diff(source, target).distance).to eq(optimum)
      end
    end

    describe 'caller supplied costs' do
      it 'uses the label/value callables for every edit' do
        delete_cost = ->(n) { n.label == :expensive ? 10.0 : 1.0 }
        insert_cost = ->(n) { 1.0 }
        replace_cost = ->(a, b) { a.value == b.value ? 0.0 : 4.0 }
        d = described_class.new(delete_cost: delete_cost,
                                insert_cost: insert_cost,
                                replace_cost: replace_cost)
        # Deleting the cheap leaf a (1) and replacing the surviving root
        # with b (4) costs 5; deleting the expensive tagged node costs 10
        # plus a replacement, so the caller costs really drive the optimum.
        result = d.diff(tree(:expensive, leaf('a')), leaf('b'))
        expect(result.distance).to eq(5.0)
        expect(result.replay).to eq(leaf('b'))
      end
    end

    describe 'parslet parse output' do
      it 'compares tagged hash trees' do
        source = { expr: [{ term: '1' }, { op: '+' }, { term: '2' }] }
        target = { expr: [{ term: '1' }, { op: '-' }, { term: '2' }] }
        result = differ.diff(source, target)
        expect(result.distance).to eq(1.0)
        expect(result.replay).to eq(differ.build(target))
      end

      it 'wraps top-level repetition arrays under one anonymous root' do
        source = [{ item: 'a' }, { item: 'b' }]
        target = [{ item: 'a' }, { item: 'b' }, { item: 'c' }]
        d = described_class.new
        s = d.build_parslet(source)
        t = d.build_parslet(target)
        result = d.diff(s, t)
        # One inserted tag node plus its value leaf.
        expect(result.distance).to eq(2.0)
        expect(result.replay).to eq(t)
      end
    end

    describe 'move post-processing' do
      it 'reports an ordered move without changing the proven distance' do
        # r(g(x), a, b) -> r(a, b, g(x)): the g(x) subtree shifts position.
        source = tree(:r, tree(:g, leaf('x')), leaf('a'), leaf('b'))
        target = tree(:r, leaf('a'), leaf('b'), tree(:g, leaf('x')))
        result = differ.diff(source, target)

        expect(result.distance).to eq(4.0)
        expect(result.distance_with_moves).to be < result.distance
        expect(result.operations_with_moves.map(&:kind)).to include(:move)
        expect(result.replay_with_moves).to eq(target)
        # The basic optimum and script are untouched by post-processing.
        expect(result.replay).to eq(target)
      end

      it 'pairs repeated subtrees in non-crossing order' do
        source = tree(:r, tree(:g, leaf('x')), tree(:h, leaf('x')))
        target = tree(:r, tree(:h, leaf('x')), tree(:g, leaf('x')))
        result = differ.diff(source, target)
        # No delete/insert pairing should fabricate a move out of the
        # position-preserving optimum.
        result.moves.each do |_si, ti, _|
          expect(ti).to be_a(Integer)
        end
        expect(result.replay_with_moves).to eq(target)
      end
    end
  end

  describe '.apply' do
    it 'replays a script independently' do
      source = tree(:f, leaf('a'))
      target = leaf('a')
      result = described_class::Differ.new.diff(source, target)
      expect(described_class.apply(source, result.operations)).to eq(target)
    end
  end
end
