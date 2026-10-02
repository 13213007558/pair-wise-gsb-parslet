require 'spec_helper'

describe "Layout (indentation) support" do
  include Parslet

  # A small indentation sensitive rule language used throughout these
  # examples:
  #
  #   if a:
  #     x
  #     y
  #   z
  #
  class LayoutLang < Parslet::Parser
    rule(:document)   { statement >> (same_indent >> statement).repeat }
    rule(:statement)  { if_stmt | simple_stmt }
    rule(:simple_stmt){ name.as(:simple) }
    rule(:if_stmt)    { str('if') >> str(' ') >> name.as(:cond) >> str(':') >> block }
    rule(:block)      { (indent >> statement >>
                          (same_indent >> statement).repeat >> dedent).as(:block) }
    rule(:name)       { match['a-z'].repeat(1) }
    root(:document)
  end

  def parse_error(parser, input)
    parser.parse(input)
    nil
  rescue Parslet::ParseFailed => exception
    exception
  end

  describe "the layout primitives" do
    it "indent enters a deeper level and consumes the indentation" do
      (indent >> str('x')).should parse("  x")
    end
    it "indent fails when the line is not deeper" do
      (indent >> str('x')).should_not parse("x")
    end
    it "indent fails in the middle of a line" do
      (str('x') >> indent).should_not parse("x  y")
    end
    it "same_indent keeps the current level" do
      (indent >> str('x') >> same_indent >> str('y') >> dedent).
        should parse("  x\n  y\n")
    end
    it "same_indent fails on a different level" do
      (indent >> str('x') >> same_indent >> str('y')).
        should_not parse("  x\n    y\n")
    end
    it "dedent leaves the current level" do
      (indent >> str('x') >> dedent >> str('y')).should parse("  x\ny")
    end
    it "dedent fails at the outermost level" do
      dedent.should_not parse("x")
    end
    it "dedent pops exactly one level per occurrence" do
      # The line 'y' dedents two levels at once; each nested block's dedent
      # pops exactly one, so 'y' ends up outside both blocks.
      LayoutLang.new.parse("if a:\n  if b:\n    x\ny\n").should ==
        [{ cond: 'a', block: { cond: 'b', block: { simple: 'x' } } },
         { simple: 'y' }]
    end
    it "dedent succeeds at end of input" do
      (indent >> str('x') >> dedent).should parse("  x")
    end
    it "layout atoms leave no trace in the resulting tree" do
      (indent >> str('x').as(:x) >> dedent).parse("  x").should == { x: 'x' }
    end
  end

  describe "a nested rule language" do
    let(:parser) { LayoutLang.new }

    it "parses nested blocks through indentation alone" do
      parser.parse("if a:\n  x\n  y\nz\n").should ==
        [{ cond: 'a', block: [{ simple: 'x' }, { simple: 'y' }] },
         { simple: 'z' }]
    end
    it "parses doubly nested blocks" do
      parser.parse("if a:\n  if b:\n    x\n  y\nz\n").should ==
        [{ cond: 'a',
           block: [{ cond: 'b', block: { simple: 'x' } }, { simple: 'y' }] },
         { simple: 'z' }]
    end
    it "parses a block at the end of input" do
      parser.parse("if a:\n  x\n").should ==
        { cond: 'a', block: { simple: 'x' } }
    end
    it "parses a block at the end of input, no trailing newline" do
      parser.parse("if a:\n  x").should ==
        { cond: 'a', block: { simple: 'x' } }
    end
    it "ignores trailing blank lines at end of input" do
      parser.parse("x\n\n\n").should == { simple: 'x' }
    end
  end

  describe "blank lines" do
    let(:parser) { LayoutLang.new }

    it "never establish a new level" do
      parser.parse("if a:\n\n  x\n\n  y\n\nz\n").should ==
        [{ cond: 'a', block: [{ simple: 'x' }, { simple: 'y' }] },
         { simple: 'z' }]
    end
    it "may contain whitespace" do
      parser.parse("if a:\n  x\n   \n  y\nz\n").should ==
        [{ cond: 'a', block: [{ simple: 'x' }, { simple: 'y' }] },
         { simple: 'z' }]
    end
  end

  describe "tab policy" do
    it "forbids tabs by default, pointing out line and column" do
      error = parse_error(LayoutLang.new, "if a:\n\tx\n")
      error.message.should =~ /tab/i
      error.message.should =~ /line 2 char 1/
    end
    it "is configured centrally on the parser" do
      tab_lang = Class.new(LayoutLang) do
        layout tab: :expand, tab_width: 4
      end
      tab_lang.new.parse("if a:\n\tx\n    y\nz\n").should ==
        [{ cond: 'a', block: [{ simple: 'x' }, { simple: 'y' }] },
         { simple: 'z' }]
    end
    it "rejects mixed tabs and spaces, pointing out line and column" do
      tab_lang = Class.new(LayoutLang) do
        layout tab: :expand, tab_width: 4
      end
      error = parse_error(tab_lang.new, "if a:\n \tx\n")
      error.message.should =~ /mixed/i
      error.message.should =~ /line 2 char 2/
    end
    it "is inherited by subclass parsers" do
      tab_lang = Class.new(LayoutLang) do
        layout tab: :expand, tab_width: 4
      end
      Class.new(tab_lang).new.parse("if a:\n\tx\n").should ==
        { cond: 'a', block: { simple: 'x' } }
    end
    it "rejects unknown policies" do
      lambda {
        Class.new(Parslet::Parser) { layout tab: :whatever }
      }.should raise_error(ArgumentError)
    end
  end

  describe "inconsistent dedentation" do
    it "fails, pointing out line and column" do
      error = parse_error(LayoutLang.new, "if a:\n    x\n  y\n")
      error.message.should =~ /outer indentation level/
      error.message.should =~ /line 3 char 1/
    end
  end

  describe "interaction with alternatives" do
    # The first branch enters a deeper level and fails afterwards; the
    # second branch must see a pristine layout state.
    class AltLang < Parslet::Parser
      rule(:top)      { branch_a | branch_b }
      rule(:branch_a) { str('>') >> inner >> str('!') }
      rule(:branch_b) { str('>') >> inner >> str('?') }
      rule(:inner)    { indent >> str('x') >> dedent }
      root(:top)
    end

    it "rolls layout state back with the failed branch" do
      AltLang.new.parse(">\n  x\n?").should == '>x?'
    end
    it "reparses the same text as an independent parse of the other branch" do
      input = ">\n  x\n?"
      AltLang.new.parse(input).should == AltLang.new.branch_b.parse(input)
    end

    # Same, but with the failure happening after two levels of nesting.
    class NestLang < Parslet::Parser
      rule(:top)  { deep | flat }
      rule(:deep) { indent >> str('x') >> same_indent >> str('y') >> dedent >> str('!') }
      rule(:flat) { indent >> str('x') >> dedent >> str('z') }
      root(:top)
    end

    it "rolls back nested levels as well" do
      input = "  x\nz"
      NestLang.new.parse(input).should == NestLang.new.flat.parse(input)
    end
  end

  describe "interaction with lookahead" do
    it "positive lookahead does not change the level" do
      (indent.present? >> indent >> str('x') >> dedent).should parse("  x")
    end
    it "negative lookahead does not change the level" do
      (same_indent.absent? >> indent >> str('x') >> dedent).should parse("  x")
    end
    it "lookahead inside a block does not leak levels" do
      parser = Class.new(Parslet::Parser) do
        rule(:top) { (indent >> str('x') >> dedent).present? >>
                     indent >> str('x') >> dedent }
        root(:top)
      end
      parser.new.parse("  x").should == 'x'
    end
  end

  describe "interaction with repetition" do
    it "does not leak levels across iterations" do
      block = indent >> str('x') >> (same_indent >> str('x')).repeat >> dedent
      block.repeat.should parse("  x\n  x\n")
    end
    it "rolls back failed branches inside iterations" do
      parser = indent >> str('y') >> str('!') >> dedent |
               same_indent >> str('y')
      parser.repeat.should parse("y\ny\n")
    end
  end

  describe Parslet::Layout::Policy do
    def measure(whitespace, options)
      described_class.new(options).measure(whitespace, 0)
    end

    it "measures spaces one column each" do
      measure('   ', {}).should == 3
    end
    it "expands tabs to tab stops" do
      measure("\t", { tab: :expand, tab_width: 4 }).should == 4
      measure("\t\t", { tab: :expand, tab_width: 4 }).should == 8
    end
    it "raises on tabs when forbidden" do
      lambda { measure("\t", {}) }.should raise_error(Parslet::Layout::Violation)
    end
    it "raises on mixed indentation" do
      lambda {
        measure(" \t", { tab: :expand })
      }.should raise_error(Parslet::Layout::Violation)
    end
  end
end
