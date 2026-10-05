require 'spec_helper'

describe 'scoped cut' do
  include Parslet

  class ScopedCutParser < Parslet::Parser
    rule(:increment) do
      str('inc') >> cut >> str(' ').maybe >> name.as(:name)
    end

    rule(:decrement) do
      str('dec') >> cut >> str(' ').maybe >> name.as(:name)
    end

    rule(:command) do
      increment | decrement
    end

    rule(:name) do
      match['[:alnum:]'].repeat(1)
    end

    root(:command)
  end

  it 'commits after matching the selected command keyword' do
    parser = ScopedCutParser.new
    parser.parse('inc counter').should == { name: 'counter' }

    cause = catch_failed_parse { parser.parse('inc?') }
    cause.children.should be_empty
    cause.pos.charpos.should == 3
    cause.to_s.should == "Failed to match [[:alnum:]] at line 1 char 4."
  end

  it 'keeps a cut in an inner alternative local to that alternative' do
    parser = Class.new(Parslet::Parser) do
      rule(:keyword) { (str('go') >> cut >> str('x')) | str('stop') }
      rule(:command) { keyword | str('going') }
      root(:command)
    end.new

    parser.parse('stop').should == 'stop'
    parser.parse('going').should == 'going'

    cause = catch_failed_parse { parser.parse('go!') }
    cause.pos.charpos.should == 2
    cause.to_s.should == "Expected \"x\", but got \"!\" at line 1 char 3."
  end

  it 'does not let repetition swallow commitment to an enclosing choice' do
    parser = (str('a') >> cut >> str('b').repeat(1)) | str('a!')
    cause = catch_failed_parse { parser.parse('a!') }
    cause.pos.charpos.should == 1
    cause.to_s.should == "Expected \"b\", but got \"!\" at line 1 char 2."
  end

  it 'limits a cut inside repeated choice to that inner choice' do
    inner = (str('a') >> cut >> str('b')) | str('a')
    parser = inner.repeat >> str('!') | str('a!')

    parser.parse('ab!').should == 'ab!'
    parser.parse('a!').should == 'a!'
  end

  it 'does not let a lookahead commit an enclosing choice' do
    parser = Class.new(Parslet::Parser) do
      rule(:check) { str('go') >> cut >> str('n') }
      rule(:inner) { check.present? >> str('go') | str('y') }
      rule(:command) { (inner >> str('z')) | str('go!') }
      root(:command)
    end.new

    parser.parse('go!').should == 'go!'
  end

  it 'recomputes cuts on cache hits in another choice scope' do
    parser = Class.new(Parslet::Parser) do
      rule(:shared) { str('a') >> match['b'].maybe }
      rule(:inner) { (str('a') >> cut >> str('b')) | shared }
      rule(:command) { inner | str('a') }
      root(:command)
    end.new

    parser.parse('a').should == 'a'
  end

  it 'is visible to parser visitors' do
    Parslet::Parser::Visitors::Citrus.new(nil).visit_cut.should == 'cut'
  end
end
