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
      @cut_stack = []
      @cut_events = Hash.new(0)
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
        cut_depth = @cut_stack.size
        cuts_at_depth = @cut_events[cut_depth]
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          # If a cut fired inside obj reached the cut barrier that is 
          # currently innermost, remember that fact; a cache hit must 
          # replay the commit against whatever barrier is innermost then.
          cut_escaped = @cut_events[cut_depth] > cuts_at_depth ? true : nil
          set obj, beg, [result, source.bytepos-beg, cut_escaped]
        end
        
        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance, cut_escaped = entry

      # Replay the side effect a cut had when this cache entry was 
      # created. (see above)
      cut! if cut_escaped

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + advance
      return result
    end  

    # Commits the innermost enclosing alternation to the branch that is 
    # currently being tried. Called by Atoms::Cut. If no alternation is 
    # currently being tried, the cut has no effect.
    #
    def cut!
      @cut_events[@cut_stack.size] += 1
      @cut_stack[-1] = true unless @cut_stack.empty?
    end

    # Opens a new cut scope. Cuts fired while this scope is open only 
    # affect this scope, never an outer one. Used by Atoms::Alternative to
    # scope commits to a single alternation and by Atoms::Lookahead to 
    # discard cuts fired during speculation.
    #
    def push_cut_barrier
      @cut_stack.push(false)
    end

    # Closes the innermost cut scope, returning true if a cut was fired 
    # while it was open.
    #
    def pop_cut_barrier
      @cut_stack.pop
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
