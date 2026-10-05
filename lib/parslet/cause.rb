module Parslet
  # Represents a cause why a parse did fail. A lot of these objects are
  # constructed - not all of the causes turn out to be failures for the whole
  # parse. 
  #
  class Cause
    def initialize(message, source, pos, children)
      @message, @source, @pos, @children, @context =
        message, source, pos, children, nil
      @committed_for = nil
    end
    
    # @return [String, Array] A string or an array of message pieces that 
    #   provide failure information. Use #to_s to get a formatted string.
    attr_reader :message
    
    # @return [Parslet::Source] Source that was parsed when this error 
    #   happend. Mainly used for line number information.
    attr_reader :source
    
    # Location of the error. 
    #
    # @return [Fixnum] Position where the error happened. (character offset)
    attr_reader :pos 
    attr_reader :committed_for
    
    # When this cause is part of a tree of error causes: child nodes for this
    # node. Very often carries the reasons for this cause. 
    #
    # @return [Array<Parslet::Cause>] A list of reasons for this cause. 
    def children
      @children ||= []
    end
    
    # Appends 'at line LINE char CHAR' to the string given. Use +pos+ to
    # override the position of the +source+. This method returns an object
    # that can be turned into a string using #to_s.
    #
    # @param source [Parslet::Source] source that was parsed when this error
    #   happened 
    # @param pos [Fixnum] position of error
    # @param str [String, Array<String>] message parts
    # @param children [Array<Parslet::Cause>] child nodes for this error tree
    # @return [Parslet::Cause] a new instance of {Parslet::Cause}
    #
    def self.format(source, pos, str, children=[])
      self.new(str, source, pos, children)
    end

    # Marks this cause tree as belonging to an ordered-choice commitment.
    def commit!(frame)
      @committed_for = frame
      children.each { |child| child.commit!(frame) }
      self
    end

    def clear_commitment!
      @committed_for = nil
      children.each { |child| child.clear_commitment! }
      self
    end

    # True when this tree contains a failure after an ordered-choice cut.
    def committed?
      !@committed_for.nil? || children.any? { |child| child.committed? }
    end

    def committed_for?(frame)
      @committed_for.equal?(frame) ||
        children.any? { |child| child.committed_for?(frame) }
    end

    # Returns the most advanced committed failure in this cause tree. This is
    # returned directly by an outer choice so the real failure position wins.
    def deepest_committed
      candidates = children.map { |child| child.deepest_committed }.compact
      candidates.push(self) if @committed_for
      candidates.max_by { |cause| cause.pos }
    end

    # Update error message to include context provided by label
    # Update all child causes too (the same context applies to all causes)
    def set_label(l)
      @context = " when parsing #{l}"
      children.each { |c| c.set_label(l) }
    end

    def to_s
      line, column = source.line_and_column(pos)
      # Allow message to be a list of objects. Join them here, since we now
      # really need it.
      Array(message).map { |o|
        o.respond_to?(:to_slice) ?
          o.str.inspect :
          o.to_s }.join + " at line #{line} char #{column}#{@context}."
    end
    
    # Signals to the outside that the parse has failed. Use this in
    # conjunction with .format for nice error messages. 
    #
    def raise(exception_klass=Parslet::ParseFailed)
      exception = exception_klass.new(self.to_s, self)
      Kernel.raise exception
    end

    # Returns an ascii tree representation of the causes of this node and its
    # children. 
    #
    def ascii_tree
      StringIO.new.tap { |io| 
        recursive_ascii_tree(self, io, [true]) }.
        string
    end

  private
    def recursive_ascii_tree(node, stream, curved)
      append_prefix(stream, curved)
      stream.puts node.to_s

      node.children.each do |child|
        last_child = (node.children.last == child)

        recursive_ascii_tree(child, stream, curved + [last_child])
      end
    end
    def append_prefix(stream, curved)
      return if curved.size < 2
      curved[1..-2].each do |c|
        stream.print c ? "   " : "|  "
      end
      stream.print curved.last ? "`- " : "|- "
    end
  end
end
