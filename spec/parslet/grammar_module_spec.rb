require 'spec_helper'

describe Parslet::GrammarModule do
  # A separated list, defined once as a parameterized grammar module.
  class SeparatedList < Parslet::GrammarModule
    param :element
    param :separator, default: -> { str(',') }

    rule(:list) { element.as(:item) >> (separator >> element.as(:item)).repeat }

    export :list
  end

  # A list whose delimiter must be consistent: the first delimiter is
  # captured, later ones must match it (dynamic back-reference). Uses
  # internal rule names (:list, :separator) and a capture name (:delim)
  # that also exist in the parent grammar and in sibling instances.
  class ConsistentList < Parslet::GrammarModule
    param :element

    rule(:list) { element >> (separator >> element).repeat(1) }
    rule(:separator) {
      dynamic { |src, ctx|
        begin
          str(ctx.captures[:delim].to_s)
        rescue Parslet::Scope::NotFound
          match[',;'].capture(:delim)
        end
      }
    }

    export :list
  end

  describe 'parameterization' do
    let(:parser) {
      Class.new(Parslet::Parser) do
        rule(:integer) { match['0-9'].repeat(1) }
        rule(:word)    { match['a-z'].repeat(1) }

        rule(:top) {
          ints  = SeparatedList.new(:int_list,  element: integer)
          words = SeparatedList.new(:word_list, element: word,
                                    separator: str(';'))

          ints.export(:list).as(:ints) >> str(' ') >>
            words.export(:list).as(:words)
        }
        root(:top)
      end
    }

    it 'instantiates the same module twice with different parameters' do
      parser.new.parse('1,22,3 a;b;c').should == {
        :ints  => [{:item => '1'}, {:item => '22'}, {:item => '3'}],
        :words => [{:item => 'a'}, {:item => 'b'}, {:item => 'c'}]
      }
    end

    it 'applies parameter defaults' do
      list = SeparatedList.new(:l, element: Parslet.match['0-9'].repeat(1))
      list.export(:list).parse('1,2,3').should == [
        {:item => '1'}, {:item => '2'}, {:item => '3'}]
    end

    it 'rejects unknown parameters' do
      expect {
        SeparatedList.new(:l, element: nil, bogus: 1)
      }.to raise_error(ArgumentError, /bogus/)
    end

    it 'requires all parameters without default to be bound' do
      list = SeparatedList.new(:my_list)
      expect {
        list.export(:list).parse('1,2')
      }.to raise_error(ArgumentError, /element.*my_list/)
    end
  end

  describe 'instance boundaries' do
    # Parent grammar uses rule and capture names identical to the
    # module-internal ones (:list, :separator, :delim) on purpose.
    let(:parser) {
      Class.new(Parslet::Parser) do
        rule(:integer) { match['0-9'].repeat(1) }
        rule(:word)    { match['a-z'].repeat(1) }

        # Same name as the module-internal rule; must not interfere.
        rule(:list) { str('!') }

        rule(:top) {
          ints  = ConsistentList.new(:int_list,  element: integer)
          words = ConsistentList.new(:word_list, element: word)

          str('#').capture(:delim) >>
            ints.export(:list) >> str(' ') >>
            words.export(:list) >> str(' ') >> list >>
            dynamic { |src, ctx| str(ctx.captures[:delim].to_s) }
        }
        root(:top)
      end
    }

    it 'keeps captures of two instances with identical internal names apart' do
      # Regression: both instances capture :delim internally. If the
      # captures leaked into each other, the second list could not use a
      # different delimiter than the first.
      parser.new.parse('#1,2,3 a;a;a !#').should_not be_nil
    end

    it 'enforces delimiter consistency within each instance' do
      expect { parser.new.parse('#1,2;3 a;a;a !#') }.
        to raise_error(Parslet::ParseFailed)
      expect { parser.new.parse('#1,2,3 a;a,a !#') }.
        to raise_error(Parslet::ParseFailed)
    end

    it 'does not let parent captures leak into the instance' do
      # The parent captures '#' as :delim; if the instance could see it,
      # its first separator would have to be '#' and the parse would fail.
      parser.new.parse('#1,2 a;a !#').should_not be_nil
    end

    it 'does not let instance captures leak back to the parent' do
      # The trailing dynamic rule matches the parent capture ('#'), not
      # the last delimiter captured inside an instance (';').
      expect { parser.new.parse('#1,2 a;a !;') }.
        to raise_error(Parslet::ParseFailed)
    end

    it 'resolves recursive rule references within the instance' do
      # The parent defines rule(:list) { str('!') }; the module-internal
      # recursive references to :list and :separator still resolve to the
      # module rules, otherwise nothing would parse.
      parser.new.parse('#1,2,3,4 a;a !#').should_not be_nil
    end
  end

  describe 'exports' do
    let(:list) {
      SeparatedList.new(:l, element: Parslet.match['0-9'].repeat(1))
    }

    it 'exposes exported rules as parslet atoms' do
      list.export(:list).should be_a(Parslet::Atoms::Base)
    end

    it 'refuses to expose internal rules' do
      expect {
        ConsistentList.new(:c, element: nil).export(:separator)
      }.to raise_error(ArgumentError, /internal.*:separator|'export separator'/)
    end

    it 'refuses unknown rule names' do
      expect {
        list.export(:nope)
      }.to raise_error(ArgumentError, /nope/)
    end

    it 'keeps module rules private on the instance' do
      list.should_not respond_to(:list)
      list.should_not respond_to(:element)
    end
  end

  describe 'error reporting' do
    let(:parser) {
      Class.new(Parslet::Parser) do
        rule(:integer) { match['0-9'].repeat(1) }
        rule(:word)    { match['a-z'].repeat(1) }

        rule(:top) {
          ints  = SeparatedList.new(:int_list,  element: integer)
          words = SeparatedList.new(:word_list, element: word,
                                    separator: str(';'))

          ints.export(:list) >> str(' ') >> words.export(:list)
        }
        root(:top)
      end
    }

    it 'qualifies rule names with the instance path' do
      expect { parser.new.parse('1,2,3 a;b,c') }.
        to raise_error(Parslet::ParseFailed) { |error|
          tree = error.parse_failure_cause.ascii_tree
          tree.should include('INT_LIST.LIST')
          tree.should include('WORD_LIST.LIST')
        }
    end

    it 'keeps the default instance path readable' do
      list = SeparatedList.new(element: Parslet.str('x'))
      list.instance_path.should == 'SeparatedList'
    end

    it 'composes nested instance paths via :parent' do
      inner = SeparatedList.new(:inner,
        element: Parslet.str('x'),
        parent: SeparatedList.new(:outer, element: Parslet.str('y')))
      inner.instance_path.should == 'outer.inner'
    end
  end
end
