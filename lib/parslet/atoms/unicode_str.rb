
require 'unicode_normalize/tables'

# Matches a string of characters up to Unicode canonical equivalence, 
# optionally applying full case folding to both the literal and the input 
# before comparing them. 
#
# Canonical equivalence means that text that looks the same can be matched
# even though it is stored differently: 'é' as a single codepoint or as 
# 'e' followed by a combining acute accent are the same text for this 
# atom. With case folding enabled, 'ß' and 'SS' are the same text as 
# well. 
#
# Example: 
#
#   unicode_str('café')                     # matches 'café' and 'café'
#   unicode_str('straße', case_fold: true)  # matches 'STRASSE' too
#
# The atom consumes whole normalization units only: if the matching input
# span would end in the middle of a combining character sequence, the 
# match fails instead of consuming half of the sequence. Matching never 
# modifies the input or its position system - captured results are slices
# of the original input with real offsets, not normalized replacement 
# text. 
#
class Parslet::Atoms::UnicodeStr < Parslet::Atoms::Base
  # Normalization forms that express canonical equivalence. 
  FORMS = [:nfc, :nfd].freeze

  # Version of the Unicode character data that normalization and case 
  # folding are based on. 
  UNICODE_VERSION =
    if defined?(Encoding::UNICODE_VERSION)
      Encoding::UNICODE_VERSION
    elsif defined?(UnicodeNormalize::UNICODE_VERSION)
      UnicodeNormalize::UNICODE_VERSION
    else
      'unknown'
    end

  # Canonical combining classes of all non-starter characters, from the 
  # Unicode data shipped with this Ruby. Used to detect normalization 
  # boundaries. 
  CCC = UnicodeNormalize::CLASS_TABLE

  attr_reader :str
  attr_reader :form

  def initialize(str, form: :nfc, case_fold: false)
    super()

    if !FORMS.include?(form)
      raise ArgumentError, "form must be one of #{FORMS.inspect}"
    end

    @str = str.to_s
    @form = form
    @case_fold = case_fold ? true : false

    # The literal, normalized to @form (and folded), for inspection. 
    @normalized = normalize(@str, @form)

    # Comparison key. NFD based: neither NFD nor full case folding ever 
    # shrink a string, so the key length bounds the length of any matching
    # input span, and the key length of a span grows strictly with every 
    # additional input character. 
    @key = normalize(@str, :nfd)
  end

  # True if full case folding is applied before comparing. 
  #
  def case_fold?
    @case_fold
  end

  # The literal after normalization to #form (and case folding, if 
  # enabled). This is the text the atom compares against; matched input is
  # never replaced by it. 
  #
  attr_reader :normalized

  # Version of the Unicode data used for normalization and case folding. 
  #
  def unicode_version
    UNICODE_VERSION
  end

  def error_msgs
    @error_msgs ||= {
      premature: 'Premature end of input',
      failed: "Expected #{str.inspect}, but got "
    }
  end

  def try(source, context, consume_all)
    return succ(source.consume(0)) if @key.empty?

    rest = source.rest

    # A matching span is never longer (in characters) than the key. 
    max_len = [@key.length, rest.length].min
    len = 0
    while len < max_len
      len += 1
      key = normalize(rest[0, len], :nfd)

      # Key length grows strictly with every input character, so once it 
      # exceeds the key length no match is possible anymore. 
      break if key.length > @key.length
      next unless key == @key

      # The span must end on a normalization boundary; consuming only part
      # of a combining character sequence is not allowed. No longer span 
      # can produce the same key, so an unclean boundary ends the search. 
      next_char = rest[len]
      if next_char.nil? || starter?(next_char)
        return succ(source.consume(len))
      end

      return err_failed(source, context, rest)
    end

    err_failed(source, context, rest)
  end

  def to_s_inner(prec)
    suffix = case_fold? ? ', case_fold: true' : ''
    "unicode_str(#{str.inspect}#{suffix})"
  end

private

  # Normalizes string to the given form, applying full case folding if 
  # enabled. 
  #
  def normalize(string, form)
    result = string.unicode_normalize(form)
    result = result.downcase(:fold).unicode_normalize(form) if case_fold?
    result
  end

  # True if the given character starts a new normalization unit, i.e. has 
  # a canonical combining class of zero. 
  #
  def starter?(char)
    (CCC[char] || 0).zero?
  end

  def err_failed(source, context, rest)
    return context.err(self, source, error_msgs[:premature]) if rest.empty?

    error_pos = source.pos
    context.err_at(
      self, source,
      [error_msgs[:failed], source.consume([rest.length, @key.length].min)],
      error_pos)
  end
end
