class Parslet::Atoms::Layout < Parslet::Atoms::Base
  class Atom < Parslet::Atoms::Base
    attr_reader :config

    def initialize(config)
      super()
      @config = config
    end

    def cached?
      false
    end

    def apply(source, context, consume_all)
      context.begin_layout(config)
      begin
        super
      ensure
        context.end_layout(config)
      end
    end

    private

    def next_line(source, context)
      scan = config.scan(source, mode)
      unless scan
        return failure(source, context)
      end

      if scan.error_message
        return context.err_at(
          self,
          source,
          scan.error_message,
          scan.error_position
        )
      end

      scan
    end

    def mode
      :next
    end

    def failure(source, context)
      context.err_at(
        self,
        source,
        "Layout atoms may only be used at the beginning of a line.",
        source.pos
      )
    end
  end

  class Indent < Atom
    def try(source, context, consume_all)
      scan = next_line(source, context)
      return scan unless scan.is_a?(Parslet::Layout::Config::ScanResult)

      if scan.end_of_input?
        return context.err_at(
          self,
          source,
          "Expected a more deeply indented line before end of input.",
          source.pos
        )
      end

      current = context.layout_indents.last
      unless scan.width > current
        return context.err_at(
          self,
          source,
          "Expected indentation deeper than #{current} columns, but got #{scan.width}.",
          scan.indentation.position
        )
      end

      context.layout_indents.push(scan.width)
      context.layout_at_content
      succ(nil)
    end

    def to_s_inner(prec)
      "INDENT"
    end
  end

  class SameLevel < Atom
    def try(source, context, consume_all)
      return succ(nil) if context.layout_phase == :content

      scan = next_line(source, context)
      return scan unless scan.is_a?(Parslet::Layout::Config::ScanResult)

      current = context.layout_indents.last

      if scan.end_of_input?
        return context.err_at(
          self,
          source,
          "Expected another line indented #{current} columns before end of input.",
          source.pos
        )
      end

      unless scan.width == current
        return context.err_at(
          self,
          source,
          "Expected indentation of #{current} columns, but got #{scan.width}.",
          scan.indentation.position
        )
      end

      context.layout_at_content
      succ(nil)
    end

    def to_s_inner(prec)
      "SAME_LEVEL"
    end
  end

  class Dedent < Atom
    def failure(source, context)
      context.err_at(
        self,
        source,
        "Expected a less indented line before end of current line.",
        source.pos
      )
    end

    def mode
      :dedent
    end

    def try(source, context, consume_all)
      scan = next_line(source, context)
      return scan unless scan.is_a?(Parslet::Layout::Config::ScanResult)

      current = context.layout_indents.last

      accepted = scan.end_of_input? ? current > 0 : scan.width < current
      unless accepted
        actual = scan.end_of_input? ? nil : scan.width
        return context.err_at(
          self,
          source,
          "Expected indentation less than #{current} columns#{actual.nil? ? " before end of input" : ", but got #{actual}"}.",
          actual.nil? ? source.pos : scan.indentation.position
        )
      end

      context.layout_indents.pop
      context.layout_at_indentation unless scan.end_of_input?
      succ(nil)
    end

    def to_s_inner(prec)
      "DEDENT"
    end
  end
end
