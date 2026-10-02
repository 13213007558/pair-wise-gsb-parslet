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
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @cut_marks = []
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
        
      # Not in cache yet? Return early.
      unless entry = lookup(obj, beg)
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
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

    # Commits to the innermost enclosing choice (see
    # Parslet::Atoms::Alternative). After this has been called, the
    # innermost choice will not try any more of its alternatives; a failure
    # is reported directly. If there is no enclosing choice, cutting is a
    # no-op.
    #
    def cut!
      @cut_marks[-1] = true unless @cut_marks.empty?
    end

    # Returns true if the innermost enclosing choice has been committed to
    # using #cut!.
    #
    def cut?
      @cut_marks.last ? true : false
    end

    # Starts a new choice. Choices nest; a cut always commits to the
    # innermost choice only and never leaks into outer ones.
    #
    def push_choice
      @cut_marks.push(false)
    end

    # Ends the innermost choice, discarding its commit state.
    #
    def pop_choice
      @cut_marks.pop
    end

    # Snapshots the current commit state of all enclosing choices. Used by
    # speculative parses (lookaheads) that must not leave commit state
    # behind.
    #
    def save_cut_state
      @cut_marks.dup
    end

    # Restores a commit state snapshot made with #save_cut_state.
    #
    def restore_cut_state(state)
      @cut_marks = state
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
