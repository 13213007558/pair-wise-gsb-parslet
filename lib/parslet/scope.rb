class Parslet::Scope
  # Raised when the accessed slot has never been assigned a value. 
  #
  class NotFound < StandardError
  end
  
  class Binding
    attr_reader :parent
    
    def initialize(parent=nil)
      @parent = parent
      @hash = Hash.new
    end
    
    def [](k)
      @hash.has_key?(k) && @hash[k] ||
        parent && parent[k] or 
        raise NotFound
    end
    def []=(k,v)
      @hash.store(k,v)
    end

    # Returns a copy of the assignments stored in this frame. Part of the
    # snapshot/restore mechanism, see Parslet::Scope#snapshot.
    #
    def snapshot
      @hash.dup
    end

    # Replaces the assignments in this frame with a snapshot taken earlier.
    #
    def restore(snapshot)
      @hash = snapshot
    end
  end
  
  def [](k)
    @current[k]
  end
  def []=(k,v)
    @current[k] = v
  end
  
  def initialize
    @current = Binding.new
  end
  
  def push
    @current = Binding.new(@current)
  end
  def pop
    @current = @current.parent
  end

  # Returns an opaque snapshot of the current state of this scope. The
  # snapshot can later be passed to #restore to bring the scope back to
  # exactly this state, even if captures have been made or frames have been
  # pushed and popped in the meantime. This is used when a parse is
  # re-evaluated at the same input position (left recursion support), where
  # each candidate evaluation must start from a clean, identical state.
  #
  def snapshot
    frames = []
    binding = @current
    while binding
      frames << [binding, binding.snapshot]
      binding = binding.parent
    end
    frames
  end

  # Restores a state previously captured with #snapshot.
  #
  def restore(frames)
    frames.each do |binding, snapshot|
      binding.restore(snapshot)
    end
    @current = frames.first.first
  end
end
