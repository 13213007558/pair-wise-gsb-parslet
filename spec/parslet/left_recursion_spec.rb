require 'spec_helper'

require 'timeout'

describe 'left recursion' do
  include Parslet

  class ArithmeticParser < Parslet::Parser
    root(:expr)

    rule(:expr) do
      (expr.as(:left) >> plus >> term.as(:right)) | term
    end

    rule(:term) do
      match['0-9'].repeat(1).as(:number)
    end

    rule(:plus) { str('+').ignore }
  end

  class MutualArithmeticParser < Parslet::Parser
    root(:sum)

    rule(:sum) do
      (difference.as(:left) >> str('+').as(:op) >> number.as(:right)) | difference
    end

    rule(:difference) do
      (sum.as(:left) >> str('-').as(:op) >> number.as(:right)) | number
    end

    rule(:number) do
      match['0-9'].repeat(1).as(:number)
    end
  end

  class RightRecursiveParser < Parslet::Parser
    root(:list)

    rule(:list) do
      (str('a').ignore >> str(',').ignore >> list.as(:rest)) | str('a').as(:item)
    end
  end

  def evaluate(tree)
    return Integer(tree[:number]) if tree.key?(:number)

    left = evaluate(tree[:left])
    right = evaluate(tree[:right])
    tree[:op].to_s == '-' ? left - right : left + right
  end

  it 'grows a directly left recursive expression into a left-associated tree' do
    tree = ArithmeticParser.new.parse('1+2+3')

    tree.should == {
      left: {
        left: { number: '1' },
        right: { number: '2' }
      },
      right: { number: '3' }
    }
    evaluate(tree).should == 6
  end

  it 'grows mutually left recursive rules without special-casing expr' do
    tree = MutualArithmeticParser.new.parse('1-2+3-4')

    evaluate(tree).should == ((1 - 2) + 3) - 4
  end

  it 'keeps right recursion working' do
    RightRecursiveParser.new.parse('a,a,a').should == {
      rest: { rest: { item: 'a' } }
    }
  end

  it 'keeps ordered choice and error positions working after a successful seed' do
    cause = catch_failed_parse { ArithmeticParser.new.parse('1+') }

    cause.to_s.should == 'Don\'t know what to do with "+" at line 1 char 2.'

    deepest = catch_failed_parse do
      ArithmeticParser.new.parse('1+', reporter: Parslet::ErrorReporter::Deepest.new)
    end
    deepest.to_s.should == 'Premature end of input at line 1 char 3.'
  end

  it 'reports a non-consuming left recursion instead of looping forever' do
    parser_class = Class.new(Parslet::Parser)
    parser_class.class_eval do
      root(:empty)
      rule(:empty) { empty }
    end

    expect {
      Timeout.timeout(1) { parser_class.new.parse('') }
    }.to raise_error(Parslet::ParseFailed,
      /Left recursion in EMPTY did not consume input at line 1 char 1/)
  end

  it 'reports a non-consuming mutual recursion instead of looping forever' do
    parser_class = Class.new(Parslet::Parser)
    parser_class.class_eval do
      root(:one)
      rule(:one) { two }
      rule(:two) { one }
    end

    expect {
      Timeout.timeout(1) { parser_class.new.parse('') }
    }.to raise_error(Parslet::ParseFailed,
      /Left recursion in (ONE|TWO) did not consume input at line 1 char 1/)
  end

  it 'keeps named captures available to later left recursive repetitions' do
    parser_class = Class.new(Parslet::Parser)
    parser_class.class_eval do
      root(:sequence)

      rule(:sequence) do
        (sequence.as(:left) >> match['ab'].capture(:last) >> item.as(:right)) |
          str('a').as(:value)
      end

      rule(:item) do
        dynamic { |_, context| str(context.captures[:last]) }.as(:value)
      end
    end

    result = parser_class.new.parse('abb')

    result.should == {
      left: { value: 'a' },
      right: { value: 'b' }
    }
  end
end
