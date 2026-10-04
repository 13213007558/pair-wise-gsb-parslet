require 'spec_helper'

require 'parslet'

describe Parslet::Transform, "graph mode" do
  include Parslet

  Node = Struct.new(:child, :back)
  #
  #   dag = { :a => shared, :b => shared }
  #
  let(:shared) { { :expr => 'x' } }
  let(:dag) { { :a => shared, :b => shared } }

  def counting_transform(calls)
    Parslet::Transform.new do
      rule(:expr => simple(:value)) do |d|
        calls[:expr] += 1
        { :value => d[:value] }
      end

      rule(:a => subtree(:a), :b => subtree(:b)) do |d|
        calls[:root] += 1
        { :left => d[:a], :right => d[:b] }
      end
    end
  end

  describe "shared nodes (DAG)" do
    let(:calls) { Hash.new(0) }

    it "transforms each original container node exactly once" do
      result = counting_transform(calls).apply(dag, nil, graph: true)

      result.should == {
        :left  => { :value => 'x' },
        :right => { :value => 'x' }
      }
      calls.should == { :expr => 1, :root => 1 }
      # The DAG has exactly three unique container nodes and the rules
      # fire exactly that many times.
      unique_nodes = [dag, dag[:a], dag[:b]].uniq(&:object_id).size
      calls.values.reduce(:+).should == unique_nodes
    end

    it "preserves sharing through object identity in the result" do
      result = counting_transform(calls).apply(dag, nil, graph: true)

      result[:left].should equal(result[:right])
      result[:left][:value].should == 'x'
    end

    it "shares one result across both incoming edges" do
      result = counting_transform(calls).apply(dag, nil, graph: true)

      incoming = [result[:left], result[:right]]
      incoming.map(&:object_id).uniq.size.should == 1
    end

    it "keeps pattern bindings local to each parent context" do
      seen = []
      t = Parslet::Transform.new do
        rule(:expr => simple(:value)) do |d|
          seen << d.keys
          d[:value]
        end
        rule(:a => simple(:a), :b => simple(:b)) do |d|
          seen << d.keys
          [d[:a], d[:b]]
        end
      end

      result = t.apply(dag, nil, graph: true)

      result.should == ['x', 'x']
      seen.should == [[:value], [:a, :b]]
      seen.each do |keys|
        # Bindings from one rule match never leak into another match.
        (keys - [:value]).should be_empty unless keys == [:a, :b]
      end
    end

    it "visits the shared node per edge in ordinary tree mode" do
      counting_transform(calls).apply(dag)

      calls.should == { :expr => 2, :root => 1 }
    end

    it "can be enabled for the whole transform instance" do
      t = Parslet::Transform.new(graph: true) do
        rule(:expr => simple(:value)) { |d| { :value => d[:value] } }
        rule(:a => simple(:a), :b => simple(:b)) do |d|
          { :left => d[:a], :right => d[:b] }
        end
      end

      result = t.apply(dag)
      result[:left].should equal(result[:right])
    end
  end

  describe "cycles" do
    # Minimal cycle: node = { :next => node }
    let(:cycle_node) do
      node = { :next => nil }
      node[:next] = node
      node
    end

    it "builds a controlled reference with a cycle-aware rule" do
      calls = Hash.new(0)
      t = Parslet::Transform.new do
        rule(:next => simple(:child), cycle: true) do |d, _|
          calls[:node] += 1
          Node.new(d[:child], nil)
        end
      end

      result = t.apply(cycle_node, nil, graph: true)

      result.should be_a(Node)
      result.child.should be_a(Parslet::Transform::Reference)
      result.child.target.should equal(result)
      calls.should == { :node => 1 }
    end

    it "resolves references that remain inside Hash and Array results" do
      t = Parslet::Transform.new do
        rule(:next => simple(:child), cycle: true) do |d, _|
          { :child => d[:child], :again => [d[:child]] }
        end
      end

      result = t.apply(cycle_node, nil, graph: true)

      result[:child].should equal(result)
      result[:again].first.should equal(result)
    end

    it "shares one controlled reference across all back edges to a node" do
      two_edge = { :one => nil, :two => nil }
      two_edge[:one] = two_edge
      two_edge[:two] = two_edge
      seen = []
      t = Parslet::Transform.new do
        rule(:one => simple(:a), :two => simple(:b), cycle: true) do |d, reference|
          seen << d[:a]
          seen << d[:b]
          seen << reference
          { :k => d[:a] }
        end
      end

      result = t.apply(two_edge, nil, graph: true)

      seen.map(&:object_id).uniq.size.should == 1
      result[:k].should equal(result)
    end

    it "reports the full chain for a cycle longer than one node" do
      second = { :next => nil }
      first = { :next => second }
      second[:next] = first
      t = Parslet::Transform.new do
        rule(:next => simple(:child)) { |d| d[:child] }
      end

      lambda do
        t.apply(first, nil, graph: true)
      end.should raise_error(Parslet::Transform::CycleError) do |error|
        error.reference_chain.size.should == 3
        error.reference_chain.first.should equal(first)
        error.reference_chain[1].should equal(second)
        error.reference_chain.last.should equal(first)
      end
    end

    it "exposes the forward reference through the reference helper" do
      t = Parslet::Transform.new do
        rule(:next => simple(:child), cycle: true) do
          { :child => child, :back => reference }
        end
      end

      result = t.apply(cycle_node, nil, graph: true)

      result[:back].should equal(result)
      result[:child].should equal(result)
    end

    it "raises CycleError with the reference chain for undeclared cycles" do
      t = Parslet::Transform.new do
        rule(:next => simple(:child)) { |d| d[:child] }
      end

      lambda do
        t.apply(cycle_node, nil, graph: true)
      end.should raise_error(Parslet::Transform::CycleError) do |error|
        error.reference_chain.first.should equal(cycle_node)
        error.reference_chain.last.should equal(cycle_node)
        error.message.should include('cycle detected')
      end
    end

    it "does not modify the input graph and leaves no reference in plain data" do
      t = Parslet::Transform.new do
        rule(:next => simple(:child)) { |d| d[:child] }
      end

      lambda do
        t.apply(cycle_node, nil, graph: true)
      end.should raise_error(Parslet::Transform::CycleError)

      cycle_node.keys.should == [:next]
      cycle_node[:next].should equal(cycle_node)

      # A sibling subtree transforms before the cyclic branch fails; the
      # input must still be untouched (no in-place rewriting).
      mixed = { :ok => { :leaf => 'v' }, :loop => cycle_node }
      ok_snapshot = mixed[:ok].dup
      lambda do
        t.apply(mixed, nil, graph: true)
      end.should raise_error(Parslet::Transform::CycleError)
      mixed[:ok].should == ok_snapshot
      mixed[:ok][:leaf].should == 'v'
      mixed[:loop].should equal(cycle_node)

      successful = Parslet::Transform.new do
        rule(:next => simple(:child), cycle: true) do |d, _|
          { :child => d[:child] }
        end
      end
      result = successful.apply(cycle_node, nil, graph: true)

      result[:child].should equal(result)
      seen = {}
      contains_reference = lambda do |object|
        return false if seen.include?(object.object_id)
        seen[object.object_id] = true
        return true if object.is_a?(Parslet::Transform::Reference)
        values = object.is_a?(Hash) ? object.values :
                 object.is_a?(Array) ? object : []
        values.any? { |value| contains_reference.call(value) }
      end
      contains_reference.call(result).should == false
    end
  end
end
