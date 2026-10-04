# Encoding: UTF-8

require 'spec_helper'

describe Parslet::Atoms::UnicodeStr do
  def unicode_str(s, **opts)
    described_class.new(s, **opts)
  end

  describe 'construction' do
    include Parslet

    it "should allow unicode_str(str) form" do
      unicode_str('é').should be_a(described_class)
    end
    it "should allow unicode_str(str, case_fold: true) form" do
      unicode_str('ß', case_fold: true).should be_a(described_class)
    end
    it "rejects forms that don't express canonical equivalence" do
      expect { described_class.new('x', form: :nfkc) }.
        to raise_error(ArgumentError)
    end
  end

  describe 'inspection' do
    it "exposes the normalization form" do
      unicode_str('é').form.should == :nfc
      unicode_str('é', form: :nfd).form.should == :nfd
    end
    it "exposes the Unicode data version" do
      unicode_str('é').unicode_version.should =~ /^\d+\.\d+\.\d+$/
    end
    it "exposes the normalized literal" do
      unicode_str("é").normalized.should == "é"
      unicode_str("é", form: :nfd).normalized.should == "é"
    end
    it "exposes case folding" do
      unicode_str('é').case_fold?.should == false
      unicode_str('é', case_fold: true).case_fold?.should == true
    end
  end

  describe 'canonical equivalence' do
    it "matches a precomposed literal against decomposed input" do
      unicode_str('é').should parse("é")
    end
    it "matches a decomposed literal against precomposed input" do
      unicode_str("é").should parse("é")
    end
    it "matches mixed input spanning several codepoints" do
      # ế = e + combining circumflex + combining acute
      unicode_str("ế").should parse("ế")
      unicode_str("ế").should parse("ế")
    end
    it "matches canonically reordered combining marks" do
      # ̕ (ccc 232) and ̀ (ccc 230) normalize to ̀̕
      unicode_str("è̕").should parse("è̕")
    end
    it "rejects text that is merely compatibility equivalent" do
      unicode_str('ffi').should_not parse("ﬃ")
    end
  end

  describe 'normalization units' do
    it "refuses to consume half of a combining sequence (precomposed)" do
      unicode_str('é').should_not parse("é̂")
    end
    it "refuses to consume half of a combining sequence (decomposed)" do
      unicode_str('é').should_not parse("é̂")
    end
  end

  describe 'case folding' do
    it "is off by default" do
      unicode_str('ss').should_not parse('ß')
    end
    it "matches german sharp s against 'ss' when folding" do
      unicode_str('ss', case_fold: true).should parse('ß')
    end
    it "matches capital sharp s against 'ss' when folding" do
      unicode_str('ss', case_fold: true).should parse('ẞ')
    end
    it "expands sharp s in the literal when folding" do
      unicode_str('ß', case_fold: true).should parse('SS')
      unicode_str('ß', case_fold: true).should parse('Ss')
    end
    it "folds a whole word" do
      unicode_str('straße', case_fold: true).should parse('STRASSE')
    end
  end

  describe 'interaction with other atoms' do
    include Parslet

    it "works between ordinary str atoms" do
      (str('a') >> unicode_str('é') >> str('b')).should parse("aéb")
      (str('a') >> unicode_str('é') >> str('b')).should parse("aéb")
    end
    it "captures the original input slice, byte for byte" do
      result = (str('a') >> unicode_str('é').as(:e) >> str('b')).
        parse("aéb")

      slice = result[:e]
      slice.to_s.should == "é"
      slice.to_s.bytes.should == "é".bytes
      slice.to_s.bytes.should_not == "é".bytes
      slice.offset.should == 1
      slice.line_and_column.should == [1, 2]
    end
    it "captures the original sharp s, not its expansion" do
      result = unicode_str('ss', case_fold: true).as(:s).parse('ß')

      result[:s].to_s.should == 'ß'
      result[:s].to_s.bytes.should == 'ß'.bytes
    end
    it "keeps coordinates pointing at the original input after backtracking" do
      parser = (str('a') >> unicode_str('é') >> str('b')) |
               (str('a') >> unicode_str('é').as(:e) >> str('c'))

      result = parser.parse("aéc")
      result[:e].to_s.should == "é"
      result[:e].offset.should == 1
      result[:e].line_and_column.should == [1, 2]
    end
  end
end
