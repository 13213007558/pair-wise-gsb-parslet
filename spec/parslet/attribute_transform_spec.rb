require 'spec_helper'
require 'parslet'

describe Parslet::AttributeTransform do
  class UndefinedReferenceError < StandardError
    attr_reader :name
    attr_reader :slice

    def initialize(name, slice)
      @name = name
      @slice = slice
      super("undefined reference `#{name}`")
    end
  end

  class ScopeParser < Parslet::Parser
    root(:program)

    rule(:space) { match['\s'].repeat(1) }
    rule(:space?) { space.maybe }
    rule(:program) { block }
    rule(:block) {
      str('{') >> space? >> statement.repeat.as(:body) >> str('}') >> space?
    }
    rule(:statement) {
      declaration.as(:declaration) | reference.as(:reference) |
        block.as(:block)
    }
    rule(:declaration) {
      str('let') >> space >> identifier.as(:name) >> space?
    }
    rule(:reference) { identifier.as(:name) >> space? }
    rule(:identifier) { match['a-z'].repeat(1) }
  end

  class ScopeAttributes < Parslet::AttributeTransform
    inherited_attribute(:scope, subtree(:_)) do |d|
      d.node.parent.inherited(:scope)
    end

    inherited_attribute(:scope, body: subtree(:_body)) do |d|
      scope = d.node.root? ? {} : d.node.parent.inherited(:scope)
      d.node[:body].synthesized(:locals).each do |name, declaration|
        scope = scope.merge(name => declaration)
      end
      scope
    end

    inherited_attribute(:scope, block: subtree(:_block)) do |d|
      d.node.parent.inherited(:scope)
    end

    synthesized_attribute(:locals, subtree(:statements)) do |d|
      d.node.raw.each_with_object({}) do |statement, locals|
        declaration = statement[:declaration] if statement.is_a?(Hash)
        locals[declaration[:name].to_s] = declaration[:name] if declaration
      end
    end

    synthesized_attribute(:type, body: subtree(:_body)) { :block }
    synthesized_attribute(:type, declaration: subtree(:_)) { :declaration }
    synthesized_attribute(:type, reference: subtree(:_)) { :reference }
    synthesized_attribute(:type, simple(:_value)) { :name }

    synthesized_attribute(:references, subtree(:_)) do |d|
      d.node.children.map { |child|
        child.synthesized(:references)
      }.inject([], :+)
    end

    synthesized_attribute(:references, simple(:_value)) { [] }

    synthesized_attribute(:references, body: subtree(:_body)) do |d|
      d.node[:body].synthesized(:references)
    end

    synthesized_attribute(:references, reference: { name: simple(:name) }) do |d|
      scope = d.node.inherited(:scope)
      name = d.name.to_s
      unless scope.key?(name)
        raise UndefinedReferenceError.new(
          d.name.to_s, d.name)
      end
      [{ :name => d.name, :declaration => scope[name] }]
    end
  end

  let(:parser) { ScopeParser.new }
  let(:attributes) { ScopeAttributes.new }

  it 'computes inherited and synthesized attributes through local scopes' do
    source = "{ let x { let x x } x }"
    root = attributes.analyze(parser.parse(source))

    expect(root.synthesized(:type)).to eq(:block)
    references = root.synthesized(:references)
    expect(references.map { |reference| reference[:name].to_s }).to eq(['x', 'x'])
    expect(references[0][:declaration].offset).to eq(14)
    expect(references[1][:declaration].offset).to eq(6)
  end

  it 'locates an undeclared reference at its input slice' do
    source = "{ let x\n  { let x\n    x y\n  }\n  x\n}"
    root = attributes.analyze(parser.parse(source))

    expect {
      root.synthesized(:references)
    }.to raise_error(
      UndefinedReferenceError,
      'undefined reference `y`'
    ) { |error|
      expect(error.slice).to be_a(Parslet::Slice)
      expect(error.slice.to_s).to eq('y')
      expect(error.slice.offset).to eq(24)
      expect(error.slice.line_and_column).to eq([3, 7])
    }
  end

  it 'keeps caches separate for equal nodes in different parent environments' do
    source = 'shadowed language'
    outer_declaration = {
      :declaration => { :name => Parslet::Slice.new(
        Parslet::Position.new(source, 0), 'x') } }
    inner_declaration = {
      :declaration => { :name => Parslet::Slice.new(
        Parslet::Position.new(source, 9), 'x') } }
    shared_reference = {
      :reference => { :name => Parslet::Slice.new(
        Parslet::Position.new(source, 17), 'x') } }
    tree = {
      :body => [
        outer_declaration,
        shared_reference,
        { :block => { :body => [inner_declaration, shared_reference] } }
      ]
    }

    root = attributes.analyze(tree)
    references = root.synthesized(:references)

    expect(references.size).to eq(2)
    expect(references[0][:declaration]).to equal(outer_declaration[:declaration][:name])
    expect(references[1][:declaration]).to equal(inner_declaration[:declaration][:name])
  end

  it 'computes attributes lazily and memoizes one node occurrence' do
    computations = []
    transform = Parslet::AttributeTransform.new do
      synthesized_attribute(:answer, simple(:_value)) do |d|
        d.computations << :answer
        42
      end
    end

    root = transform.analyze({ :value => 'value' }, nil,
      :computations => computations)
    expect(computations).to eq([])
    expect(root[:value].synthesized(:answer)).to eq(42)
    expect(root[:value].synthesized(:answer)).to eq(42)
    expect(computations).to eq([:answer])
  end

  it 'reports the concrete chain in a cyclic attribute definition' do
    transform = Parslet::AttributeTransform.new do
      inherited_attribute(:down, subtree(:_)) do |d|
        d.node.parent.inherited(:down)
      end

      inherited_attribute(:down, child: subtree(:_child)) do |d|
        d.node[:child].inherited(:down)
      end

      synthesized_attribute(:up, subtree(:_)) do |d|
        d.node.inherited(:down)
      end
    end
    root = transform.analyze(:child => {})

    expect {
      root.synthesized(:up)
    }.to raise_error(
      Parslet::AttributeTransform::AttributeCycleError,
      /down \(inherited\) at \$ -> down \(inherited\) at \$\.child -> down \(inherited\) at \$/
    ) { |error|
      expect(error.chain).to eq([
        'down (inherited) at $',
        'down (inherited) at $.child',
        'down (inherited) at $'
      ])
    }
  end

  it 'uses root inherited attributes as the starting environment' do
    transform = Parslet::AttributeTransform.new do
      inherited_attribute(:scope, subtree(:_)) do |d|
        d.node.root? ? {} : d.node.parent.inherited(:scope)
      end
      synthesized_attribute(:scope, subtree(:_)) do |d|
        d.node.inherited(:scope)
      end
    end

    root = transform.analyze({}, :scope => { :x => 'outer' })

    expect(root.synthesized(:scope)).to eq(:x => 'outer')
  end

  it 'treats leaf occurrences as childless positions' do
    root = attributes.analyze({ :name => 'value' })

    expect(root[:name].children).to eq([])
    expect(root[:name][0]).to be_nil
  end
end
