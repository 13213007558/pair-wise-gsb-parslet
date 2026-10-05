require 'parslet/transform'

# Evaluates declared attributes of a parse tree without replacing it.
# Attributes are calculated lazily when they are requested. Inherited
# attributes normally flow from a parent to its children; synthesized
# attributes normally flow back from children. Each tree occurrence has its
# own cached values, so equal subtrees reused under different parent
# environments do not share a result. Circular attribute requests raise
# Parslet::AttributeTransform::AttributeCycleError with the concrete chain.
#
#   class Checker < Parslet::AttributeTransform
#     inherited_attribute(:scope, subtree(:_)) do |d|
#       d.node.parent.inherited(:scope)
#     end
#
#     synthesized_attribute(:references, subtree(:_)) do |d|
#       d.node.children.map { |child| child.synthesized(:references) }
#     end
#   end
#
#   root = Checker.new.analyze(tree, :scope => {})
#   root.synthesized(:references)
#
class Parslet::AttributeTransform < Parslet::Transform
  class AttributeError < StandardError; end
  class UndefinedAttributeError < AttributeError; end
  class AttributeCycleError < AttributeError
    attr_reader :chain

    def initialize(message, chain)
      super(message)
      @chain = chain
    end
  end

  class << self
    def attribute_definitions
      @__attribute_definitions ||= []
    end

    def inherited(subclass)
      super
      subclass.instance_variable_set(:@__attribute_definitions,
        attribute_definitions.dup)
    end

    # Define an inherited attribute for the subtrees matched by +expression+.
    def inherited_attribute(name, expression=nil, &block)
      define_attribute(:inherited, name, expression, block)
    end

    # Define a synthesized attribute for the subtrees matched by +expression+.
    def synthesized_attribute(name, expression=nil, &block)
      define_attribute(:synthesized, name, expression, block)
    end

    private

    def define_attribute(kind, name, expression, block)
      unless expression || block
        raise ArgumentError, 'give a pattern or a block to define an attribute'
      end

      @__attribute_definitions ||= []
      if expression.is_a?(Proc)
        block = expression
        expression = nil
      end
      pattern = Parslet::Pattern.new(
        expression || Parslet.subtree(:_))
      @__attribute_definitions.unshift([kind, name, pattern, block])
    end
  end

  def initialize(*args, &block)
    @attribute_definitions = []
    super
  end

  # Define an inherited attribute on this transform instance.
  def inherited_attribute(name, expression=nil, &block)
    define_attribute(:inherited, name, expression, block)
  end

  # Define a synthesized attribute on this transform instance.
  def synthesized_attribute(name, expression=nil, &block)
    define_attribute(:synthesized, name, expression, block)
  end

  def attribute_definitions
    self.class.attribute_definitions.dup + @attribute_definitions
  end

  # Return the root occurrence. +root_attributes+ supplies initial inherited
  # values; +bindings+ is made available to all attribute blocks.
  def analyze(tree, root_attributes=nil, bindings=nil)
    Analyzer.new(self, tree, root_attributes || {}, bindings || {}).root
  end

  private

  def define_attribute(kind, name, expression, block)
    unless expression || block
      raise ArgumentError, 'give a pattern or a block to define an attribute'
    end

    if expression.is_a?(Proc)
      block = expression
      expression = nil
    end
    pattern = Parslet::Pattern.new(
      expression || Parslet.subtree(:_))
    @attribute_definitions.unshift([kind, name, pattern, block])
  end

  class Analyzer
    def initialize(transform, tree, root_attributes, bindings)
      @transform = transform
      @root_attributes = root_attributes
      @bindings = bindings
      @values = {}
      @states = Hash.new(:absent)
      @active = []
      @nodes = {}
      @root = make_node(tree, '$', nil)
    end

    attr_reader :root

    def attribute(node, kind, name)
      if node.root? && kind == :inherited && @root_attributes.key?(name)
        return @root_attributes[name]
      end

      definition = definition_for(node, kind, name)
      request = [node.object_id, kind, name]

      if @states[request] == :in_progress
        chain = cyclic_chain(node, kind, name)
        raise AttributeCycleError.new(
          "cyclic attribute dependency: #{chain.join(' -> ')}", chain)
      end

      return @values[request] if @states[request] == :finished

      @states[request] = :in_progress
      @active.push([node, kind, name])
      begin
        value = call_attribute(node, definition)
      rescue
        @states[request] = :absent
        raise
      ensure
        @active.delete([node, kind, name])
      end
      @states[request] = :finished
      @values[request] = value
    end

    private

    def make_node(value, path, parent, key=nil)
      if parent
        node_key = [parent.object_id, key]
        @nodes[node_key] ||= Node.new(value, path, parent, self)
      else
        @nodes[:root] ||= Node.new(value, path, parent, self)
      end
    end

    def definition_for(node, kind, name)
      attribute_definitions.each do |definition_kind, attribute_name, pattern, block|
        next unless definition_kind == kind && attribute_name == name
        bindings = pattern.match(node.raw, @bindings)
        return [pattern, block, bindings] if bindings
      end

      raise UndefinedAttributeError,
        "no #{kind} attribute `#{name}' is defined for #{node.path}"
    end

    def attribute_definitions
      @transform.attribute_definitions
    end

    def call_attribute(node, definition)
      _pattern, block, pattern_bindings = definition
      bindings = pattern_bindings.merge(
        :node => node,
        :analyzer => self,
        :transform => @transform)
      @bindings.each do |key, value|
        bindings[key] = value unless bindings.key?(key)
      end

      context = AttributeContext.new(bindings)
      return block.call(context) if block.arity == 1
      context.instance_eval(&block)
    end

    def cyclic_chain(node, kind, name)
      repeated = [node, kind, name]
      start = @active.index(repeated)
      chain = @active[start..-1].map do |active_node, active_kind, active_name|
        descriptor(active_node, active_kind, active_name)
      end
      chain.push(descriptor(node, kind, name))
    end

    def descriptor(node, kind, name)
      "#{name} (#{kind}) at #{node.path}"
    end

    class Node
      def initialize(raw, path, parent, analyzer)
        @raw = raw
        @path = path
        @parent = parent
        @analyzer = analyzer
      end

      attr_reader :raw
      attr_reader :path
      attr_reader :parent

      def root?
        @parent.nil?
      end

      def children
        @children ||= begin
          nodes = []
          each_child { |_key, child| nodes << child }
          nodes
        end
      end

      def [](key_or_index)
        exists = if @raw.is_a?(Hash)
          @raw.key?(key_or_index)
        elsif @raw.is_a?(Array)
          key_or_index.is_a?(Integer) && key_or_index >= 0 &&
            key_or_index < @raw.size
        else
          false
        end
        return nil unless exists

        @children_by_key ||= {}
        @children_by_key[key_or_index] ||=
          wrap_child(@raw[key_or_index], key_or_index)
      end

      def inherited(name)
        @analyzer.attribute(self, :inherited, name)
      end

      def synthesized(name)
        @analyzer.attribute(self, :synthesized, name)
      end

      def inspect
        "#<Parslet::AttributeTransform::Node #{path} #{raw.inspect}>"
      end

      private

      def each_child
        return unless @raw.is_a?(Hash) || @raw.is_a?(Array)

        if @raw.is_a?(Array)
          @raw.each_with_index do |child, index|
            yield(index, wrap_child(child, index))
          end
        else
          @raw.each do |key, child|
            yield(key, wrap_child(child, key))
          end
        end
      end

      def wrap_child(child, key_or_index)
        child_path = if @raw.is_a?(Array)
          "#{@path}[#{key_or_index}]"
        else
          "#{@path}.#{key_or_index}"
        end
        @analyzer.send(:make_node, child, child_path, self, key_or_index)
      end
    end

    class AttributeContext < Parslet::Context
      def initialize(bindings)
        @__bindings = bindings
        super
      end

      def method_missing(name, *args, &block)
        if args.empty? && block.nil? && @__bindings.key?(name)
          @__bindings[name]
        else
          super
        end
      end

      def respond_to_missing?(name, include_private=false)
        @__bindings.key?(name) || super
      end

      def [](key)
        @__bindings[key]
      end

      def key?(key)
        @__bindings.key?(key)
      end

      def fetch(*args, &block)
        @__bindings.fetch(*args, &block)
      end

      def to_h
        @__bindings.dup
      end

      def inherited(name)
        @__bindings[:node].inherited(name)
      end

      def synthesized(name)
        @__bindings[:node].synthesized(name)
      end
    end
  end
end
