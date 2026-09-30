require 'spec_helper'

describe Parslet::Indentation do
  include Parslet

  def strip_positions(value)
    case value
    when Parslet::Slice
      value.to_s
    when Hash
      value.each_with_object({}) { |(key, child), memo| memo[key] = strip_positions(child) }
    when Array
      value.map { |child| strip_positions(child) }
    else
      value
    end
  end

  let(:indentation) { Parslet.indentation(comments: '#', comment_lines: :ignore) }
  let(:parser) { BlockLanguage.new(indentation) }

  class BlockLanguage < Parslet::Parser
    def initialize(indentation)
      @indentation = indentation
      super()
    end

    root(:document)
    rule(:document) { block >> @indentation.eof }
    rule(:block) { node_with_children >> (newline >> node_with_children).repeat }
    rule(:node_with_children) { node >> children.maybe }
    rule(:node) { @indentation.same >> word.as(:word) }
    rule(:children) do
      newline >> @indentation.indent >> block.as(:children) >> @indentation.dedent
    end
    rule(:word) { match['a-z'].repeat(1) }
    rule(:newline) { str("\n") }
  end

  it 'parses siblings and nested blocks' do
    input = "a\n  b\n  c\nd\n  e"
    tree = parser.parse(input)

    expect(strip_positions(tree)).to eq([
      { :word => 'a', :children => [{ :word => 'b' }, { :word => 'c' }] },
      { :word => 'd', :children => { :word => 'e' } }
    ])
    expect(tree.first[:word].position.charpos).to eq(0)
    expect(tree.first[:children].map { |child| child[:word].position.charpos }).to eq([4, 8])
  end

  it 'skips configured blank and comment lines before measuring indentation' do
    input = "# outer comment\na\n\n  # inner comment\n  b\n\n"
    tree = parser.parse(input)

    expect(strip_positions(tree)).to eq(
      :word => 'a', :children => { :word => 'b' })
    expect(tree[:children][:word].position.charpos).to eq(39)
  end

  it 'closes all nested levels at EOF' do
    tree = parser.parse("a\n  b\n    c")

    expect(strip_positions(tree)).to eq(
      :word => 'a',
      :children => { :word => 'b', :children => { :word => 'c' } })
  end

  it 'expands tabs with the configured tab width' do
    tab_parser = BlockLanguage.new(Parslet.indentation(tabs: :expand, tab_width: 4))
    tree = tab_parser.parse("a\n\tb\n    c")

    expect(strip_positions(tree)).to eq(
      :word => 'a', :children => [{ :word => 'b' }, { :word => 'c' }])
  end

  it 'can count each tab as one column' do
    tab_parser = BlockLanguage.new(Parslet.indentation(tabs: :character))
    tree = tab_parser.parse("a\n\tb\n\tc")

    expect(strip_positions(tree)).to eq(
      :word => 'a', :children => [{ :word => 'b' }, { :word => 'c' }])
  end

  it 'rejects tabs when spaces are configured' do
    policy = Parslet.indentation(tabs: :reject)
    required = policy.same >> match['a-z'].repeat(1) >> str("\n") >>
      policy.indent >> match['a-z'].repeat(1) >> policy.eof

    expect do
      required.parse("a\n\tb")
    end.to raise_error(Parslet::ParseFailed, /Tab characters are not allowed.*line 2 char 1/)
  end

  it 'reports blank lines at their physical line start' do
    policy = Parslet.indentation(blank_lines: :error)
    required = policy.same >> match['a-z'].repeat(1) >> str("\n") >>
      policy.indent >> match['a-z'].repeat(1) >> policy.eof

    expect do
      required.parse("a\n\n  b")
    end.to raise_error(Parslet::ParseFailed, /Blank lines are not allowed.*line 2 char 1/)
  end

  it 'reports indentation mismatches at the bad line start' do
    policy = Parslet.indentation
    required = policy.same >> match['a-z'].repeat(1) >> str("\n") >>
      policy.indent >> match['a-z'].repeat(1) >> str("\n") >>
      policy.indent >> match['a-z'].repeat(1) >> policy.eof

    expect do
      required.parse("a\n    b\n c")
    end.to raise_error(Parslet::ParseFailed, /Expected indentation of 4.*line 3 char 1/)
  end

  it 'rolls indentation state back after a failed alternative' do
    successful = indentation.indent >> str('x')
    failing_after_indent = indentation.indent >> str('x!')

    source = Parslet::Source.new("  x")
    context = Parslet::Atoms::Context.new(nil)

    success, value = (failing_after_indent | successful).apply(source, context, false)
    expect(success).to be true
    expect(value.last).to eq('x')
    expect(context.indentation_state(indentation).levels).to eq([0, 2])
  end

  it 'restores indentation state when a scope exits' do
    source = Parslet::Source.new("  x")
    context = Parslet::Atoms::Context.new(nil)

    scope { indentation.indent }.apply(source, context, false)

    expect(context.indentation_state(indentation).levels).to eq([0])
  end

  it 'keeps indentation state local to each parse request' do
    expect(strip_positions(parser.parse("a\n  b"))).to eq(
      :word => 'a', :children => { :word => 'b' })
    expect(strip_positions(parser.parse("a"))).to eq(:word => 'a')
  end

  describe 'brackets' do
    class BracketLanguage < Parslet::Parser
      def initialize(indentation)
        @indentation = indentation
        super()
      end

      root(:document)
      rule(:document) { expression >> @indentation.eof }
      rule(:expression) do
        @indentation.open >> value >> newline.maybe >>
          @indentation.same >> value >> @indentation.close
      end
      rule(:value) { match['a-z'].repeat(1) }
      rule(:newline) { str("\n") }
    end

    let(:bracket_parser) { BracketLanguage.new(indentation) }

    it 'ignores indentation while a bracket is open' do
      expect(bracket_parser.parse("(a\n      b)")).to eq("(a\nb)")
    end

    it 'ignores blank and comment continuation lines inside brackets' do
      expect(bracket_parser.parse("(a\n\n  # continuation\n      b)")).to eq("(a\nb)")
    end

    it 'reports an unterminated bracket at EOF' do
      rescue_from = nil
      begin
        bracket_parser.parse("(a\n      b")
      rescue Parslet::ParseFailed => error
        rescue_from = error
      end

      cause = rescue_from.parse_failure_cause.indentation_cause
      expect(cause.to_s).to include('Expected closing bracket')
      expect(cause.to_s).to include('line 2 char 8')
    end
  end

  describe 'packrat cache' do
    it 'separates the same atom at the same position for different stacks' do
      atom = indentation.indent
      source = Parslet::Source.new("  x")
      context = Parslet::Atoms::Context.new(nil)
      state = context.indentation_state(indentation)

      expect(atom.apply(source, context, false).first).to be true
      state.restore([[0], [], 0, 0, 0, false])
      source.bytepos = 0
      state.push(2)

      expect(atom.apply(source, context, false).first).to be false
      expect(state.levels).to eq([0, 2])
    end

    it 'does not let one candidate leave stack state for another at the same position' do
      pushed = indentation.indent >> str('x!')
      accepted = indentation.indent >> str('x')
      source = Parslet::Source.new("  x")
      context = Parslet::Atoms::Context.new(nil)

      expect((pushed | accepted).apply(source, context, false).first).to be true
      expect(context.indentation_state(indentation).levels).to eq([0, 2])
    end
  end
end
