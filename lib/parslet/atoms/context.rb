module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    # @param layout_options [Hash, Parslet::Layout::Policy] layout (indentation)
    #   policy configuration, see Parslet::Layout::Policy
    def initialize(reporter=Parslet::ErrorReporter::Tree.new, layout_options=nil)
      @cache = Hash.new { |h, k| h[k] = {} }
      @layout_cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @layout_policy = Parslet::Layout::Policy.build(layout_options)
      @layout = nil
      @layout_used = false
      @layout_violation = nil
    end
    
    # Caches a parse answer for obj at source.pos. Applying the same parslet
    # at one position of input always yields the same result, unless the input
    # has changed. 
    #
    # We need the entire source here so we can ask for how many characters 
    # were consumed by a successful parse. Imitation of such a parse must 
    # advance the input pos by the same amount of bytes.
    #
    def try_with_cache(obj, source, consume_all)
      beg = source.bytepos

      # While layout tracking is active, parse results depend on the current
      # layout (indentation) state. Cache entries are therefore keyed by a
      # layout fingerprint and replay the layout state transition on a hit.
      if @layout
        key = [obj.object_id, @layout.snapshot]

        unless entry = @layout_cache[beg][key]
          result = obj.try(source, self, consume_all)

          if obj.cached?
            @layout_cache[beg][key] =
              [result, source.bytepos-beg, @layout && @layout.snapshot]
          end

          return result
        end

        result, advance, layout_after = entry
        source.bytepos = beg + advance

        if layout_after
          layout.restore(layout_after)
        else
          @layout = nil
        end

        return result
      end

      # Not in cache yet? Return early.
      unless entry = lookup(obj, beg)
        result = obj.try(source, self, consume_all)

        # Results produced while layout tracking got activated depend on
        # layout state; they must not be replayed from the plain cache.
        if obj.cached? && !@layout
          set obj, beg, [result, source.bytepos-beg]
        end

        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance = entry

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + advance
      return result
    end

    # The current layout (indentation) state. Activates layout tracking
    # lazily: grammars that never use layout atoms pay no penalty for it.
    #
    def layout
      @layout_used = true
      @layout ||= Parslet::Layout::State.new(@layout_policy)
    end

    # True if layout (indentation) atoms have been used during this parse,
    # even if the layout state has since been rolled back. 
    #
    def layout_used?
      @layout_used
    end

    # Records a layout (tab) policy violation. Violations don't abort the
    # parse (alternatives roll back as usual), but if the parse as a whole
    # fails, the deepest recorded violation is the error reported to the
    # user - it pinpoints the exact line and column of the problem.
    #
    def note_layout_violation(violation)
      if @layout_violation.nil? ||
          violation.bytepos > @layout_violation.bytepos
        @layout_violation = violation
      end
    end

    # The deepest layout policy violation recorded during this parse, if
    # any. See #note_layout_violation.
    #
    attr_reader :layout_violation

    # Returns a mark that allows rolling the layout state back to the current
    # point, or nil if layout tracking is inactive. See #layout_rollback.
    #
    def layout_mark
      @layout && @layout.snapshot
    end

    # Rolls layout state back to +mark+ (see #layout_mark). A nil mark means
    # layout tracking was inactive when the mark was taken; any state created
    # since is discarded entirely.
    #
    def layout_rollback(mark)
      if mark
        layout.restore(mark)
      else
        @layout = nil
      end
    end
    
    # Report an error at a given position. 
    # @see ErrorReporter
    #
    def err_at(*args)
      return [false, @reporter.err_at(*args)] if @reporter
      return [false, nil]
    end
    
    # Report an error. 
    # @see ErrorReporter
    #
    def err(*args)
      return [false, @reporter.err(*args)] if @reporter
      return [false, nil]
    end

    # Report a successful parse.
    # @see ErrorReporter::Contextual
    #
    def succ(*args)
      return [true, @reporter.succ(*args)] if @reporter
      return [true, nil]
    end

    # Returns the current captures made on the input (see
    # Parslet::Atoms::Base#capture). Use as follows: 
    # 
    #   context.captures[:foobar] # => returns capture :foobar
    #
    attr_reader :captures
    
    # Starts a new scope. Use the #scope method of Parslet::Atoms::DSL
    # to call this. 
    #
    def scope
      captures.push
      yield
    ensure
      captures.pop
    end
    
  private 
    # NOTE These methods use #object_id directly, since that seems to bring the
    # most performance benefit. This is a hot spot; going through
    # Atoms::Base#hash doesn't yield as much.
    #
    def lookup(obj, pos)
      @cache[pos][obj.object_id] 
    end
    def set(obj, pos, val)
      @cache[pos][obj.object_id] = val
    end
  end
end
