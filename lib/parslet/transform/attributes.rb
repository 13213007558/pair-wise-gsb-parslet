class Parslet::Transform
  # Base error for demand-driven attribute evaluation.
  class AttributeError < StandardError; end

  # Raised when requested attributes lead back to the same node and attribute.
  class AttributeCycle < AttributeError
    attr_reader :dependency_chain

    def initialize(dependency_chain)
      @dependency_chain = dependency_chain
      super("circular attribute dependency: #{message_chain}")
    end

    private

    def message_chain
      dependency_chain.map do |dependency|
        "#{dependency.node.path}.#{dependency.name}"
      end.join(" -> ")
    end
  end

  # Raised when no rule can supply a requested attribute at a node.
  class UnresolvedAttribute < AttributeError; end

  # One edge in a dependency chain: a positioned node and attribute name.
  class AttributeDependency < Struct.new(:node, :name)
    def ==(other)
      other.is_a?(self.class) &&
        other.node.equal?(node) &&
        other.name == name
    end

    alias eql? ==

    def hash
      [node.object_id, name].hash
    end
  end

  # A tree value with its position in one evaluation. The same raw value under
  # different parents gets different nodes and cache entries.
  class AttributeNode
    attr_reader :value, :parent, :key

    def initialize(value, parent, key, evaluation)
      @value = value
      @parent = parent
      @key = key
      @evaluation = evaluation
    end

    def root?
      @parent.nil?
    end

    def [](key)
      return nil unless navigable?
      return nil unless @value.key?(key) if @value.is_a?(Hash)
      return nil if @value.is_a?(Array) && !key.is_a?(Integer)
      return nil if @value.is_a?(Array) && (key < 0 || key >= @value.size)
      @evaluation.node_for(@value[key], self, key)
    end

    def children
      return [] unless @value.is_a?(Array)
      @value.each_index.map { |index| self[index] }
    end

    def attribute(name)
      @evaluation.attribute(self, name)
    end

    def path
      return "$" if root?

      if @key.is_a?(Integer)
        "#{@parent.path}[#{@key}]"
      else
        "#{@parent.path}.#{@key}"
      end
    end

    def inspect
      "#<Parslet::Transform::AttributeNode #{path}=#{@value.inspect}>"
    end

    def method_missing(name, *args)
      if args.empty? && @evaluation.attribute_defined?(name)
        attribute(name)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private=false)
      @evaluation.attribute_defined?(name) || super
    end

    private

    def navigable?
      @value.is_a?(Hash) || @value.is_a?(Array)
    end
  end

  # Executes one attribute rule and exposes node navigation and bindings.
  class AttributeContext
    attr_reader :node, :bindings

    def initialize(evaluation, node, bindings={})
      @evaluation = evaluation
      @node = node
      @bindings = bindings
    end

    def value
      @node.value
    end

    def node
      @node
    end

    def parent
      @node.parent
    end

    def root?
      @node.root?
    end

    def attribute(name, target=@node)
      @evaluation.attribute(target, name)
    end
    alias attr attribute

    def [](name)
      if @bindings.key?(name)
        @bindings[name]
      elsif @evaluation.attribute_defined?(name)
        attribute(name)
      elsif @evaluation.root_bindings.key?(name)
        @evaluation.root_bindings[name]
      end
    end

    def method_missing(name, *args)
      if args.empty? && @bindings.key?(name)
        return @bindings[name]
      end
      if args.empty? && @evaluation.attribute_defined?(name)
        return attribute(name)
      end
      if args.empty? && @evaluation.root_bindings.key?(name)
        return @evaluation.root_bindings[name]
      end

      super
    end

    def respond_to_missing?(name, include_private=false)
      @evaluation.attribute_defined?(name) ||
        @bindings.key?(name) ||
        @evaluation.root_bindings.key?(name) ||
        super
    end
  end

  # Lazily computes and caches attributes for exactly one tree evaluation.
  class AttributeEvaluation
    attr_reader :root_bindings

    def initialize(definitions, tree, root_bindings={})
      @definitions = definitions
      @root_bindings = root_bindings || {}
      @root = AttributeNode.new(tree, nil, nil, self)
      @nodes = {}
      @cache = Hash.new { |hash, key| hash[key] = {} }
      @stack = []
    end

    def root
      @root
    end

    def attribute(node, name)
      name = name.to_sym
      node_cache = @cache[node.object_id]
      return node_cache[name] if node_cache.key?(name)

      dependency = AttributeDependency.new(node, name)
      start = @stack.index(dependency)
      if start
        raise AttributeCycle.new(@stack[start..-1] + [dependency])
      end

      @stack.push(dependency)
      begin
        value = calculate(node, name)
      ensure
        @stack.pop
      end

      node_cache[name] = value
    end

    def [](name)
      attribute(@root, name)
    end

    def method_missing(name, *args)
      if args.empty? && attribute_defined?(name)
        return attribute(@root, name)
      end

      super
    end

    def respond_to_missing?(name, include_private=false)
      attribute_defined?(name) || super
    end

    def attribute_defined?(name)
      @definitions.attribute?(name.to_sym)
    end

    def definition(name)
      @definitions[name]
    end

    def node_for(value, parent, key)
      return nil if value.nil?
      @nodes[[parent.object_id, key]] ||=
        AttributeNode.new(value, parent, key, self)
    end

    private

    def calculate(node, name)
      definition = definition(name)
      raise UnresolvedAttribute,
        "undefined attribute #{name.inspect}" unless definition

      if node.root? && definition.root?
        root_value = definition.root
        context = AttributeContext.new(self, node)
        return root_value.respond_to?(:call) ?
          context.instance_exec(&root_value) : root_value
      end

      definition.rules.each do |pattern, block|
        bindings = pattern.match(node.value)
        next unless bindings

        context = AttributeContext.new(self, node, bindings)
        if block.arity == 1
          return block.call(context)
        else
          return context.instance_exec(&block)
        end
      end

      raise UnresolvedAttribute,
        "no rule computes #{name.inspect} at #{node.path}"
    end
  end

  # One inherited or synthesized attribute and its ordered matching rules.
  class AttributeDefinition
    attr_reader :kind, :name, :rules

    def initialize(kind, name, root=nil)
      @kind = kind
      @name = name
      @root = root
      @rules = []
    end

    def root?
      !@root.nil?
    end

    def root
      @root
    end

    def add_rule(pattern, block)
      @rules.unshift([Parslet::Pattern.new(pattern), block])
    end

    def add_existing_rule(pattern, block)
      @rules.unshift([pattern, block])
    end
  end

  # Rule collection DSL used inside an attribute declaration block.
  class AttributeRuleDSL
    def initialize(definition)
      @definition = definition
    end

    def on(pattern, &block)
      @definition.add_rule(pattern, block)
    end
    alias rule on
  end

  # Stores attribute declarations independently of an evaluation run.
  class AttributeDefinitions
    def initialize
      @definitions = {}
    end

    def define(kind, name, pattern=nil, root: nil, &block)
      definition = @definitions[name.to_sym] ||
        AttributeDefinition.new(kind, name.to_sym, root)
      if definition.kind != kind
        raise AttributeError,
          "cannot combine inherited and synthesized attribute #{name.inspect}"
      end
      @definitions[definition.name] = definition

      if pattern
        definition.add_rule(pattern, block)
      elsif block
        dsl = AttributeRuleDSL.new(definition)
        if block.arity == 1
          block.call(dsl)
        else
          dsl.instance_exec(&block)
        end
      end

      definition
    end

    def [](name)
      @definitions[name.to_sym]
    end

    def attribute?(name)
      @definitions.key?(name.to_sym)
    end

    def merge(other)
      result = duplicate
      other.instance_variable_get(:@definitions).each do |name, other_definition|
        current = result[name]
        unless current
          result.instance_variable_get(:@definitions)[name] = other_definition
          next
        end

        if current.kind != other_definition.kind
          raise AttributeError,
            "cannot combine inherited and synthesized attribute #{name.inspect}"
        end

        merged = AttributeDefinition.new(current.kind, name, current.root)
        (current.rules + other_definition.rules).each do |pattern, block|
          merged.add_existing_rule(pattern, block)
        end
        result.instance_variable_get(:@definitions)[name] = merged
      end
      result
    end

    def duplicate
      self.class.new.tap do |copy|
        @definitions.each do |name, definition|
          copy.instance_variable_get(:@definitions)[name] = definition
        end
      end
    end
  end

  module AttributeDSL
    # Declares an inherited attribute, optionally with a +root:+ value or rules.
    def inherited_attribute(name, pattern=nil, root: nil, &block)
      attribute_target.define(:inherited, name, pattern, root: root, &block)
    end
    alias inherited_attr inherited_attribute

    # Declares a synthesized attribute from a node and its descendants.
    def synthesized_attribute(name, pattern=nil, &block)
      attribute_target.define(:synthesized, name, pattern, &block)
    end
    alias synthesized_attr synthesized_attribute

    private

    def attribute_target
      if is_a?(Class)
        attribute_definitions
      else
        @instance_attribute_definitions ||= AttributeDefinitions.new
      end
    end
  end

  class << self
    include AttributeDSL

    def attribute_definitions
      @attribute_definitions ||= AttributeDefinitions.new
    end
  end

  include AttributeDSL

  def attribute_definitions
    self.class.attribute_definitions.merge(
      @instance_attribute_definitions ||= AttributeDefinitions.new
    )
  end

  # Returns a demand-driven attribute evaluation for +tree+.
  def attributes_for(tree, context=nil)
    AttributeEvaluation.new(attribute_definitions, tree, context)
  end
  alias evaluate attributes_for
end
