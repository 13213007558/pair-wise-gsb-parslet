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
  end
  
  def [](k)
    @current[k]
  end
  def []=(k,v)
    @current[k] = v
  end
  
  def initialize
    @current = Binding.new
    @stack = []
  end
  
  def push
    @stack.push(@current)
    @current = Binding.new(@current)
  end

  # Pushes a scope that is detached from the current one: lookups inside the
  # new scope will NOT fall back to bindings made outside of it. Used to
  # isolate grammar module instances from their surrounding grammar.
  #
  def push_isolated
    @stack.push(@current)
    @current = Binding.new
  end

  def pop
    @current = @stack.pop
  end
end
