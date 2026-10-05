# A parameterizable grammar module. A grammar module bundles a set of rules
# behind a formal parameter list (#param) and an explicit interface
# (#export). It can be instantiated any number of times inside a parser (or
# inside another grammar module), each time binding the formal parameters
# to different atoms of the host grammar -- without copying the module or
# renaming any of its rules.
#
# Example:
#
#   class SeparatedList < Parslet::GrammarModule
#     param :element
#     param :separator
#
#     rule(:list) { element >> (separator >> element).repeat }
#
#     export :list
#   end
#
#   class MyParser < Parslet::Parser
#     rule(:integer) { match['0-9'].repeat(1) }
#     rule(:word)    { match['a-z'].repeat(1) }
#
#     instance(:int_list,  SeparatedList,
#       :element => :integer, :separator => proc { str(',') })
#     instance(:word_list, SeparatedList,
#       :element => :word,    :separator => proc { str(';') })
#
#     rule(:top) { int_list >> str(' ') >> word_list }
#     root(:top)
#   end
#
#   MyParser.new.parse('1,2,3 a;b;c')
#
# == Instance boundaries
#
# Each instance is a hard boundary for everything that is not explicitly
# exported:
#
# * Recursive references between the module's rules always resolve to the
#   rules of the same instance, even when several instances of the same
#   module (using the exact same internal rule names) coexist in one
#   parser.
# * Captures made inside an instance are stored in an isolated capture
#   scope: they are invisible to the parent grammar and are discarded when
#   the instance's rule finishes. Likewise, captures of the parent grammar
#   are not visible inside the instance. Dynamic rules (Parslet.dynamic)
#   inside the module therefore only ever see the instance's own bindings.
# * Only the names listed in #export are accessible from the outside;
#   internal helper rules cannot be called through the instance boundary.
#
# == Error messages
#
# Rules of an instance are named '<instance>.<rule>' (printed as
# 'INT_LIST.LIST') in error messages and in #inspect output, so a failure
# always shows both the original, readable rule name and the path of the
# instance it failed in.
#
# == Parameter bindings
#
# Bindings passed to .instantiate (or to the #instance DSL) may be:
#
# * a Symbol, resolved lazily as a rule (or method) of the host grammar,
# * a Proc, evaluated (lazily) in the context of the host grammar instance,
# * any parslet atom, used as is.
#
# Parameters declared without a default must be bound at instantiation
# time; parameters with a default (param :name, :default => ...) may be
# omitted. A Proc default is evaluated in the context of the module
# instance itself.
#
class Parslet::GrammarModule
  include Parslet

  # Path of this instance, e.g. 'int_list' or 'outer.inner' when modules
  # are nested. Used to qualify rule names in error messages.
  #
  attr_reader :instance_path

  def initialize(instance_path=nil, bindings={}, resolver=nil)
    @instance_path = instance_path
    @bindings = bindings
    @resolver = resolver
    @resolved_bindings = {}
  end

  class << self
    # Declares a formal grammar parameter. Inside the module's rules, the
    # parameter is called like a rule and yields the atom it is bound to in
    # each instance.
    #
    #   param :element
    #   param :separator, :default => proc { str(',') }
    #
    def param(name, opts={})
      name = name.to_sym
      params[name] = opts

      define_method(name) do
        resolve_param(name)
      end
    end

    # Declares the module's interface. Only exported rules are accessible
    # through the instance boundary; the first exported rule doubles as the
    # default entry point used when the instance itself is chained into a
    # parent rule.
    #
    def export(*names)
      names.each do |name|
        name = name.to_sym
        exports << name unless exports.include?(name)
      end
    end

    # Defines an internal rule of the module. Works like Parslet.rule, but
    # qualifies the rule name with the instance path at instantiation time,
    # so that error messages keep both the original rule name and the
    # instance it belongs to.
    #
    def rule(name, opts={}, &definition)
      undef_method name if method_defined? name
      define_method(name) do
        @rules ||= {}     # <name, rule> memoization, per module instance
        return @rules[name] if @rules.has_key?(name)

        # Capture the self of the module instance along with the definition.
        definition_closure = proc {
          self.instance_eval(&definition)
        }

        @rules[name] = Parslet::Atoms::Entity.new(
          qualified_rule_name(name), opts[:label], &definition_closure)
      end
    end

    # Instantiates the module, binding its formal parameters. Returns the
    # instance boundary (an atom) that the host grammar can chain into its
    # rules. You normally use the #instance DSL of Parslet::Parser instead
    # of calling this directly.
    #
    def instantiate(bindings={}, opts={})
      bindings = bindings.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      validate_bindings!(bindings)

      path = opts[:path] || name
      Boundary.new(new(path, bindings, opts[:resolver]))
    end

    def params
      @params ||= {}
    end

    def exports
      @exports ||= []
    end

    def default_export
      exports.first
    end

    def inherited(subclass) # :nodoc:
      super
      subclass.instance_variable_set(:@params, params.dup)
      subclass.instance_variable_set(:@exports, exports.dup)
    end

  private
    def validate_bindings!(bindings)
      unknown = bindings.keys - params.keys
      unless unknown.empty?
        raise ArgumentError,
          "Unknown grammar parameter(s) #{unknown.map(&:inspect).join(', ')} " +
          "for #{self}; declared parameters are " +
          "#{params.keys.map(&:inspect).join(', ')}."
      end

      missing = params.keys.reject { |name|
        bindings.has_key?(name) || params[name].has_key?(:default) }
      unless missing.empty?
        raise ArgumentError,
          "Missing grammar parameter(s) #{missing.map(&:inspect).join(', ')} " +
          "for #{self}."
      end

      if exports.empty?
        raise ArgumentError,
          "#{self} doesn't export anything; use 'export :rule_name' to " +
          "declare its interface."
      end

      undefined = exports.reject { |name| method_defined?(name) }
      unless undefined.empty?
        raise ArgumentError,
          "#{self} exports undefined rule(s) " +
          "#{undefined.map(&:inspect).join(', ')}."
      end
    end
  end

  # Resolves the formal parameter +name+ to the atom it is bound to in this
  # instance. Called by the methods that .param defines.
  #
  def resolve_param(name)
    return @resolved_bindings[name] if @resolved_bindings.has_key?(name)
    @resolved_bindings[name] = resolve_binding(name)
  end

