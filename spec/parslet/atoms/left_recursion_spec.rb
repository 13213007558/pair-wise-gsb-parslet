require 'spec_helper'
require 'parslet'

describe Parslet::Atoms::Entity do
  it 'supports direct left recursion with ordered choice' do
    parser = Class.new(Parslet::Parser) do
      root(:expr)
      rule(:expr) { expr.as(:left) >> str('+') >> term.as(:right) | term }
      rule(:term) { match('[0-9]').repeat(1).as(:number) }
    end.new

    expect(parser.parse('1+2+3')).to eq(
      left: { left: { number: '1' }, right: { number: '2' } },
      right: { number: '3' }
    )
  end

  it 'supports mutual left recursion' do
    parser = Class.new(Parslet::Parser) do
      root(:expr)
      rule(:expr) { mul.as(:left) >> str('+') >> term.as(:right) | mul }
      rule(:mul) { expr.as(:left) >> str('*') >> term.as(:right) | term }
      rule(:term) { match('[0-9]').repeat(1).as(:number) }
    end.new

    expect(parser.parse('1*2+3')).to eq(
      left: { left: { number: '1' }, right: { number: '2' } },
      right: { number: '3' }
    )
  end

  it 'keeps ordinary right recursion working' do
    parser = Class.new(Parslet::Parser) do
      root(:list)
      rule(:list) { str('a') >> list | str('a') }
    end.new

    expect(parser.parse('aaa')).to eq('aaa')
    expect(parser.parse('aaa', prefix: true)).to eq('aaa')
  end

  it 'reports non-consuming left recursion explicitly' do
    parser = Class.new(Parslet::Parser) do
      root(:x)
      rule(:x) { x | str('a') }
    end.new

    expect { parser.parse('') }.to raise_error(
      Parslet::ParseFailed,
      /Left recursion in rule X did not consume input/
    )
  end

  it 'keeps named captures in grown left-recursive results' do
    parser = Class.new(Parslet::Parser) do
      root(:expr)
      rule(:expr) { expr.as(:left) >> str('+') >> num.as(:right) | num }
      rule(:num) { match('[0-9]').repeat(1).as(:value) }
    end.new

    expect(parser.parse('1+2')).to eq(
      left: { value: '1' },
      right: { value: '2' }
    )
  end

  it 'preserves the ordered-choice failure position after unsuccessful left recursion' do
    parser = Class.new(Parslet::Parser) do
      root(:expr)
      rule(:expr) { expr >> str('+') >> str('1') | str('1') }
    end.new

    cause = catch_failed_parse { parser.parse('1+2') }
    expect(cause.to_s).to include('Don\'t know what to do with "+2"')
  end
end
