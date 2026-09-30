module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    # One memoized parse answer: the result of applying an atom at a given
    # position, plus the bookkeeping needed to replay and to reuse it across
    # edits (see Parslet::Session). 
    #
    # * result: the [success, value] pair returned by the atom
    # * advance: bytes consumed on success
    # * read_end: highest byte offset (exclusive) read while computing the
    #   entry, including reads of failed branches and lookaheads
    # * captures: capture assignments ([name, value] pairs) performed while
    #   computing the entry; replayed on cache hits
    # * dynamic: true if a dynamic block was evaluated while computing the
    #   entry; such entries must never be reused across edits
    #
    CacheEntry = Struct.new(
      :result, :advance, :read_end, :captures, :dynamic)

    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    # @param cache [Hash] packrat cache to use; leave empty to start with a
    #   fresh cache. Pass a cache carried over from a previous parse to reuse
    #   its entries (see Parslet::Session). 
    def initialize(reporter=Parslet::ErrorReporter::Tree.new, cache=nil)
      @cache = cache || Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new

      # Bookkeeping for cache entries and for Parslet::Session statistics. 
      @capture_frames = []
      @dynamic_count = 0
      reset_stats!
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
        @capture_frames.push(journal = [])
        # Read windows are an optional Source protocol (see
        # Parslet::Source#push_read_window); sources that do not implement
        # it simply get no read range tracking. 
        track_reads = source.respond_to?(:push_read_window)
        source.push_read_window(beg) if track_reads
        dynamic_before = @dynamic_count
        begin
          result = obj.try(source, self, consume_all)
        ensure
          read_end = track_reads ? source.pop_read_window : beg
          @capture_frames.pop
        end
    
        if obj.cached?
          set obj, beg, CacheEntry.new(
            result, 
            source.bytepos - beg, 
            read_end, 
            journal, 
            @dynamic_count != dynamic_before)
        end
        
        @misses += 1
        @first_miss_pos = beg if @first_miss_pos.nil? || beg < @first_miss_pos
        return result
      end

      @hits += 1

      # the condition in unless has returned true, so entry is not nil.
      # Replay the captures that were recorded when this entry was computed,
      # so that cache hits are indistinguishable from real parses. 
      entry.captures.each do |name, value|
        @captures[name] = value
      end

      # Account for the input range the cached computation read back then;
      # enclosing computations depend on it as well. 
      source.note_cached_read(entry.read_end) \
        if source.respond_to?(:note_cached_read)

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + entry.advance
      return entry.result
    end

    # Records a capture assignment made while parsing. The assignment is
    # journaled into all cache entries currently being computed, so that it
    # can be replayed on cache hits. @api private
    #
    def record_capture(name, value)
      @capture_frames.each do |frame|
        frame << [name, value]
      end
      nil
    end

    # Notes that a dynamic block was evaluated. Cache entries computed while
    # this counter advances are marked as dynamic and must not be reused
    # across edits. @api private
    #
    def note_dynamic
      @dynamic_count += 1
      nil
    end

    # Number of cache hits since the last #reset_stats!. @api private
    attr_reader :hits
    # Number of cache misses since the last #reset_stats!. @api private
    attr_reader :misses
    # Lowest position at which a cache miss occurred since the last
    # #reset_stats! (nil if there were none). @api private
    attr_reader :first_miss_pos

    # Resets the hit/miss statistics. @api private
    #
    def reset_stats!
      @hits = 0
      @misses = 0
      @first_miss_pos = nil
    end

    # Yields (position, atom object_id, CacheEntry) for every cache entry.
    # @api private
    #
    def each_cache_entry
      @cache.each do |pos, entries|
        entries.each do |object_id, entry|
          yield pos, object_id, entry
        end
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
