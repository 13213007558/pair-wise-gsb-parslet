require 'spec_helper'

# Acceptance tests for opt-in left recursion support. Left-recursive rules
# (direct, like expr = expr '+' term, and indirect, spanning several rules)
# are grown iteratively from a seed parse; ordered choice semantics are
# preserved.
#
describe "Left recursion" do
  describe "operator precedence (direct left recursion)" do
    class ArithmeticParser < Parslet::Parser
      rule(:expression) do
        (expression.as(:l) >> str('+').as(:op) >> term.as(:r)).as(:plus) |
          term
      end
      rule(:term) do
        (term.as(:l) >> str('*').as(:op) >> integer.as(:r)).as(:mult) |
          integer
      end
      rule(:integer) { match['0-9'].repeat(1).as(:int) }
      root(:expression)
    end

    let(:parser) { ArithmeticParser.new }

    it "parses a single integer" do
      parser.parse('42', left_recursion: true).should == { int: '42' }
    end

    it "grows the seed to the longest parse" do
      parser.parse('1+2', left_recursion: true).should == {
        plus: { l: { int: '1' }, op: '+', r: { int: '2' } } }
    end

    it "respects operator precedence" do
      parser.parse('1+2*3+4', left_recursion: true).should == {
        plus: {
          l: { plus: {
            l: { int: '1' },
            op: '+',
            r: { mult: { l: { int: '2' }, op: '*', r: { int: '3' } } } } },
          op: '+',
          r: { int: '4' } } }
    end

    it "is left associative" do
      parser.parse('1+2+3', left_recursion: true).should == {
        plus: {
          l: { plus: { l: { int: '1' }, op: '+', r: { int: '2' } } },
          op: '+',
          r: { int: '3' } } }
    end

    it "parses a long chain without excessive recursion" do
      input = (['1'] * 200).join('+')
      tree = parser.parse(input, left_recursion: true)
      199.times { tree = tree[:plus][:l] }
      tree.should == { int: '1' }
    end
  end

  describe "ordered choice semantics" do
    it "prefers an earlier alternative even if a recursive one is longer" do
      parser = Class.new(Parslet::Parser) do
        rule(:a) { str('1') | a >> str('1') }
        root(:a)
      end.new

      parser.parse('1', left_recursion: true).should == '1'
      expect {
        parser.parse('11', left_recursion: true)
      }.to raise_error(Parslet::ParseFailed, /Don't know what to do/)
    end

    it "uses recursive alternatives when earlier ones fail" do
      parser = Class.new(Parslet::Parser) do
        rule(:a) { a >> str('1') | str('1') }
        root(:a)
      end.new

      parser.parse('111', left_recursion: true).should == '111'
    end
  end

  describe "indirect left recursion" do
    class MutualParser < Parslet::Parser
      rule(:aa) { (bb >> str('x')) | str('1') }
      rule(:bb) { (aa >> str('y')) | str('2') }
      root(:aa)
    end

    let(:parser) { MutualParser.new }

    it "parses through a two-rule cycle" do
      parser.parse('1yx', left_recursion: true).should == '1yx'
    end

    it "parses the non-recursive base cases" do
      parser.parse('1', left_recursion: true).should == '1'
      parser.parse('2x', left_recursion: true).should == '2x'
    end

    it "fails input the cycle cannot derive" do
      expect {
        parser.parse('1y', left_recursion: true)
      }.to raise_error(Parslet::ParseFailed)
    end

    it "parses through a three-rule cycle" do
      parser = Class.new(Parslet::Parser) do
        rule(:a) { b >> str('!') | str('a') }
        rule(:b) { c }
        rule(:c) { a >> str('?') | str('c') }
        root(:a)
      end.new

      parser.parse('a?!', left_recursion: true).should == 'a?!'
    end
  end

  describe "failing left-recursive branches" do
    let(:parser) { ArithmeticParser.new }

    it "fails when the recursive branch cannot be completed" do
      expect {
        parser.parse('1+', left_recursion: true)
      }.to raise_error(Parslet::ParseFailed, /Don't know what to do with "\+"/)
    end

    it "reports the farthest error position with the deepest reporter" do
      reporter = Parslet::ErrorReporter::Deepest.new
      expect {
        parser.parse('1+', left_recursion: true, reporter: reporter)
      }.to raise_error(Parslet::ParseFailed) { |error|
        error.parse_failure_cause.pos.bytepos.should == 2
        error.message.should =~ /Premature end of input/
      }
    end

    it "reports the farthest error position deep inside the input" do
      reporter = Parslet::ErrorReporter::Deepest.new
      expect {
        parser.parse('1+2*', left_recursion: true, reporter: reporter)
      }.to raise_error(Parslet::ParseFailed) { |error|
        error.parse_failure_cause.pos.bytepos.should == 4
      }
    end
  end

  describe "captures and scopes during seed growth" do
    it "keeps the captures of the winning candidate" do
      parser = Class.new(Parslet::Parser) do
        rule(:number) { match['0-9'].repeat(1) }
        rule(:sum) do
          (sum >> str('+') >> number.capture(:last)) |
            number.capture(:last)
        end
        rule(:top) do
          sum >> str('=') >> dynamic { |src, ctx| str(ctx.captures[:last].to_s) }
        end
        root(:top)
      end.new

      # Only if captures from the winning (longest) candidate are kept
      # will the dynamic parser see '23' here.
      parser.parse('1+23=23', left_recursion: true).should == '1+23=23'
    end

    it "does not leak scope frames or captures across candidates" do
      parser = Class.new(Parslet::Parser) do
        rule(:number) { match['0-9'].repeat(1) }
        rule(:sum) do
          scope {
            (sum >> str('+') >> number.capture(:inner)) |
              number.capture(:inner) }
        end
        rule(:top) do
          str('>').capture(:marker) >> sum >>
            dynamic { |s, ctx| str(ctx.captures[:marker].to_s) }
        end
        root(:top)
      end.new

      parser.parse('>1+2>', left_recursion: true).should == '>1+2>'
    end
  end

  describe "diagnostics for cycles that cannot make progress" do
    it "diagnoses unbounded repetition of a nullable match" do
      expect {
        Parslet.str('').repeat.parse('')
      }.to raise_error(Parslet::InfiniteLoopError, /without consuming/)
    end

    it "diagnoses nullable left-recursive cycles used in a repetition" do
      parser = Class.new(Parslet::Parser) do
        rule(:top) { emptyable.repeat }
        rule(:emptyable) { emptyable | str('x').maybe }
        root(:top)
      end.new

      expect {
        parser.parse('', left_recursion: true)
      }.to raise_error(Parslet::InfiniteLoopError)
    end

    it "fails (instead of looping) on cycles without a base alternative" do
      parser = Class.new(Parslet::Parser) do
        rule(:a) { a >> str('x') }
        root(:a)
      end.new

      expect {
        parser.parse('x', left_recursion: true)
      }.to raise_error(Parslet::ParseFailed)
    end
  end

  describe "opt-in behaviour" do
    it "does not enable left recursion unless requested" do
      expect {
        ArithmeticParser.new.parse('1+2')
      }.to raise_error(SystemStackError)
    end

    it "leaves ordinary grammars untouched" do
      parser = Class.new(Parslet::Parser) do
        rule(:word) { match['a-z'].repeat(1) }
        root(:word)
      end.new

      parser.parse('hello', left_recursion: true).should == 'hello'
    end
  end
end
