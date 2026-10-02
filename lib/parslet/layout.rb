module Parslet
  # Layout-sensitive parsing support. A layout is configured once for a parser
  # and exposes composable atoms that observe and update the current logical
  # indentation level.
  #
  class Layout
    class ConfigurationError < ArgumentError; end

    class Config
      INDENTATION = /[ \t]*/

      POLICY_ALIASES = {
        :spaces              => :spaces,
        :space               => :spaces,
        :only_spaces         => :spaces,
        :tabs                => :tabs,
        :tab                 => :tabs,
        :only_tabs           => :tabs,
        :consistent          => :consistent,
        :consistent_indent   => :consistent,
        :mixed               => :mixed,
        :allow_mixed         => :mixed,
        :tabs_and_spaces     => :mixed
      }

      ScanResult = Struct.new(
        :skipped, :indentation, :width, :error_position, :error_message, :consume_indentation,
        keyword_init: true
      ) do
        def end_of_input?
          indentation.nil?
        end
      end

      LINE = /(?:[^\S\n]*(?:\n|\r\n?))/

      attr_reader :tab_width, :tab_policy

      def self.default
        new
      end

      def initialize(tab_width: 8, tab_policy: :consistent)
        tab_width = Integer(tab_width)
        raise ConfigurationError, "Tab width must be positive." unless tab_width > 0

        tab_policy = POLICY_ALIASES.fetch(tab_policy.to_sym, nil)
        unless [:spaces, :tabs, :consistent, :mixed].include?(tab_policy)
          raise ConfigurationError, "Unknown tab policy #{tab_policy.inspect}."
        end

        @tab_width = tab_width
        @tab_policy = tab_policy
      end

      # Moves to the next nonblank line when required (when called after a
      # token on the current line), then measures and consumes its
      # indentation. Atoms may also stay on the current physical line.
      #
      def scan(source, mode=:next)
        consume_indentation = mode != :dedent
        if source.beginning_of_line?
          while source.matches?(LINE)
            skipped = source.scan(LINE)
          end
        else
          skipped = source.scan(LINE)
          while source.matches?(LINE)
            skipped = source.scan(LINE)
          end
          return nil if mode == :next && skipped.nil?
          return nil if mode == :dedent && skipped.nil? && source.chars_left > 0
        end

        if source.chars_left.zero?
          return ScanResult.new(skipped: skipped, indentation: nil)
        end

        if consume_indentation
          indentation = source.scan(INDENTATION)
        else
          indentation = source.check(INDENTATION)
        end
        width, bad_column, message = measure(indentation.to_s)
        error_position = indentation.position + (bad_column || 0)

        ScanResult.new(
          skipped: skipped,
          indentation: indentation,
          width: width,
          error_position: bad_column ? error_position : nil,
          error_message: message,
          consume_indentation: consume_indentation
        )
      end

    private

      def measure(prefix)
        case tab_policy
        when :spaces
          bad = prefix.bytes.index("\t".ord)
          [prefix.bytesize, bad, "Tabs are not allowed in indentation."]
        when :tabs
          bad = prefix.bytes.index(" ".ord)
          [prefix.bytesize * tab_width, bad, "Spaces are not allowed in indentation."]
        when :consistent
          if prefix.include?("\t") && prefix.include?(" ")
            first = prefix[0]
            other = first == "\t" ? " " : "\t"
            bad = prefix.bytes.index(other.ord)
            [nil, bad, "Indentation cannot mix tabs and spaces."]
          elsif prefix.include?("\t")
            [prefix.bytesize * tab_width, nil, nil]
          else
            [prefix.bytesize, nil, nil]
          end
        when :mixed
          width = prefix.each_char.reduce(0) do |column, character|
            if character == "\t"
              (column / tab_width + 1) * tab_width
            else
              column + 1
            end
          end
          [width, nil, nil]
        end
      end
    end

    attr_reader :config

    def initialize(config=Config.default)
      @config = config
      @indent = Atoms::Layout::Indent.new(config)
      @same = Atoms::Layout::SameLevel.new(config)
      @dedent = Atoms::Layout::Dedent.new(config)
    end

    def indent
      @indent
    end

    def same
      @same
    end
    alias same_level same

    def dedent
      @dedent
    end
    alias outdent dedent
  end

  # Builds a set of composable layout atoms. This is also available inside a
  # Parslet::Parser as `layout`, using that parser's configured tab policy.
  #
  def layout(tab_width: 8, tab_policy: :consistent)
    Layout.new(Layout::Config.new(
      tab_width: tab_width,
      tab_policy: tab_policy
    ))
  end
  module_function :layout
end
