require 'spec_helper'

describe Parslet::Layout do
  include Parslet

  class LayoutParser < Parslet::Parser
    layout(tab_width: 2)
    root(:node)

    rule(:node) do
      str('a').as(:name) >> block.maybe >> str('c').as(:next).maybe
    end

    rule(:block) do
      layout.indent >> children.as(:children) >> layout.dedent
    end

    rule(:children) do
      (layout.same >> str('b')).repeat(1)
    end

    rule(:next_line) do
      layout.same >> str('c').as(:next)
    end
  end

  let(:parser_class) { LayoutParser }

  it 'parses nested indentation and returns to the outer level' do
    parser_class.new.parse("a\n  b\nc").should == {
      name: 'a',
      children: 'b',
      next: 'c'
    }
  end

  it 'skips blank lines without changing indentation level' do
    parser_class.new.parse("a\n\n  b\n\nc").should == {
      name: 'a',
      children: 'b',
      next: 'c'
    }
  end

  it 'parses a blockless line without requiring indentation tokens' do
    parser_class.new.parse("ac").should == { name: 'a', next: 'c' }
  end

  it 'restores state when a failed alternative backtracks' do
    deep = parser_class.new
    flat = parser_class.new

    choice = deep | flat
    choice.parse("ac", prefix: true).should == flat.parse("ac")
  end

  it 'retries the same text in another branch as if parsed independently' do
    failed_layout = layout(tab_width: 2)
    accepted_layout = layout(tab_width: 2)
    failed_suffix = failed_layout.indent >> failed_layout.same >> str('b')
    accepted_suffix = accepted_layout.indent >> accepted_layout.same >> str('x')
    choice = failed_suffix | accepted_suffix
    input = "\n  x"

    choice.parse(input).should == accepted_suffix.parse(input)
  end

  it 'does not let lookahead change the indentation level' do
    parser = parser_class.new

    input = "a\n  b\nc"
    guarded = str('a').as(:name) >> parser.layout.indent.present? >> parser.block.maybe >>
      parser.next_line.maybe

    guarded.parse(input, prefix: true).should == parser_class.new.parse(input)
  end

  it 'restores layout after negative lookahead' do
    parser = parser_class.new
    guarded = str('a').as(:name) >> parser.layout.indent.absent? >>
      str('c').as(:next)

    guarded.parse("ac", prefix: true).should == { name: 'a', next: 'c' }
  end

  it 'reports the position of disallowed tabs' do
    custom = Class.new(Parslet::Parser) do
      layout(tab_width: 2, tab_policy: :spaces)
      root(:node)
      rule(:node) do
        str('a') >> (layout.indent >> layout.same >> str('b') >>
          layout.dedent).maybe
      end
    end
    cause = catch_failed_parse { custom.new.parse("a\n\n\n\tb\nc") }

    cause.ascii_tree.should include(
      "Tabs are not allowed in indentation. at line 4 char 1"
    )
  end

  it 'reports mixed tabs and spaces at the first noncompliant character' do
    custom = Class.new(Parslet::Parser) do
      layout(tab_width: 4, tab_policy: :consistent)
      root(:line)
      rule(:line) { layout.same >> str('x') }
    end

    cause = catch_failed_parse { custom.new.parse(" \tx") }
    cause.ascii_tree.should include(
      "Indentation cannot mix tabs and spaces. at line 1 char 2"
    )
  end

  it 'expands tabs to configured tab stops' do
    custom = Class.new(Parslet::Parser) do
      layout(tab_width: 4, tab_policy: :mixed)
      root(:block)
      rule(:block) do
        str('a') >> layout.indent >> layout.same >> str('b').as(:child) >>
          layout.dedent >> layout.same >> str('c')
      end
    end

    custom.new.parse("a\n\tb\nc").should == { child: 'b' }
  end

  it 'requires dedent to move to a less indented physical line' do
    custom = Class.new(Parslet::Parser) do
      layout(tab_width: 2)
      root(:line)
      rule(:line) do
        str('a') >> layout.indent >> layout.same >> str('b') >>
          layout.dedent >> str('c')
      end
    end

    cause = catch_failed_parse { custom.new.parse("a\n  bc") }
    cause.ascii_tree.should include(
      "Expected a less indented line before end of current line."
    )
  end

  it 'allows consecutive dedents at end of input' do
    custom = Class.new(Parslet::Parser) do
      layout(tab_width: 4)
      root(:node)
      rule(:node) do
        str('a') >> layout.indent >> layout.same >> str('b') >>
          layout.indent >> layout.same >> str('c') >>
          layout.dedent >> layout.dedent
      end
    end

    custom.new.parse("a\n    b\n        c").should == "abc"
  end
end
