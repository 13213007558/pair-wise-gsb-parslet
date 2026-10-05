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
      @frames = nil
    end

    # Enables tracking of parse frames (atom applications). Used by
    # Parslet::Session to compute how much input must be retained for
    # backtracking. Off by default.
    #
    def track_frames!
      @frames = []
    end

    def tracking?
      !@frames.nil?
    end

    # Called by Parslet::Atoms::Base#apply when frame tracking is
    # enabled: records that +atom+ started matching at +bytepos+.
    #
    def push_frame(bytepos, atom)
      @frames << [bytepos, atom]
    end

    def pop_frame
      @frames.pop
    end

    # The smallest byte position the currently suspended parse may still
    # rewind to and read from, or nil if there is no such position (the
    # parse can then only continue at or after the read head).
    #
    def rewind_horizon
      return nil unless @frames

      horizon = nil
      @frames.each_with_index do |(pos, atom), idx|
        rereads = atom.streaming_reread?
        rereads ||= idx > 0 && @frames[idx-1][1].streaming_reread_children?
        horizon = pos if rereads && (horizon.nil? || pos < horizon)
      end
      horizon
    end

    # Drops all packrat cache entries for positions before +bytepos+;
    # those positions will never be parsed at again.
    #
    def prune_before(bytepos)
      @cache.delete_if { |pos, _| pos < bytepos }
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
