require 'spec_helper'

# Specs for opt-in left recursion support. With left recursion enabled,
# rules may refer to themselves in leftmost position, directly or through
# other rules:
#
#   rule(:expr) { expr >> str('+') >> term | term }
#
# The rules are evaluated with a seed-growing scheme: a failing seed is
# installed for the recursive occurrence, the body is evaluated, and the
# result is then grown by reevaluating the body with the best result so
# far until no more input can be consumed (progress condition).
#
describe 'Left recursion' do
  describe 'direct left recursion: operator precedence' do
    class LeftRecArithmeticParser < Parslet::Parser
      left_recursion

      rule(:expr)   { (expr.as(:l) >> str('+') >> term.as(:r)).as(:plus) | term }
      rule(:term)   { (term.as(:l) >> str('*') >> factor.as(:r)).as(:mult) | factor }
      rule(:factor) { match['0-9'].repeat(1).as(:int) | str('(') >> expr >> str(')') }

      root :expr
    end

    let(:parser) { LeftRecArithmeticParser.new }

    it 'parses a single factor' do
      parser.parse('42').should == { int: '42' }
    end

    it 'gives * higher precedence than +' do
      parser.parse('1+2*3').should ==
        { plus: { l: { int: '1' }, r: { mult: { l: { int: '2' }, r: { int: '3' } } } } }
      parser.parse('1*2+3').should ==
        { plus: { l: { mult: { l: { int: '1' }, r: { int: '2' } } }, r: { int: '3' } } }
    end

    it 'is left associative' do
      parser.parse('1+2+3').should ==
        { plus: { l: { plus: { l: { int: '1' }, r: { int: '2' } } }, r: { int: '3' } } }
    end

    it 'grows the match over many iterations' do
      parser.parse('1+2+3+4').should ==
        { plus: { l: { plus: { l: { plus: { l: { int: '1' }, r: { int: '2' } } },
                               r: { int: '3' } } },
                  r: { int: '4' } } }
    end

    it 'handles parentheses' do
      parser.parse('(1+2)*3').should ==
        { mult: { l: { plus: { l: { int: '1' }, r: { int: '2' } } }, r: { int: '3' } } }
    end

    it 'applies left recursion when parsing a sub-rule directly' do
      parser.expr.parse('1+2').should ==
        { plus: { l: { int: '1' }, r: { int: '2' } } }
    end

    it 'parses repeatedly with the same parser instance' do
      parser.parse('1+2').should == { plus: { l: { int: '1' }, r: { int: '2' } } }
      parser.parse('3*4').should == { mult: { l: { int: '3' }, r: { int: '4' } } }
    end

    describe 'a left recursive branch that ultimately fails' do
      it 'reports the farthest error position with the deepest reporter' do
        cause = catch_failed_parse {
          parser.parse('1+2*', reporter: Parslet::ErrorReporter::Deepest.new) }
        cause.pos.charpos.should == 4
        cause.to_s.should include('line 1 char 5')
      end

      it 'reports unconsumed input after the best match with the tree reporter' do
        cause = catch_failed_parse { parser.parse('1+2*') }
        cause.pos.charpos.should == 3
        cause.to_s.should include('line 1 char 4')
      end

      it 'points at the end of input for a dangling operator' do
        cause = catch_failed_parse {
          parser.parse('1+', reporter: Parslet::ErrorReporter::Deepest.new) }
        cause.pos.charpos.should == 2
      end
    end
  end

  describe 'indirect left recursion through a two-rule cycle' do
    class MutualLeftRecursionParser < Parslet::Parser
      left_recursion

      rule(:a) { (b >> str('!')).as(:a) | str('x').as(:x) }
      rule(:b) { (a >> str('?')).as(:b) | str('y').as(:y) }

      root :a
    end

    let(:parser) { MutualLeftRecursionParser.new }

    it 'matches the base case' do
      parser.parse('x').should == { x: 'x' }
    end

    it 'grows through the cycle' do
      parser.parse('x?!').should == { a: { b: { x: 'x' } } }
    end

    it 'fails cleanly when the recursive branch cannot be completed' do
      expect { parser.parse('y') }.to raise_error(Parslet::ParseFailed)
    end
  end

  describe 'indirect left recursion through a three-rule cycle' do
    class IndirectLeftRecursionParser < Parslet::Parser
      left_recursion

      rule(:a) { (b >> str('!')).as(:a) | str('x').as(:x) }
      rule(:b) { (c >> str('?')).as(:b) | str('y').as(:y) }
      rule(:c) { (a >> str('%')).as(:c) | str('z').as(:z) }

      root :a
    end

    it 'grows through all three rules' do
      IndirectLeftRecursionParser.new.parse('x%?!').should ==
        { a: { b: { c: { x: 'x' } } } }
    end
  end

  describe 'ordered choice semantics' do
    class LeftRecOrderedChoiceParser < Parslet::Parser
      left_recursion

      rule(:ab) { (str('a') >> str('b')).as(:ab) | (str('a') >> str('c')).as(:ac) }

      root :ab
    end

    let(:parser) { LeftRecOrderedChoiceParser.new }

    it 'still tries alternatives in order' do
      parser.parse('ab').should == { ab: 'ab' }
      parser.parse('ac').should == { ac: 'ac' }
    end

    it 'fails when no alternative matches' do
      expect { parser.parse('ad') }.to raise_error(Parslet::ParseFailed)
    end
  end

  describe 'enabling' do
    it 'is disabled by default' do
      Class.new(Parslet::Parser).left_recursion_enabled?.should be_falsey
    end

    it 'is enabled for subclasses' do
      Class.new(LeftRecArithmeticParser).left_recursion_enabled?.should be_truthy
    end

    it 'can be disabled again' do
      parser_class = Class.new(Parslet::Parser) do
        left_recursion
        left_recursion false
      end
      parser_class.left_recursion_enabled?.should be_falsey
    end

    describe 'per rule via :left_recursive' do
      class PerRuleLeftRecursionParser < Parslet::Parser
        rule(:e, left_recursive: true) {
          (e >> str('+') >> match['0-9'].as(:r)).as(:p) | match['0-9'].as(:n) }

        root :e
      end

      it 'evaluates that rule with the left recursion scheme' do
        PerRuleLeftRecursionParser.new.parse('1+2+3').should ==
          { p: { p: { n: '1', r: '2' }, r: '3' } }
      end
    end
  end

  describe 'progress condition and degenerate grammars' do
    it 'terminates on cycles that never consume input' do
      parser = Class.new(Parslet::Parser) do
        left_recursion
        rule(:a) { b }
        rule(:b) { a }
        root :a
      end.new

      expect { parser.parse('x') }.to raise_error(Parslet::ParseFailed)
    end

    it 'terminates on self-recursion without a base case' do
      parser = Class.new(Parslet::Parser) do
        left_recursion
        rule(:a) { a >> str('x') }
        root :a
      end.new

      expect { parser.parse('x') }.to raise_error(Parslet::ParseFailed)
    end

    it 'raises LeftRecursionError for nullable recursion' do
      parser = Class.new(Parslet::Parser) do
        left_recursion
        rule(:a) { (a >> str('x')).maybe }
        root :a
      end.new

      expect { parser.parse('x') }.to raise_error(Parslet::LeftRecursionError)
    end

    it 'raises LeftRecursionError for indirectly nullable recursion' do
      parser = Class.new(Parslet::Parser) do
        left_recursion
        rule(:a) { b }
        rule(:b) { a | str('') }
        root :a
      end.new

      expect { parser.parse('x') }.to raise_error(Parslet::LeftRecursionError)
    end
  end

  describe 'capture and scope state across candidate expansions' do
    class LeftRecCaptureParser < Parslet::Parser
      left_recursion

      rule(:a)   { (a >> str('+') >> match['0-9'].capture(:d)).as(:sum) |
                   match['0-9'].capture(:d) }
      rule(:top) { a >> str('=') >> dynamic { |src, ctx| str(ctx.captures[:d].to_s) } }

      root :top
    end

    let(:parser) { LeftRecCaptureParser.new }

    it 'keeps the captures of the best expansion' do
      parser.parse('1+2=2').should == { sum: '1+2' }
    end

    it 'does not leak captures from failed expansions' do
      # The last (failing) expansion pass captures '1' into :d; if that
      # state leaked, the parse would wrongly succeed.
      expect { parser.parse('1+2=1') }.to raise_error(Parslet::ParseFailed)
    end

    class LeftRecOuterCaptureParser < Parslet::Parser
      left_recursion

      rule(:a)   { (a >> str('+') >> match['0-9']).as(:sum) | match['0-9'] }
      rule(:top) { str('v').capture(:v) >> a >>
                   dynamic { |src, ctx| str(ctx.captures[:v].to_s) } }

      root :top
    end

    it 'keeps captures made before the recursive rule intact' do
      LeftRecOuterCaptureParser.new.parse('v1+2v').should == { sum: '1+2' }
    end

    class LeftRecScopeParser < Parslet::Parser
      left_recursion

      rule(:a)   { scope { (a >> str('+') >> match['0-9'].capture(:d)).as(:sum) |
                           match['0-9'].capture(:d) } }
      rule(:top) { a >> str('=') >> match['0-9'].capture(:last) >>
                   dynamic { |src, ctx| str(ctx.captures[:last].to_s) } }

      root :top
    end

    it 'keeps scopes balanced across expansions' do
      LeftRecScopeParser.new.parse('1+2=33').should == { sum: '1+2' }
    end

    it 'does not leak captures out of their scope' do
      parser = Class.new(Parslet::Parser) do
        left_recursion
        rule(:a)   { scope { (a >> str('+') >> match['0-9'].capture(:d)).as(:sum) |
                             match['0-9'].capture(:d) } }
        rule(:top) { a >> dynamic { |src, ctx| ctx.captures[:d]; str('') } }
        root :top
      end.new

      expect { parser.parse('1+2') }.to raise_error(Parslet::Scope::NotFound)
    end
  end
end
