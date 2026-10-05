require 'spec_helper'

describe Parslet::GrammarModule do
  # A parameterizable grammar module: a list of +element+ separated by
  # +separator+. Adjacent elements may not repeat each other (enforced by
  # the dynamic rule +previous_element+, which reads the instance's own
  # +:current+ capture).
  #
  # All internal names (the rules +list+, +guarded_item+, +item+,
  # +previous_element+ and the capture +:current+) are private to each
  # instance; only +list+ and +item+ are exported.
  #
  class SeparatedList < Parslet::GrammarModule
    param :element
    param :separator

    rule(:list) { item >> (separator >> guarded_item).repeat }
    rule(:guarded_item) { previous_element.absent? >> item }
    rule(:item) { element.capture(:current).as(:element) }
    rule(:previous_element) {
      dynamic { |source, context| str(context.captures[:current].to_s) }
    }

    export :list
    export :item
  end

  # A second module, recursive this time: brackets containing either
  # +content+ or more brackets. Used to verify that recursive references
  # resolve to the rules of the same instance.
  #
  class Bracketed < Parslet::GrammarModule
    param :content

    rule(:brackets) { str('[').ignore >> inner >> str(']').ignore }
    rule(:inner) { (brackets | content).repeat }

    export :brackets
  end

  # Instantiates the module twice with different element rules. Both
  # instances use the exact same internal names (regression: the instances
  # must not see each other's bindings).
  #
  class ListParser < Parslet::Parser
    rule(:integer) { match['0-9'].repeat(1) }
    rule(:word)    { match['a-z'].repeat(1) }

    instance(:int_list, SeparatedList,
      :element => :integer, :separator => proc { str(',').ignore })
    instance(:word_list, SeparatedList,
      :element => :word, :separator => proc { str(';').ignore })

    instance(:int_brackets, Bracketed, :content => :integer)
    instance(:word_brackets, Bracketed, :content => :word)

    rule(:top) {
      str('[').ignore >> int_list.as(:ints) >> str(']').ignore >>
      str('[').ignore >> word_list.as(:words) >> str(']').ignore
    }
    root(:top)

    rule(:nested) { int_brackets >> str('=').ignore >> word_brackets }
  end

  let(:parser) { ListParser.new }

  describe 'two instances with identical internal names' do
    it 'parses each instance with its own parameter bindings' do
      parser.should parse('[1,22,3][ab;c]')
    end

    it 'yields the parse results of both instances' do
      parser.parse('[1,22,3][ab;c]').should == {
        :ints  => [{:element => '1'}, {:element => '22'}, {:element => '3'}],
        :words => [{:element => 'ab'}, {:element => 'c'}]
      }
    end

    it 'rejects input that only matches the other instance' do
      parser.should_not parse('[a,b][1;2]')
    end

    it 'applies captures and dynamic rules per instance' do
      parser.should_not parse('[1,1][a;b]')
      parser.should_not parse('[1,2][a;a]')
      parser.should parse('[12,21][ab;ba]')
    end

    it 'resolves recursive references within each instance' do
      parser.nested.should parse('[[1][2]]=[[a][b]]')
      parser.nested.should_not parse('[[1][2]]=[[1][2]]')
      parser.nested.should_not parse('[[1][a]]=[[a][b]]')
    end

    it 'creates separate rule entities per instance' do
      parser.int_list.should_not equal(parser.word_list)
      parser.int_list.list.should_not equal(parser.word_list.list)
    end

    it 'memoizes each instance' do
      parser.int_list.should equal(parser.int_list)
    end
  end

  describe 'instance boundary' do
    it 'exposes exported rules' do
      parser.int_list.should respond_to(:list)
      parser.int_list.should respond_to(:item)
    end

    it 'parses via an exported rule' do
      parser.int_list.item.parse('42', :prefix => true).
        should == {:element => '42'}
    end

    it 'hides internal rules' do
      parser.int_list.should_not respond_to(:guarded_list)
      parser.int_list.should_not respond_to(:previous_element)
      lambda { parser.int_list.guarded_list }.
        should raise_error(NoMethodError)
    end

    it 'keeps instance captures from leaking into the parent grammar' do
      parser = Class.new(Parslet::Parser) do
        rule(:integer) { match['0-9'].repeat(1) }
        instance(:int_list, SeparatedList,
          :element => :integer, :separator => proc { str(',').ignore })
        rule(:top) {
          int_list >> dynamic { |source, context| context.captures[:current] }
        }
        root(:top)
      end.new

      lambda { parser.parse('1,2') }.
        should raise_error(Parslet::Scope::NotFound)
    end

    it 'keeps parent captures visible after the instance ran' do
      parser = Class.new(Parslet::Parser) do
        rule(:integer) { match['0-9'].repeat(1) }
        instance(:int_list, SeparatedList,
          :element => :integer, :separator => proc { str(',').ignore })
        rule(:top) {
          str('parent').capture(:current) >> str(' ').ignore >>
          int_list >>
          dynamic { |source, context|
            str(' ').ignore >> str(context.captures[:current].to_s)
          }
        }
        root(:top)
      end.new

      parser.should parse('parent 1,2 parent')
    end

    it 'hides parent captures from the instance' do
      spy_module = Class.new(Parslet::GrammarModule) do
        rule(:spy) {
          dynamic { |source, context| str(context.captures[:from_parent].to_s) }
        }
        export :spy
      end
      parser = Class.new(Parslet::Parser) do
        instance(:spy_instance, spy_module)
        rule(:top) { str('x').capture(:from_parent) >> spy_instance }
        root(:top)
      end.new

      lambda { parser.parse('x') }.
        should raise_error(Parslet::Scope::NotFound)
    end
  end

  describe 'error messages' do
    it 'names the instance in parent-level failures' do
      cause = catch_failed_parse { parser.parse('[1,2][a]x') }
      cause.to_s.should include('INT_LIST')
      cause.to_s.should include('WORD_LIST')
    end

    it 'keeps the original rule name and the instance path' do
      cause = catch_failed_parse { parser.parse('[!][a]') }
      cause.ascii_tree.should include('INT_LIST.ITEM')

      cause = catch_failed_parse { parser.parse('[1][!]') }
      cause.ascii_tree.should include('WORD_LIST.ITEM')
    end

    it 'names the instance path of recursive module rules' do
      cause = catch_failed_parse { parser.nested.parse('[[1][x]]=[[a]]') }
      cause.ascii_tree.should include('INT_BRACKETS.INNER')
    end

    it 'inspects instances and their rules with qualified names' do
      parser.int_list.inspect.should == 'INT_LIST'
      parser.int_list.list.inspect.should == 'INT_LIST.LIST'
      parser.word_list.list.inspect.should == 'WORD_LIST.LIST'
    end
  end

  describe 'formal parameters' do
    it 'requires parameters without defaults to be bound' do
      lambda {
        SeparatedList.instantiate(:separator => proc { str(',') })
      }.should raise_error(ArgumentError, /:element/)
    end

    it 'rejects unknown bindings' do
      lambda {
        SeparatedList.instantiate(
          :element => proc { any },
          :separator => proc { str(',') },
          :bogus => proc { any })
      }.should raise_error(ArgumentError, /:bogus/)
    end

    it 'accepts plain atoms as bindings' do
      list = SeparatedList.instantiate(
        :element => Parslet.str('x'), :separator => Parslet.str(','))
      list.parse('x').should == {:element => 'x'}
    end

    context 'with a default' do
      class CommaList < Parslet::GrammarModule
        param :element
        param :separator, :default => proc { str(',').ignore }

        rule(:list) { element >> (separator >> element).repeat }
        export :list
      end

      it 'uses the default when the parameter is not bound' do
        CommaList.instantiate(:element => proc { match['0-9'].repeat(1) }).
          parse('1,2').should == '12'
      end

      it 'allows overriding the default' do
        CommaList.instantiate(
          :element => proc { match['0-9'].repeat(1) },
          :separator => proc { str(';').ignore }).
          parse('1;2').should == '12'
      end
    end

    it 'requires the module to export something' do
      no_exports = Class.new(Parslet::GrammarModule) do
        rule(:a) { str('a') }
      end
      lambda { no_exports.instantiate }.
        should raise_error(ArgumentError, /export/)
    end

    it 'requires exported rules to be defined' do
      bad_exports = Class.new(Parslet::GrammarModule) do
        rule(:a) { str('a') }
        export :b
      end
      lambda { bad_exports.instantiate }.
        should raise_error(ArgumentError, /:b/)
    end
  end

  describe 'nested instances' do
    class PairOfLists < Parslet::GrammarModule
      param :left
      param :right

      instance(:left_list, SeparatedList,
        :element => :left, :separator => proc { str(',').ignore })
      instance(:right_list, SeparatedList,
        :element => :right, :separator => proc { str(';').ignore })

      rule(:pair) { left_list >> str('=').ignore >> right_list }
      export :pair
    end

    class PairParser < Parslet::Parser
      rule(:integer) { match['0-9'].repeat(1) }
      rule(:word)    { match['a-z'].repeat(1) }

      instance(:pairs, PairOfLists, :left => :integer, :right => :word)
      rule(:top) { pairs }
      root(:top)
    end

    it 'parses through two levels of instantiation' do
      PairParser.new.should parse('1,2=a;b')
    end

    it 'composes the instance path in error messages' do
      cause = catch_failed_parse { PairParser.new.parse('1,?=a') }
      cause.ascii_tree.should include('PAIRS.LEFT_LIST')
    end
  end
end
