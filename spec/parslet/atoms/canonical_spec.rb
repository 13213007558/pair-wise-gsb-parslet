# Encoding: UTF-8

require 'spec_helper'

describe Parslet::Atoms::Canonical do
  let(:composed_e_acute) { "\u00e9" }
  let(:decomposed_e_acute) { "e\u0301" }

  describe 'canonical equivalence' do
    it 'matches composed and decomposed input' do
      atom = described_class.new(composed_e_acute)

      expect(atom).to parse(composed_e_acute)
      expect(atom).to parse(decomposed_e_acute)
    end

    it 'honors the requested normalization form' do
      atom = described_class.new(composed_e_acute, :nfd)

      expect(atom).to parse(composed_e_acute)
      expect(atom).to parse(decomposed_e_acute)
    end

    it 'matches an input fragment that contracts during normalization' do
      expect(described_class.new("\uac00")).to parse("\u1100\u1161")
    end

    it 'does not leave a contracting normalization unit half matched' do
      atom = described_class.new("\uac00")

      expect(atom).to parse("\u1100\u1161")
      expect {
        atom.parse("\u1100\u1161\u11a8", prefix: true)
      }.to raise_error(Parslet::ParseFailed)
    end

    it 'does not consume half of a normalization unit' do
      atom = described_class.new(composed_e_acute)

      expect {
        atom.parse("\u00e9\u0300", prefix: true)
      }.to raise_error(Parslet::ParseFailed)
    end
  end

  describe 'input encoding and capture bytes' do
    it 'accepts UTF-8 bytes carried in an ASCII-8BIT string' do
      input = decomposed_e_acute.dup.force_encoding(Encoding::ASCII_8BIT)
      slice = described_class.new(composed_e_acute).parse(input)

      expect(slice.to_s.bytes).to eq(decomposed_e_acute.bytes)
      expect(slice.byte_range).to eq(0...decomposed_e_acute.bytesize)
    end
  end

  describe 'full case folding' do
    it 'matches German sharp s against its ss expansion' do
      atom = described_class.new("\u00df", :nfc, true)

      expect(atom).to parse("\u00df")
      expect(atom).to parse('SS')
    end

    it 'does not case fold unless requested' do
      atom = described_class.new("\u00df")

      expect(atom).to parse("\u00df")
      expect(atom).not_to parse('SS')
    end

    it 'accepts keyword options' do
      atom = Parslet.canonical("Stra\u00dfe", form: :nfc, casefold: true)

      expect(atom.parse('STRASSE').to_s).to eq('STRASSE')
    end

    it 'keeps the expanded match as the original input bytes' do
      input = "a=\u00df!"
      parser = Parslet.str('a=') >>
        Parslet.canonical('ss', casefold: true).as(:word) >>
        Parslet.str('!')
      result = parser.parse(input)
      slice = result.fetch(:word)

      expect(slice.to_s).to eq("\u00df")
      expect(slice.to_s.bytes).to eq("\u00df".bytes)
      expect(slice.byte_range).to eq(2...(input.bytesize - 1))
    end
  end

  describe 'ordinary source positions' do
    let(:parser) do
      Parslet.str('a=') >>
        Parslet.canonical(composed_e_acute, casefold: true).as(:word) >>
        Parslet.str('!')
    end

    it 'keeps neighboring ordinary atoms on the original coordinates' do
      input = "a=#{decomposed_e_acute}!"
      result = parser.parse(input)
      slice = result.fetch(:word)

      expect(slice.to_s).to eq(decomposed_e_acute)
      expect(slice.to_s.bytes).to eq(decomposed_e_acute.bytes)
      expect(slice.position.bytepos).to eq(2)
      expect(slice.byte_range).to eq(2...(input.bytesize - 1))
    end

    it 'restores source coordinates after backtracking' do
      source = Parslet::Source.new("z#{decomposed_e_acute}")
      context = Parslet::Atoms::Context.new(nil)
      parser = Parslet.canonical(composed_e_acute) | Parslet.str('z')

      success, value = parser.apply(source, context, false)

      expect(success).to eq(true)
      expect(value.to_s).to eq('z')
      expect(source.bytepos).to eq(1)
      expect(source.pos.charpos).to eq(1)
    end
  end

  describe 'captures' do
    it 'stores the original slice and its real byte range' do
      context = Parslet::Atoms::Context.new(nil)
      source = Parslet::Source.new(decomposed_e_acute)
      atom = described_class.new(composed_e_acute).capture(:word)

      atom.apply(source, context, true)
      captured = context.captures[:word]

      expect(captured.to_s).to eq(decomposed_e_acute)
      expect(captured.to_s.bytes).to eq(decomposed_e_acute.bytes)
      expect(captured.position.bytepos).to eq(0)
      expect(captured.byte_range).to eq(0...decomposed_e_acute.bytesize)
    end
  end

  describe 'metadata and construction' do
    it 'exposes the normalization form and Unicode data version' do
      atom = described_class.new(composed_e_acute)

      expect(atom.form).to eq(:nfc)
      expect(atom.normalization_form).to eq(:nfc)
      expect(atom.casefold).to eq(false)
      expect(atom.unicode_version).to eq(Parslet::Unicode::VERSION)
      expect(Parslet::Unicode::VERSION).to match(/\A\d+(\.\d+)*\z/)
      expect(Parslet::Unicode::NORMALIZATION_FORMS).to include(:nfc, :nfd)
    end

    it 'provides the short str and canonical_str constructors' do
      expect(Parslet.str('plain')).to be_a(Parslet::Atoms::Str)
      expect(Parslet.str(composed_e_acute, form: :nfc)).
        to be_a(described_class)
      expect(Parslet.str(composed_e_acute, :nfc, full_case_fold: true)).
        to be_a(described_class)
      expect(Parslet.str(composed_e_acute, :nfc, true)).
        to be_a(described_class)
      expect(Parslet.canonical_str(composed_e_acute, full_case_fold: true)).
        to be_a(described_class)
    end

    it 'rejects unsupported normalization forms' do
      expect { described_class.new(composed_e_acute, :nfkc) }.
        to raise_error(ArgumentError)
    end
  end
end
