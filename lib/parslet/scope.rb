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

    # Returns a detached copy of this binding and all its parents. Storing
    # values into either chain doesn't affect the other.
    #
    def snapshot
      copy = self.class.new(parent && parent.snapshot)
      @hash.each { |k, v| copy[k] = v }
      copy
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

  # Returns a detached copy of the current scope chain. Pass the result to
  # #restore to roll the scope back to the state it had when the snapshot
  # was taken.
  #
  def snapshot
    @current.snapshot
  end

  # Restores a snapshot previously taken with #snapshot, discarding all
  # captures made since.
  #
  def restore(snapshot)
    @current = snapshot
  end
end
