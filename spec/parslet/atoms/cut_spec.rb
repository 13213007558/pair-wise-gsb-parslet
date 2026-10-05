require 'spec_helper'

describe 'scoped ordered-choice cuts' do
  include Parslet

  def failure(&block)
    catch_failed_parse { block.call }
  end

  it 'matches zero input' do
    parser = (cut >> str('a')) | str('b')
    parser.parse('a').should == 'a'
  end

  it 'prints the commitment markers' do
    cut.inspect.should == '~'
    str('a').commit.inspect.should == "'a'~"
  end

  it 'commits after an atom has matched using #commit' do
    parser = (str('keyword').commit >> str(': ')) | str('keyword = ')
    failure { parser.parse('keyword x') }.to_s.should ==
      'Expected ": ", but got " x" at line 1 char 8.'
  end

  it 'does not rematch the atom committed with #commit' do
    calls = 0
    keyword = Parslet::Atoms::Str.new('keyword').tap do |atom|
      atom.define_singleton_method(:try) do |*args|
        calls += 1
        super(*args)
      end
    end
    parser = (keyword.commit >> str(': ')) | str('fallback')

    expect { parser.parse('keyword: x', prefix: true) }.not_to raise_error
    calls.should == 1
  end

  it 'limits a cut to the nearest enclosing ordered choice' do
    inner = (cut >> str('x')) | str('z')
    parser =
      (str('k') >> inner >> str('end')) |
      (str('k') >> str('other'))

    parser.parse('kother').should == 'kother'
    failure { parser.parse('kmatch') }.to_s.should ==
      'Expected "x", but got "m" at line 1 char 2.'
  end

  it 'does not let a required repetition swallow a committed failure' do
    parser =
      (str('k').commit >> str('x').repeat(1) >> str('end')) | str('fallback')

    failure { parser.parse('kend') }.to_s.should ==
      'Expected "x", but got "e" at line 1 char 2.'
  end

  it 'preserves a committed failure through an optional repetition' do
    parser =
      (str('k').commit >> str('x').maybe >> str('end')) | str('fallback')

    failure { parser.parse('kbad') }.to_s.should ==
      'Expected "x", but got "b" at line 1 char 2.'
  end

  it 'carries a cut through a positive lookahead' do
    parser =
      (str('k') >> (cut >> str('x')).present? >> str('end')) |
      str('fallback')

    failure { parser.parse('knope') }.to_s.should ==
      'Expected "x", but got "n" at line 1 char 2.'
  end

  it 'reports a negative lookahead failure after a cut' do
    parser =
      (str('k') >> (cut >> str('x')).absent? >> str('end')) |
      str('fallback')

    failure { parser.parse('kxend') }.to_s.should ==
      'Input should not start with ~ \'x\' at line 1 char 2.'
  end

  it 'replays a commitment on a cache hit' do
    committed = str('k').commit >> str('x')
    parser = (committed.present? >> committed >> str('end')) | str('fallback')

    failure { parser.parse('kbad') }.to_s.should ==
      'Expected "x", but got "b" at line 1 char 2.'
  end

  it 'does not bind a cached cut to an unrelated choice scope' do
    committed = (str('k').commit >> str('x')) | str('z')
    scoped = committed >> str('tail')
    parser =
      (scoped.present? >> str('outer-tail')) |
      (str('kx') >> str('ok'))

    parser.parse('kxok').should == 'kxok'
  end
end
