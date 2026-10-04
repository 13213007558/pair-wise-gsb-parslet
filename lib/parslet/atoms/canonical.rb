require 'rbconfig'

class Parslet::Atoms::Canonical < Parslet::Atoms::Base
  attr_reader :str, :form, :casefold

  FORMS = [:nfc, :nfd].freeze
  GRAPHEME_EXTEND = /\p{Grapheme_Extend}/
  MAX_EXPANSION_FACTOR = 18

  def self.unicode_version
    Parslet::Unicode::VERSION
  end

  def initialize(str, form=:nfc, casefold=false)
    super()

    options = nil
    default_form = :nfc

    if form.is_a?(Hash)
      options = form
    elsif casefold.is_a?(Hash)
      options = casefold
      default_form = form
    end

    if options
      form = options.fetch(:form, options.fetch(:normalization_form, default_form))
      casefold = full_case_fold?(options, false)
    end

    @str = utf8(str.to_s)
    @form = form.to_sym
    @casefold = casefold

    unless FORMS.include?(@form)
      raise ArgumentError, "Normalization form must be one of #{FORMS.map(&:inspect).join(', ')}"
    end
    unless @str.valid_encoding?
      raise ArgumentError, "Canonical literals require valid UTF-8 strings."
    end

    @expected = normalize(@str)
  end

  def normalization_form
    form
  end

  def unicode_version
    self.class.unicode_version
  end

  def accept(visitor)
    visitor.visit_str(str)
  end

  def try(source, context, consume_all)
    length = match_length(source.rest)

    if length
      return succ(source.consume(length))
    end

    return context.err(self, source, error_msgs[:premature]) \
      if source.chars_left < @str.size

    error_pos = source.pos
    context.err_at(
      self, source,
      [error_msgs[:failed], source.consume([@str.size, 1].max)], error_pos)
  end

  def to_s_inner(prec)
    "canonical(#{str.inspect}, #{form.inspect}#{', casefold' if casefold})"
  end

  private

  def full_case_fold?(options, default)
    return options.fetch(:casefold, default) if options.has_key?(:casefold)
    return options.fetch(:full_case_fold, default) if options.has_key?(:full_case_fold)
    options[:case] == :fold || default
  end

  def utf8(string)
    if string.encoding == Encoding::ASCII_8BIT
      candidate = string.dup.force_encoding(Encoding::UTF_8)
      return candidate if candidate.valid_encoding?
    end

    return string if string.encoding == Encoding::UTF_8
    string.encode(Encoding::UTF_8)
  rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
    raise ArgumentError, "Canonical literals require Unicode input."
  end

  def normalize(value)
    value = utf8(value)
    value =
      if value.respond_to?(:unicode_normalize)
        value.unicode_normalize(form)
      else
        raise NotImplementedError, "This Ruby does not support Unicode normalization."
      end

    casefold ? full_case_fold(value) : value
  end

  def full_case_fold(value)
    value.downcase(:fold)
  rescue ArgumentError
    raise NotImplementedError, "This Ruby does not support Unicode case folding."
  end

  def match_length(input)
    original = input
    input =
      begin
        utf8(input)
      rescue ArgumentError
        return nil
      end

    prefix = String.new.force_encoding(Encoding::UTF_8)
    window = input[0, @expected.size * MAX_EXPANSION_FACTOR].to_s

    window.each_codepoint do |codepoint|
      prefix << codepoint
      normalized = normalize(prefix)
      next unless normalized == @expected || normalized.size <= @expected.size

      if normalized == @expected
        return nil unless stable_match?(input, prefix)
        return original.encoding == Encoding::ASCII_8BIT ? prefix.bytesize : prefix.size
      end
    end

    nil
  end

  def stable_match?(input, prefix)
    following = input[prefix.size]
    following.nil? ||
      (!GRAPHEME_EXTEND.match?(following) &&
        normalize(prefix + following).start_with?(@expected))
  end

  def error_msgs
    @error_msgs ||= {
      premature: 'Premature end of input',
      failed: "Expected #{str.inspect} canonically, but got "
    }
  end
end
