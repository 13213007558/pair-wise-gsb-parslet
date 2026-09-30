module Parslet::Atoms
  # Helper class that implements a transient packrat cache. Regular parses use
  # it within a single parse; Parslet::Session retains entries that have no
  # dynamic dependency and restores the subset unaffected by an edit.
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable.
  #
  class Context
    Entry = Struct.new(
      :object_id,
      :start,
      :read_end,
      :miss_start,
      :miss_end,
      :result,
      :advance,
      :tainted,
      :eof,
      :dependencies,
      keyword_init: true
    )

    # @param reporter [#err, #err_at] Error reporter (leave empty for default
    #   reporter)
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @frames = []
      @hits = 0
      @misses = 0
      @hit_objects = []
      @miss_objects = []
      @reparsed_start = nil
      @reparsed_end = nil
      @hit_positions = []
    end

    # Caches a parse answer for obj at source.pos. Applying the same parslet
    # at one position of input always yields the same result, unless the input
    # has changed.
    #
    # The cache stores the maximal source interval examined while producing an
    # answer, not only the interval consumed by success. Failed alternatives
    # and lookahead therefore invalidate entries when an edit changes text
    # those branches inspected.
    def try_with_cache(obj, source, consume_all)
      beg = source.bytepos

      entry = obj.cached? ? lookup(obj, beg) : nil
      unless entry
        frame = push_frame(obj, beg)
        begin
          frame[:result] = obj.try(source, self, consume_all)
          frame[:consumed_end] = source.bytepos
          remember(obj, frame)
        ensure
          pop_frame(frame)
        end

        return frame[:result]
      end

      use_entry(entry, source)
    end

    def parslet_read(beg, ending, eof=false)
      return if @frames.empty?

      frame = @frames.last
      frame[:read_end] = ending if ending > frame[:read_end]
      frame[:eof] = true if eof
      frame[:miss_start] = beg if frame[:miss_start].nil? || beg < frame[:miss_start]
      frame[:miss_end] = ending if ending > frame[:miss_end]
    end

    def dynamic!
      @frames.each { |frame| frame[:tainted] = true }
    end

    def completed_entries
      @cache.values.flat_map(&:values).reject(&:tainted)
    end

    def restore_entries(entries, source, old_ending, suffix_offset)
      entries.each do |entry|
        offset = entry.start >= old_ending ? suffix_offset : 0
        mapped = map_entry(entry, source, offset)
        next unless mapped

        @cache[mapped.start][mapped.object_id] = mapped
      end
    end

    def cache_stats
      {
        hits: @hits,
        misses: @misses,
        hit_objects: @hit_objects,
        miss_objects: @miss_objects,
        reparsed_start: @reparsed_start,
        reparsed_end: @reparsed_end,
        hit_positions: @hit_positions
      }
    end

    # Report an error at a given position.
    # @see ErrorReporter
    def err_at(*args)
      return [false, @reporter.err_at(*args)] if @reporter
      return [false, nil]
    end

    # Report an error.
    # @see ErrorReporter
    def err(*args)
      return [false, @reporter.err(*args)] if @reporter
      return [false, nil]
    end

    # Report a successful parse.
    # @see ErrorReporter::Contextual
    def succ(*args)
      return [true, @reporter.succ(*args)] if @reporter
      return [true, nil]
    end

    # Returns the current captures made on the input (see
    # Parslet::Atoms::Base#capture). Use as follows:
    #
    #   context.captures[:foobar] # => returns capture :foobar
    attr_reader :captures

    # Starts a new scope. Use the #scope method of Parslet::Atoms::DSL
    # to call this.
    def scope
      captures.push
      yield
    ensure
      captures.pop
    end

    private

    def push_frame(obj, beg)
      @misses += 1
      @miss_objects << obj.object_id
      frame = {
        object: obj,
        object_id: obj.object_id,
        start: beg,
        read_end: beg,
        miss_start: nil,
        miss_end: beg,
        consumed_end: beg,
        tainted: tainted_frame?,
        eof: false,
        dependencies: []
      }
      @frames.push(frame)
      frame
    end

    def pop_frame(frame)
      return unless @frames.last.equal?(frame)

      parent = @frames[-2]
      @frames.pop
      if frame[:miss_start] && (@reparsed_start.nil? || frame[:miss_start] < @reparsed_start)
        @reparsed_start = frame[:miss_start]
      end
      if frame[:miss_end] && (@reparsed_end.nil? || frame[:miss_end] > @reparsed_end)
        @reparsed_end = frame[:miss_end]
      end
      if parent && frame[:miss_start]
        parent[:miss_start] = frame[:miss_start] if parent[:miss_start].nil? || frame[:miss_start] < parent[:miss_start]
        parent[:miss_end] = [parent[:miss_end], frame[:miss_end]].max
      end
      propagate_taint(frame)
    end

    def propagate_taint(frame)
      return unless frame[:tainted]
      return if @frames.empty?

      @frames.last[:tainted] = true
    end

    def tainted_frame?
      @frames.any? { |frame| frame[:tainted] }
    end

    def remember(obj, frame)
      success, _ = frame[:result]
      advance = success ? frame[:consumed_end] - frame[:start] : 0
      return unless obj.cached?

      entry = Entry.new(
        object_id: obj.object_id,
        start: frame[:start],
        read_end: frame[:read_end],
        miss_start: frame[:miss_start],
        miss_end: frame[:miss_end],
        result: frame[:result],
        advance: advance,
        tainted: frame[:tainted],
        eof: frame[:eof],
        dependencies: frame[:dependencies].to_a.dup
      )
      @cache[frame[:start]][cache_key(obj.object_id)] = entry
      parent_frame = @frames.last.equal?(frame) ? @frames[-2] : @frames.last
      attach_dependency(parent_frame, entry) if parent_frame
    end

    def lookup(obj, pos)
      @cache[pos][cache_key(obj.object_id)]
    end

    def cache_key(object_id)
      object_id
    end

    def use_entry(entry, source)
      @hits += 1
      @hit_objects << entry.object_id
      @hit_positions << entry.start

      propagate_hit(entry)
      source.bytepos = entry.start + entry.advance
      entry.result
    end

    def propagate_hit(entry)
      return if @frames.empty?

      frame = @frames.last
      frame[:read_end] = entry.read_end if entry.read_end > frame[:read_end]
      frame[:tainted] = true if entry.tainted
      frame[:eof] = true if entry.eof
      attach_dependency(frame, entry)
    end

    def map_entry(entry, source, position_offset)
      start = entry.start + position_offset
      return unless start >= 0

      Entry.new(
        object_id: entry.object_id,
        start: start,
        read_end: entry.read_end + position_offset,
        miss_start: entry.miss_start.nil? ? nil : entry.miss_start + position_offset,
        miss_end: entry.miss_end.nil? ? nil : entry.miss_end + position_offset,
        result: remap_value(entry.result, source, position_offset),
        advance: entry.advance,
        tainted: entry.tainted,
        eof: entry.eof,
        dependencies: []
      )
    end

    def attach_dependency(frame, entry)
      return unless frame.key?(:dependencies)
      return if frame[:dependencies].any? do |dependency|
        dependency.object_id == entry.object_id &&
          dependency.start == entry.start
      end

      frame[:dependencies] << entry
    end

    def remap_value(value, source, position_offset)
      case value
      when Parslet::Slice
        remap_slice(value, source, position_offset)
      when Parslet::Cause
        value.remap(source, position_offset) do |item|
          remap_value(item, source, position_offset)
        end
      when Parslet::Position
        Parslet::Position.new(source.string, value.bytepos + position_offset)
      when Array
        value.map { |item| remap_value(item, source, position_offset) }
      when Hash
        value.each_with_object({}) do |(key, item), mapped|
          mapped[key] = remap_value(item, source, position_offset)
        end
      else
        value
      end
    end

    def remap_slice(slice, source, position_offset)
      bytepos = slice.position.bytepos + position_offset
      Parslet::Slice.new(
        Parslet::Position.new(source.string, bytepos),
        slice.str,
        source.line_cache
      )
    end
  end
end
