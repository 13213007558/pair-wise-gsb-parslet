require 'spec_helper'

describe Parslet::Atoms::Cut do
  include Parslet

  describe 'as a standalone atom' do
    it 'matches without consuming input' do
      cut.parse('', prefix: true).should be_nil
    end
    it 'is a no-op outside of any choice' do
      (str('a') >> cut >> str('b')).parse('ab').should == 'ab'
    end
    it 'leaves no trace in the result tree' do
      (str('a') >> cut >> str('b')).parse('ab').should == 'ab'
    end
    it 'inspects as cut' do
      (str('a') >> cut >> str('b')).inspect.should == "'a' cut 'b'"
    end
  end

  describe 'inside a choice' do
    let(:parser) { (str('a') >> cut >> str('b')) | str('ac') }

    it 'lets the committed branch succeed' do
      parser.should parse('ab')
    end
    it 'commits: does not try other branches when failing after the cut' do
      expect { parser.parse('ac') }.to raise_error(Parslet::ParseFailed)
    end
    it 'still tries other branches when failing before the cut' do
      parser = (str('x') >> cut >> str('b')) | str('ac')
      parser.should parse('ac')
    end

    context 'without a cut, for contrast' do
      let(:parser) { (str('a') >> str('b')) | str('ac') }
      it 'backtracks into the other branch' do
        parser.should parse('ac')
      end
    end
  end

  describe 'error reporting after commit' do
    let(:parser) { (str('a') >> cut >> str('b')) | str('c') }
    let(:cause) { catch_failed_parse { parser.parse('ax') } }

    it 'reports the real failure position, not the choice position' do
      cause.pos.bytepos.should == 1
    end
    it 'keeps the true failure in the error tree' do
      cause.ascii_tree.should ==
        "Failed to match sequence ('a' cut 'b') at line 1 char 2.\n" +
        "`- Expected \"b\", but got \"x\" at line 1 char 2.\n"
    end

    context 'with the deepest error reporter' do
      it 'points at the committed failure' do
        expect {
          parser.parse('ax', reporter: Parslet::ErrorReporter::Deepest.new)
        }.to raise_error(Parslet::ParseFailed, /char 2/)
      end
    end
  end

  describe 'in nested choices' do
    # inner choice is sealed by the cut, outer choice is not
    let(:inner) { (str('ab') >> cut >> str('x')).as(:first) | str('abc').as(:second) }
    let(:parser) { (inner >> str('d')) | str('abcd').as(:fallback) }

    it 'seals only the inner choice and still tries outer branches' do
      # The cut seals the inner choice: 'abc' (its second branch) is never
      # tried. The outer choice is not committed: 'abcd' is tried and
      # matches.
      parser.parse('abcd').should == { fallback: 'abcd' }
    end
    it 'makes the sealed layer visible in the returned error' do
      cause = catch_failed_parse { parser.parse('abc') }

      # The inner committed failure (char 3) survives in the error tree,
      # alongside the failure of the outer branch that was still tried.
      cause.ascii_tree.should include('Expected "x", but got "c" at line 1 char 3')
      cause.ascii_tree.should include('Premature end of input at line 1 char 1')
    end
  end

  describe 'inside lookaheads' do
    it 'leaves no commit state behind (positive lookahead, match)' do
      parser = ((str('a') >> cut).present? >> str('b')) | str('a')
      parser.should parse('a')
    end
    it 'leaves no commit state behind (positive lookahead, mismatch after cut)' do
      parser = ((str('a') >> cut >> str('b')).present? >> str('x')) | str('a')
      parser.should parse('a')
    end
    it 'leaves no commit state behind (negative lookahead)' do
      parser = ((str('a') >> cut).absent? >> str('z')) | str('a')
      parser.should parse('a')
    end
  end

  describe 'config section example' do
    # Once a section keyword has been read, a syntax error in the section
    # body is reported directly instead of trying other section types.
    let(:section_a) { str('alpha') >> cut >> str('!') }
    let(:section_b) { str('al') >> str('?') }
    let(:parser) { section_a | section_b }

    it 'parses a valid section' do
      parser.should parse('alpha!')
    end
    it 'reports body errors directly at their position' do
      cause = catch_failed_parse { parser.parse('alpha?') }
      cause.ascii_tree.should include('Expected "!", but got "?" at line 1 char 6')
    end
    it 'still tries other section types when the keyword does not match' do
      parser.should parse('al?')
    end
  end
end
