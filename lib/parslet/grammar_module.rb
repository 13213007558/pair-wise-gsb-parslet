# A parameterized, reusable grammar fragment with formal parameters and
# explicit instance boundaries. Subclass this to define a grammar module
# once and instantiate it several times inside the same parser, each time
# with different parameter bindings - without copying parser classes and
# renaming methods.
#
# Example:
#
#   class SeparatedList < Parslet::GrammarModule
#     param :element                    # formal grammar parameter
#     param :separator, default: -> { str(',') }
#
#     rule(:list) { element >> (separator >> element).repeat }
#
#     export :list                     # only exported names are visible
#   end                                #   to parent grammars
#
#   class MyParser < Parslet::Parser
#     rule(:integer) { match['0-9'].repeat(1) }
#     rule(:word)    { match['a-z'].repeat(1) }
#
#     rule(:top) {
#       int_list  = SeparatedList.new(:int_list,  element: integer)
#       word_list = SeparatedList.new(:word_list, element: word,
#                                     separator: str(';'))
#
#       int_list.export(:list) >> str(' ') >> word_list.export(:list)
#     }
#     root(:top)
#   end
#
#   MyParser.new.parse('1,2,3 a;b;c')
#
# Instance boundaries:
#
# * Rules inside the module resolve against the module instance, so
#   recursive references and helper rules never collide with rules of the
#   parent grammar or of sibling instances - even when they share names.
# * Captures (and the dynamic rules reading them) are confined to an
#   isolated capture scope per instance use: an instance can neither see
#   nor modify the captures of its parent grammar.
# * Only rules declared with +export+ can be referenced from the parent
#   grammar, via #export on the instance.
# * Error output qualifies rule names with the instance path, e.g.
#   INT_LIST.LIST, keeping the original rule name readable while showing
#   which instance failed.
#
class Parslet::GrammarModule
  include Parslet

  class << self
    # Declares a formal grammar parameter. Inside rule definitions, the
    # parameter name is available as a method returning the bound parslet
    # atom (or other value).
    #
    #   param :element                          # required parameter
    #   param :separator, default: -> { str(',') }
    #
    # A default that responds to #call is evaluated in the instance, so it
    # may use the full parslet DSL.
    #
    def param(name, opts={})
      param_specs[name.to_sym] = opts

      define_method(name) do
        resolve_param(name.to_sym)
      end
      private name
    end

    # Defines a rule of the module, just like Parslet::ClassMethods#rule,
    # but scoped to the module instance: the method is private, so rules
    # can only be referenced from inside the module. Parent grammars must
    # go through an explicitly exported name (see .export and #export).
    #
    def rule(name, opts={}, &definition)
      undef_method name if method_defined?(name) || \
        private_method_defined?(name)
      own_rule_names << name.to_sym

      define_method(name) do
        @rules ||= {}     # <name, rule> memoization, per instance
        return @rules[name] if @rules.has_key?(name)

        # Capture the self of the module instance along with the
        # definition.
        definition_closure = proc {
          self.instance_eval(&definition)
        }

        entity = Parslet::Atoms::Entity.new(
          name, opts[:label], &definition_closure)
        entity.path = instance_path
        @rules[name] = entity
      end
      private name
    end

    # Declares which rules are visible to parent grammars. Only exported
    # names can be obtained through #export on an instance.
    #
    def export(*names)
      own_exports.concat(names.map(&:to_sym))
    end

    # All exported rule names, including the ones inherited from a
    # superclass.
    #
    def exports
      inherited = superclass.respond_to?(:exports) ? superclass.exports : []
      (inherited + own_exports).uniq
    end

    # All rule names defined in this module and its superclasses.
    #
    def rule_names
      inherited = \
        superclass.respond_to?(:rule_names) ? superclass.rule_names : []
      inherited + own_rule_names
    end

    # All declared parameter names, including inherited ones.
    #
    def param_names
      inherited = \
        superclass.respond_to?(:param_names) ? superclass.param_names : []
      inherited + param_specs.keys
    end

    # @api private
    def param_spec(name)
      return param_specs[name] if param_specs.has_key?(name)
      if superclass.respond_to?(:param_spec)
        superclass.param_spec(name)
      end
    end

    private

    def param_specs
      @param_specs ||= {}
    end

    def own_exports
      @own_exports ||= []
    end

    def own_rule_names
      @rule_names ||= []
    end
  end

  # Name of this instance, as given to ::new. Defaults to the class name.
  #
  attr_reader :instance_name

  # Dotted path of this instance, e.g. +outer.inner+ for an instance
  # created inside another module instance (passing parent:). Used to
  # qualify rule names in error output.
  #
  attr_reader :instance_path

  # Creates an instance of the module, binding its formal grammar
  # parameters.
  #
  #   SeparatedList.new(:int_list, element: integer, separator: str(','))
  #
  # @param name [Symbol, String] optional instance name, used to build the
  #   instance path that appears in error messages
  # @param opts [Hash] parameter bindings; :parent may name an enclosing
  #   module instance to compose nested instance paths
  #
  def initialize(*args)
    opts = args.last.is_a?(Hash) ? args.pop.dup : {}
    name = args.shift

    parent = opts.delete(:parent)

    unknown = opts.keys.map(&:to_sym) - self.class.param_names
    unless unknown.empty?
      raise ArgumentError, \
        "Unknown grammar parameter(s) #{unknown.inspect} for #{self.class}."
    end

    @params = {}
    opts.each { |key, value| @params[key.to_sym] = value }

    @instance_name = (name || self.class.name || 'anonymous').to_s
    @instance_path = parent ? \
      [parent.instance_path, @instance_name].join('.') : @instance_name
  end

  # Returns the exported rule +name+ of this instance as a parslet atom
  # that can be embedded into a parent grammar. The returned atom carries
  # the instance boundary: it parses inside an isolated capture scope and
  # reports errors under the qualified name +instance.rule+.
  #
  # Raises ArgumentError if +name+ has not been declared via .export.
  #
  def export(name)
    name = name.to_sym

    unless self.class.exports.include?(name)
      if self.class.rule_names.include?(name)
        raise ArgumentError, \
          "#{self.class}: rule #{name.inspect} is internal to instance " \
          "#{instance_path}; declare 'export #{name}' in #{self.class} " \
          "to make it available to parent grammars."
      else
        raise ArgumentError, \
          "#{self.class}: no such rule #{name.inspect}."
      end
    end

    Parslet::Atoms::InstanceBoundary.new(
      send(name), [instance_path, name].join('.'))
  end

  private

  def resolve_param(name)
    return @params[name] if @params.has_key?(name)

    spec = self.class.param_spec(name)
    if spec && spec.has_key?(:default)
      default = spec[:default]
      return default.respond_to?(:call) ? instance_exec(&default) : default
    end

    raise ArgumentError, \
      "Grammar parameter #{name.inspect} of #{self.class} (instance " \
      "#{instance_path}) is not bound."
  end
end
