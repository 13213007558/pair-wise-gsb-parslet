require 'spec_helper'

require 'parslet'

describe Parslet::Transform do
  class TinyScopedLanguageParser < Parslet::Parser
    rule(:space) { match('[ \t\n]').repeat }
    rule(:separator) { space >> str(';').maybe >> space }
    rule(:identifier) { match('[a-z]').repeat(1).as(:name) }
    rule(:declaration) { str('let') >> space >> identifier }
    rule(:reference) { identifier.as(:reference) }
    rule(:block) { str('{') >> space >> program_body >> space >> str('}') }
    rule(:statement) do
      (declaration.as(:declaration) | block.as(:block) | reference).
        as(:statement)
    end
    rule(:statement_list) do
      (statement >> (separator >> statement).repeat).maybe.as(:statements)
    end
    rule(:program_body) { statement_list }
    root(:program_body)
  end

  UndefinedReference = Class.new(StandardError)

  class TinyScopeTransform < Parslet::Transform
    inherited_attribute(:scope, { statements: subtree(:statements) }) do
      (root? ? {} : parent.scope).merge(declarations)
    end
    inherited_attribute(:scope, { statement: subtree(:statement) }) do
      parent.parent.scope
    end
    inherited_attribute(:scope, { block: subtree(:block) }) do
      parent.scope
    end
    inherited_attribute(:scope, { name: subtree(:name) }) do
      parent.scope
    end
    inherited_attribute(:scope, { reference: subtree(:reference) }) do
      parent.scope
    end
    inherited_attribute(:scope, { declaration: subtree(:declaration) }) do
      parent.scope
    end
    inherited_attribute(:scope, simple(:name)) do
      parent.scope
    end

    synthesized_attribute(:declarations) do |d|
      d.on(statements: subtree(:statements)) do
        node[:statements].children.each_with_object({}) do |wrapped, result|
          declaration = wrapped[:statement][:declaration]
          result[declaration.value[:name].to_s] = declaration.value[:name] if declaration
        end
      end
      d.on(statement: subtree(:statement)) { { } }
      d.on(block: subtree(:block)) { { } }
      d.on(declaration: subtree(:declaration)) { { } }
      d.on(reference: subtree(:reference)) { { } }
      d.on(name: simple(:name)) { { } }
      d.on(simple(:_)) { { } }
    end

    synthesized_attribute(:type) do |d|
      d.on(statements: subtree(:statements)) do
        node[:statements].children.map { |wrapped| wrapped[:statement].type }
      end
      d.on(statement: subtree(:statement)) { node[:statement].type }
      d.on(declaration: subtree(:declaration)) { :unit }
      d.on(block: subtree(:block)) { :unit }
      d.on(reference: subtree(:reference)) { :variable }
      d.on(name: simple(:name)) { :name }
      d.on(simple(:_)) { :leaf }
    end

    synthesized_attribute(:resolution) do |d|
      d.on(reference: subtree(:reference)) do
        scope[node[:name].value.to_s]
      end
      d.on(simple(:name)) do
        scope[name.to_s]
      end
    end

    synthesized_attribute(:references) do |d|
      d.on(reference: subtree(:reference)) do
        [value[:reference][:name]]
      end
      d.on(statements: subtree(:statements)) do
        node[:statements].children.flat_map do |wrapped|
          wrapped[:statement].references
        end
      end
      d.on(statement: subtree(:statement)) { node[:statement].references }
      d.on(block: subtree(:block)) { node[:block].references }
      d.on(declaration: subtree(:declaration)) { [] }
      d.on(name: simple(:name)) { [] }
      d.on(simple(:_)) { [] }
    end

    synthesized_attribute(:undefined_references) do |d|
      d.on(statements: subtree(:statements)) do
        node[:statements].children.flat_map do |wrapped|
          wrapped[:statement].undefined_references
        end
      end
      d.on(statement: subtree(:statement)) { node[:statement].undefined_references }
      d.on(block: subtree(:block)) { node[:block].undefined_references }
      d.on(reference: subtree(:reference)) do
        name_node = node[:reference][:name]
        name_node.resolution.nil? ? [name_node.value] : []
      end
      d.on(declaration: subtree(:declaration)) { [] }
      d.on(simple(:_)) { [] }
    end

    synthesized_attribute(:check) do |d|
      d.on(statements: subtree(:statements)) do
        next :ok if undefined_references.empty?
        names = undefined_references.map(&:to_s).join(', ')
        raise UndefinedReference, "undefined references: #{names}"
      end
      d.on(simple(:_)) { :ok }
    end
  end

  let(:parser) { TinyScopedLanguageParser.new }
  let(:transform) { TinyScopeTransform.new }
  it "computes inherited scopes and synthesized type/reference attributes" do
    tree = parser.parse("let outer; { let inner; outer; inner }")
    evaluation = transform.attributes_for(tree)

    evaluation.type.should == [:unit, :unit]
    evaluation.references.map(&:to_s).should == ['outer', 'inner']
    evaluation.check.should == :ok
  end

  it "resolves shadowed variables to the nearest declaration" do
    tree = parser.parse("let outer; { let outer; outer }")
    evaluation = transform.attributes_for(tree)
    outer_declaration = tree[:statements][0][:statement][:declaration][:name]
    reference_name = evaluation.root[:statements][1][:statement][:block]
    reference_name = reference_name[:statements][1][:statement][:reference]
    reference_name = reference_name[:name]

    reference_name.resolution.should_not equal(outer_declaration)
    reference_name.resolution.offset.should == 17
    evaluation.undefined_references.should == []
  end

  it "reports undeclared references as Slice objects with source positions" do
    tree = parser.parse("outer\ninner")
    evaluation = transform.attributes_for(tree)

    evaluation.undefined_references.each do |slice|
      slice.should be_a(Parslet::Slice)
    end
    evaluation.undefined_references.map(&:to_s).should == ['outer', 'inner']
    evaluation.undefined_references.map do |slice|
      slice.line_and_column
    end.should == [[1, 1], [2, 1]]

    expect { evaluation.check }.to raise_error(
      UndefinedReference,
      'undefined references: outer, inner'
    )
  end

  it "keeps an attribute cache separate for a node in different parent scopes" do
    name_parser = Class.new(Parslet::Parser) do
      rule(:identifier) { match('[a-z]').repeat(1) }
      root(:identifier)
    end.new
    shared_name = name_parser.parse('x')
    tree = {
      statements: [
        { statement: { reference: { env: 'outer', name: shared_name } } },
        { statement: { reference: { env: 'inner', name: shared_name } } }
      ]
    }
    transform = Parslet::Transform.new do
      inherited_attribute(:scope, { statements: subtree(:statements) }) do
        root? ? {} : parent.scope
      end
      inherited_attribute(:scope, { statement: subtree(:statement) }) do
        parent.parent.scope
      end
      inherited_attribute(:scope, { env: simple(:env), name: subtree(:name) }) do
        { 'x' => env.to_s }
      end
      inherited_attribute(:scope, { name: simple(:name) }) do
        parent.scope
      end
      inherited_attribute(:scope, simple(:name)) do
        parent.scope
      end
      synthesized_attribute(:resolution, simple(:name)) do
        scope[name.to_s]
      end
    end

    evaluation = transform.attributes_for(tree)
    first_name = evaluation.root[:statements][0][:statement][:reference][:name]
    second_name = evaluation.root[:statements][1][:statement][:reference][:name]

    first_name.value.should equal(shared_name)
    second_name.value.should equal(shared_name)
    first_name.resolution.should == 'outer'
    second_name.resolution.should == 'inner'
  end

  describe Parslet::Transform::AttributeCycle do
    it "reports the concrete dependency chain" do
      tree = { :a => { :marker => 'a' }, :b => { :marker => 'b' } }
      transform = Parslet::Transform.new do
        synthesized_attribute(:ping, marker: 'a') do
          parent[:b].pong
        end
        synthesized_attribute(:pong, marker: 'b') do
          parent[:a].ping
        end
      end

      expect do
        transform.attributes_for(tree).root[:a].ping
      end.to raise_error(Parslet::Transform::AttributeCycle) do |error|
        error.message.should ==
          'circular attribute dependency: $.a.ping -> $.b.pong -> $.a.ping'
        paths = error.dependency_chain.map do |dependency|
          [dependency.node.path, dependency.name]
        end
        paths.should == [
          ['$.a', :ping],
          ['$.b', :pong],
          ['$.a', :ping]
        ]
      end
    end
  end

  it "keeps ordinary post-order transformation unchanged" do
    transform = Parslet::Transform.new do
      rule(:value => simple(:x)) { x.to_s + '!' }
      rule(:outer => subtree(:outer)) { { :rewritten => outer } }
    end

    transform.apply(outer: { value: 'x' }).should ==
      { rewritten: 'x!' }
  end

  it "keeps inherited and instance rules for the same synthesized attribute" do
    base = Class.new(Parslet::Transform) do
      synthesized_attribute(:value, kind: 'leaf') { :base }
    end
    transform = base.new do
      synthesized_attribute(:value, kind: 'override') { :override }
    end

    transform.attributes_for(kind: 'leaf').value.should == :base
    transform.attributes_for(kind: 'override').value.should == :override
  end

  it "initializes an inherited attribute at the root with root:" do
    transform = Parslet::Transform.new do
      inherited_attribute(:answer, root: 7)
      synthesized_attribute(:copy, simple(:_)) { answer }
    end

    transform.attributes_for(1).copy.should == 7
  end

  it "does not compute an attribute until it is requested" do
    calculated = false
    transform = Parslet::Transform.new do
      synthesized_attribute(:answer, simple(:_)) do
        calculated = true
        7
      end
    end

    evaluation = transform.attributes_for(1)
    calculated.should == false
    evaluation.answer.should == 7
    calculated.should == true
  end
end
