require 'spec_helper'

describe Parslet::Atoms::Cut do
  include Parslet

  describe 'parser construction' do
    it 'is available as Parslet#cut' do
      cut.should be_a(Parslet::Atoms::Cut)
    end
    it 'inspects as cut' do
      (str('a') >> cut >> str('b')).inspect.should == "'a' cut 'b'"
    end
    it 'is not cached, since it has a side effect on the parse' do
      cut.should_not be_cached
    end
  end

  context 'outside of any alternation' do
    it 'succeeds without consuming input' do
      (str('a') >> cut >> str('b')).should parse('ab')
    end
  end

  context 'in a flat alternation' do
    let(:parser) { (str('a') >> cut >> str('b')) | str('c') }

    it 'lets the committed branch match' do
      parser.should parse('ab')
    end
    it 'still tries other branches when the cut is never reached' do
      parser.should parse('c')
    end
  end

  context 'when the parse fails after the cut' do
    let(:parser) { (str('a') >> cut >> str('b')) | (str('a') >> str('c')) }

    it 'does not try the remaining alternatives' do
      # Without the cut, the second branch would match 'ac'.
      parser.should_not parse('ac')
    end
    it 'reports the branchs error directly, not the alternations' do
      cause = catch_failed_parse { parser.parse('ac') }

      cause.ascii_tree.should ==
        "Failed to match sequence ('a' cut 'b') at line 1 char 2.\n" +
        "`- Expected \"b\", but got \"c\" at line 1 char 2.\n"
    end
    it 'preserves the real failure position for the Deepest reporter' do
      reporter = Parslet::ErrorReporter::Deepest.new
      catch_failed_parse { parser.parse('ax', reporter: reporter) }

      reporter.deepest_cause.to_s.should ==
        'Expected "b", but got "x" at line 1 char 2.'
    end
  end

  context 'keyword followed by a cut (config section scenario)' do
    let(:section) {
      (str('header') >> cut >> str('{')) |
      (str('footer') >> str('{'))
    }

    it 'reports a syntax error after the keyword directly' do
      cause = catch_failed_parse { section.parse('header;') }

      cause.ascii_tree.should ==
        "Failed to match sequence ('header' cut '{') at line 1 char 7.\n" +
        "`- Expected \"{\", but got \";\" at line 1 char 7.\n"
    end
    it 'does not try to reinterpret the input as another section type' do
      cause = catch_failed_parse { section.parse('header;') }

      cause.ascii_tree.should_not include('footer')
    end
  end

  context 'in nested alternations' do
    let(:inner) { (str('b') >> cut >> str('c')) | (str('b') >> str('d')) }
    let(:parser) { (str('a') >> inner) | (str('a') >> str('e')) }

    it 'seals only the inner alternation' do
      # Without the cut, the inner second branch 'b' 'd' would match.
      parser.should_not parse('abd')
    end
    it 'lets an outer alternative recover from a committed inner failure' do
      recovering = (str('a') >> inner) | (str('a') >> str('b') >> str('d'))

      recovering.should parse('abd')
    end
    it 'shows the sealed layer in the error tree' do
      cause = catch_failed_parse { parser.parse('abx') }

      # The inner alternation fails with its committed branchs error (no
      # inner "Expected one of"), while the outer alternation has tried
      # both of its branches.
      cause.ascii_tree.should ==
        "Expected one of ['a' ('b' cut 'c' / 'b' 'd'), 'a' 'e'] at line 1 char 1.\n" +
        "|- Failed to match sequence ('a' ('b' cut 'c' / 'b' 'd')) at line 1 char 2.\n" +
        "|  `- Failed to match sequence ('b' cut 'c') at line 1 char 3.\n" +
        "|     `- Expected \"c\", but got \"x\" at line 1 char 3.\n" +
        "`- Failed to match sequence ('a' 'e') at line 1 char 2.\n" +
        "   `- Expected \"e\", but got \"b\" at line 1 char 2.\n"
    end
  end

  context 'inside a lookahead' do
    it 'leaves no commit behind when positive speculation fails' do
      parser = ((str('x') >> cut >> str('y')).present? >> str('a')) |
               (str('x') >> str('b'))

      parser.should parse('xb')
    end
    it 'leaves no commit behind when positive speculation succeeds' do
      parser = ((str('x') >> cut).present? >> str('y')) |
               (str('x') >> str('z'))

      parser.should parse('xz')
    end
    it 'leaves no commit behind from negative speculation' do
      parser = ((str('a') >> cut).absent? >> str('b')) | str('a')

      parser.should parse('a')
    end
  end

  context 'with the packrat cache' do
    # The rule 'kw' is applied twice at the same input position: first
    # under the alternation in 'mid', then (from the cache) under the
    # alternation in 'top'. The cached result must replay the cut against
    # the alternation that is innermost at replay time.
    let(:parser_class) {
      Class.new(Parslet::Parser) do
        rule(:kw)  { str('a') >> cut }
        rule(:mid) { (kw >> str('b')) | (str('a') >> str('x')) }
        rule(:top) {
          (mid >> str('c')) |
          (kw >> str('d') >> str('z')) |
          (str('a') >> str('d'))
        }
        root(:top)
      end
    }

    it 'replays the cut when a cached rule is applied under a new alternation' do
      # If the cut were lost through the cache, the third branch of 'top'
      # would match 'ad'.
      parser_class.new.should_not parse('ad')
    end
    it 'still lets the committed branch match' do
      parser_class.new.should parse('adz')
    end
  end
end