private

  def qualified_rule_name(name)
    return name unless @instance_path
    :"#{@instance_path}.#{name}"
  end

  def resolve_binding(name)
    if @bindings.has_key?(name)
      return resolve_bound_value(@bindings[name], name)
    end

    opts = self.class.params[name]
    if opts && opts.has_key?(:default)
      default = opts[:default]
      return default.is_a?(Proc) ? instance_exec(&default) : default
    end

    raise ArgumentError,
      "Grammar parameter #{name.inspect} is not bound in instance " +
      "'#{@instance_path}' of #{self.class}."
  end

  def resolve_bound_value(value, name)
    case value
    when Symbol
      unless @resolver && @resolver.respond_to?(value)
        raise ArgumentError,
          "Cannot resolve grammar parameter #{name.inspect} => " +
          "#{value.inspect}: the host grammar doesn't respond to it."
      end
      @resolver.send(value)
    when Proc
      # Evaluate the binding in the context of the host grammar instance if
      # there is one, otherwise in the context of this module instance.
      @resolver ? @resolver.instance_exec(&value) : instance_exec(&value)
    else
      value
    end
  end

  # The instance boundary: this is what the host grammar gets to see of a
  # grammar module instance. It is an atom (parses via the module's default
  # export) and gives access to the exported rules -- and nothing else.
  #
  class Boundary < Parslet::Atoms::Base
    def initialize(grammar_instance)
      super()

      @grammar_instance = grammar_instance
      @exported_rules = {}
    end

    def try(source, context, consume_all)
      exported_rule(default_export).apply(source, context, consume_all)
    end

    def to_s_inner(prec)
      @grammar_instance.instance_path.to_s.upcase
    end

    # Transparent for visitors (export, graphviz, accelerator).
    def accept(visitor)
      exported_rule(default_export).accept(visitor)
    end

    # Gives access to the exported rules of the module instance. Internal
    # rules are not reachable through the boundary.
    #
    def method_missing(name, *args, &block)
      if args.empty? && block.nil? && exported?(name)
        return exported_rule(name)
      end
      super
    end

    def respond_to_missing?(name, include_private=false)
      exported?(name) || super
    end

  private
    def default_export
      @grammar_instance.class.default_export
    end

    def exported?(name)
      @grammar_instance.class.exports.include?(name)
    end

    def exported_rule(name)
      @exported_rules[name] ||= ExportedRule.new(@grammar_instance.send(name))
    end
  end

  # Wraps one exported rule of a module instance. Applies the rule inside
  # an isolated capture scope, so that captures and dynamic rules of the
  # instance only see their own bindings.
  #
  class ExportedRule < Parslet::Atoms::Base
    def initialize(entity)
      super()

      @entity = entity
    end

    def try(source, context, consume_all)
      context.isolate do
        @entity.apply(source, context, consume_all)
      end
    end

    def to_s_inner(prec)
      @entity.to_s(prec)
    end

    # Transparent for visitors (export, graphviz, accelerator).
    def accept(visitor)
      @entity.accept(visitor)
    end
  end
end

module Parslet
  module ClassMethods
    # Instantiates a Parslet::GrammarModule, binding its formal parameters.
    # Defines a method of the given name that returns the instance boundary
    # (memoized per parser instance), ready to be chained into rules.
    #
    #   instance(:int_list, SeparatedList,
    #     :element => :integer,            # Symbol: rule of this grammar
    #     :separator => proc { str(',') }) # Proc: evaluated in this grammar
    #
    def instance(name, module_class, bindings={})
      undef_method name if method_defined? name
      define_method(name) do
        @grammar_instances ||= {}
        return @grammar_instances[name] if @grammar_instances.has_key?(name)

        # Compose the instance path when nesting modules inside modules.
        path = if respond_to?(:instance_path) && instance_path
          "#{instance_path}.#{name}"
        else
          name.to_s
        end

        @grammar_instances[name] = module_class.instantiate(bindings,
          :resolver => self, :path => path)
      end
    end
  end
end
