require 'spec_helper'

require 'parslet'

describe Parslet::Transform, "graph mode" do
  include Parslet

  ExprNode = Struct.new(:value, keyword_init: true)
  RootNode = Struct.new(:tag, :left, :right, keyword_init: true)

  def dag_transform(graph_options = {})
    calls = { expr: 0, root: 0 }
    transform = Parslet::Transform.new(graph: true, **graph_options) do
      rule({ expr: simple(:v), lit: simple(:x) }, recursive: false) do |bindings|
        calls[:expr] += 1
        ExprNode.new(value: bindings[:x])
      end
      rule(root: simple(:v), left: simple(:l), right: simple(:r)) do |bindings|
        calls[:root] += 1
        RootNode.new(tag: bindings[:v], left: bindings[:l], right: bindings[:r])
      end
    end
    [transform, calls]
  end

  def shared_dag
    shared = { expr: 'n', lit: '1' }
    first = { root: 'first', left: shared, right: shared }
    second = { root: 'second', left: shared, right: shared }
    [shared, [first, second]]
  end

  it 'transforms a shared subtree once and keeps the result shared' do
    transform, calls = dag_transform
    _shared, dag = shared_dag

    result = transform.apply(dag)

    expect(result).to eq([
      RootNode.new(tag: 'first',
                   left: ExprNode.new(value: '1'),
                   right: ExprNode.new(value: '1')),
      RootNode.new(tag: 'second',
                   left: ExprNode.new(value: '1'),
                   right: ExprNode.new(value: '1'))
    ])

    first_root, second_root = result
    expect(first_root.left).to equal(first_root.right)
    expect(second_root.left).to equal(second_root.right)
    expect(first_root.left).to equal(second_root.left)

    # One call for the unique Expr node, one for each unique Root node.
    expect(calls).to eq(expr: 1, root: 2)
  end

  it 'keeps sharing when both entry roots are transformed in one call' do
    separate_transform, _separate_calls = dag_transform
    transform, calls = dag_transform
    shared, dag = shared_dag

    separate_transform.apply(dag[0])
    separate_transform.apply(dag[1])
    result = transform.apply(dag)
    expect(result[0].left).to equal(result[1].left)
    expect(result[0].left.equal?(shared)).to be(false)
    expect(calls).to eq(expr: 1, root: 2)
  end

  it 'can be enabled per call while the same instance serves tree mode' do
    transform, calls = dag_transform
    _shared, dag = shared_dag

    tree_result = transform.apply(dag, nil, graph: false)
    expect(tree_result[0].left).not_to equal(tree_result[1].left)

    graph_result = transform.apply(dag, nil, graph: true)
    expect(graph_result[0].left).to equal(graph_result[1].left)
  end

  it 'identifies nodes by identity, not value equality' do
    transform, calls = dag_transform
    first = { expr: 'n', lit: 'x' }
    second = { expr: 'n', lit: 'x' }

    transform.apply([first, second])

    expect(calls[:expr]).to eq(2)
  end

  it 'does not let pattern bindings of one parent leak into another parent' do
    bound = []
    transform = Parslet::Transform.new(graph: true) do
      rule(left_child: simple(:c)) do |bindings|
        { side: 'left', value: bindings[:c] }
      end
      rule(right_child: simple(:c)) do |bindings|
        { side: 'right', value: bindings[:c] }
      end
      rule(name: simple(:name),
           left: subtree(:l), right: subtree(:r)) do |bindings|
        bound << bindings.dup
        unless bindings[:l] == { side: 'left', value: 'L' } &&
               bindings[:r] == { side: 'right', value: 'R' }
          raise "bindings leaked between parents: #{bindings.inspect}"
        end
        { parent: bindings[:name], left: bindings[:l], right: bindings[:r] }
      end
    end

    left_kid = { left_child: 'L' }
    right_kid = { right_child: 'R' }
    first = { name: 'a', left: left_kid, right: right_kid }
    second = { name: 'b', left: left_kid, right: right_kid }

    result = transform.apply([first, second])

    expect(result[0][:parent]).to eq('a')
    expect(result[1][:parent]).to eq('b')
    expect(result[0][:left]).to equal(result[1][:left])
    expect(result[0][:right]).to equal(result[1][:right])
    expect(bound.map { |bindings| bindings[:name] }).to eq(%w[a b])
  end

  describe 'cyclic graphs' do
    CycleNode = Struct.new(:name, :next, keyword_init: true)

    def self_cycle
      node = { name: 'only' }
      node[:next] = node
      node
    end

    it 'lets a declared rule build an identity-preserving cycle via a ref' do
      rule_calls = 0
      transform = Parslet::Transform.new(graph: true) do
        rule({ name: simple(:name), next: simple(:nxt) }, recursive: true) do |bindings, ref|
          rule_calls += 1
          node = CycleNode.new(name: bindings[:name], next: nil)
          ref.resolve!(node)
          node.next = node
          node
        end
      end

      result = transform.apply(self_cycle)

      expect(result.name).to eq('only')
      expect(result.next).to equal(result)
      expect(rule_calls).to eq(1)
    end

    it 'passes the controlled ref as the local `ref` binding to arity-0 blocks' do
      transform = Parslet::Transform.new(graph: true) do
        rule({ name: simple(:name), next: simple(:nxt) }, recursive: true) do
          node = CycleNode.new(name: name, next: nil)
          ref.resolve!(node)
          node.next = node
          node
        end
      end

      result = transform.apply(self_cycle)
      expect(result.next).to equal(result)
    end

    it 'raises a reference chain when a cycle reaches an undeclared rule' do
      transform = Parslet::Transform.new(graph: true) do
        rule(name: simple(:name), next: simple(:nxt)) do |bindings|
          CycleNode.new(name: bindings[:name], next: bindings[:nxt])
        end
      end

      error = nil
      begin
        transform.apply(self_cycle)
      rescue Parslet::Transform::CyclicReferenceError => exception
        error = exception
      end

      expect(error).to be_a(Parslet::Transform::CyclicReferenceError)
      expect(error.message).to include('cyclic reference')
      expect(error.message).to include('recursive: true')
      expect(error.message).to include('Reference chain')
      expect(error.message).to include('[:next]')
    end

    it 'raises when no rule matches the cyclic node, with the chain attached' do
      transform = Parslet::Transform.new(graph: true)

      expect do
        transform.apply(self_cycle)
      end.to raise_error(Parslet::Transform::CyclicReferenceError, /Reference chain/)
    end

    it 'supports a minimal two-node cycle and calls each unique node once' do
      calls = 0
      transform = Parslet::Transform.new(graph: true) do
        rule({ name: simple(:name), next: simple(:nxt) }, recursive: true) do |bindings, ref|
          calls += 1
          CycleNode.new(name: bindings[:name], next: bindings[:nxt])
        end
      end

      first = { name: 'first' }
      second = { name: 'second', next: first }
      first[:next] = second

      result = transform.apply(first)

      expect(result.next.name).to eq('second')
      expect(result.next.next.name).to eq('first')
      # The back edge is a controlled reference that resolves to the first
      # node: sharing is preserved through one shared RecursiveRef object.
      expect(result.next.next).to be_a(Parslet::Transform::RecursiveRef)
      expect(result.next.next.__getobj__).to equal(result)
      expect(result.next.name).to eq('second')
      expect(calls).to eq(2)
    end
  end

  describe 'failure handling' do
    it 'does not modify the input graph when a rule raises' do
      transform = Parslet::Transform.new(graph: true) do
        rule(value: simple(:v)) do
          raise 'boom'
        end
      end

      input = { value: 'x' }
      expect { transform.apply(input) }.to raise_error('boom')
      expect(input).to eq(value: 'x')

      # The failed call's cache must not poison a later call.
      quiet = Parslet::Transform.new(graph: true) do
        rule(value: simple(:v)) { |bindings| bindings[:v].upcase }
      end
      expect(quiet.apply(input)).to eq('X')
    end

    it 'never writes through a frozen cyclic input while reporting the cycle' do
      node = { name: 'only' }
      node[:next] = node
      node.freeze

      transform = Parslet::Transform.new(graph: true)
      expect { transform.apply(node) }.to raise_error(
        Parslet::Transform::CyclicReferenceError)
      expect(node.frozen?).to be(true)
      expect { node[:next] }.not_to raise_error
    end

    it 'leaves the input untouched even on a successful graph transform' do
      transform, _calls = dag_transform
      _shared, dag = shared_dag
      snapshot = Marshal.load(Marshal.dump(dag))

      transform.apply(dag)

      expect(dag).to eq(snapshot)
    end
  end

  it 'keeps plain tree mode free of the graph session object' do
    transform = Parslet::Transform.new do
      rule(expr: simple(:v), lit: simple(:x)) { |bindings|
        ExprNode.new(value: bindings[:x]) }
    end
    flexmock(Parslet::Transform::GraphSession)
      .should_receive(:new).never

    transform.apply({ expr: 'n', lit: '1' })
  end
end
