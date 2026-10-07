require 'spec_helper'
require 'timeout'

describe Parslet::CFG do
  include Parslet

  describe '#parse_cfg' do
    it 'keeps explicit alternatives in a shared forest' do
      parser = str('a').as(:left) | str('a').as(:right)
      forest = parser.parse_cfg('a')

      forest.success?.should == true
      forest.ambiguous?.should == true
      forest.value { |families| families.first }.should == { :left => 'a' }
      forest.value { |families| families.last }.should == { :right => 'a' }
    end

    it 'builds only the selected named tree' do
      parser = str('a').as(:left) | str('a').as(:right)
      forest = parser.parse_cfg('a')

      forest.value { |families| families.last }.should == { :right => 'a' }
    end

    it 'handles left recursive grammars' do
      parser = Class.new(Parslet::Parser) do
        root(:expression)
        rule(:expression) do
          (expression >> str('+') >> expression) | match('[0-9]')
        end
      end.new

      forest = parser.parse_cfg('1+2+3')

      forest.success?.should == true
      forest.ambiguous?.should == true
      forest.empty_loop?.should == false
      forest.value.should == '1+2+3'
    end

    it 'keeps long ambiguous expressions compact' do
      parser = Class.new(Parslet::Parser) do
        root(:expression)
        rule(:expression) do
          (expression >> str('+') >> expression) | match('[0-9]')
        end
      end.new

      forest = nil
      Timeout.timeout(2) do
        forest = parser.parse_cfg(Array.new(20, '1').join('+'))
      end

      forest.ambiguous?.should == true
      forest.node_count.should < 2000
    end

    it 'marks nullable recursion instead of enumerating empty loops' do
      parser = Class.new(Parslet::Parser) do
        root(:expression)
        rule(:expression) { expression.maybe }
      end.new

      forest = nil
      Timeout.timeout(2) do
        forest = parser.parse_cfg('')
      end

      forest.success?.should == true
      forest.empty_loop?.should == true
      forest.empty_loops.first.should be_a(Parslet::CFG::EmptyLoopMarker)
      forest.value.should == ''
      selected = forest.value { |families| families.find(&:empty_loop?) }
      selected.should be_a(Parslet::CFG::EmptyLoopMarker)
    end

    it 'accepts a prefix when requested' do
      forest = str('ab').parse_cfg('abc', :prefix => true)

      forest.success?.should == true
      forest.value.should == 'ab'
    end

    it 'handles multicharacter terminals' do
      forest = str('ab').repeat(2, 2).parse_cfg('abab')

      forest.value.should == 'abab'
    end

    it 'supports empty productions through normal repetitions' do
      forest = str('a').maybe.as(:letter).parse_cfg('')

      forest.success?.should == true
      forest.value.should == { :letter => '' }
    end

    it 'rejects side-effecting lookahead' do
      expect do
        str('a').present?.parse_cfg('a')
      end.to raise_error(Parslet::CFG::UnsupportedGrammar)
    end

    it 'rejects side-effecting dynamic atoms' do
      expect do
        dynamic { str('a') }.parse_cfg('a')
      end.to raise_error(Parslet::CFG::UnsupportedGrammar)
    end

    it 'leaves ordinary PEG parsing ordered' do
      parser = str('a').as(:first) | str('a').as(:second)

      parser.parse('a').should == { :first => 'a' }
    end
  end
end
