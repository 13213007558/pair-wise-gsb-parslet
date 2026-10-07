
module Parslet
  module CFG
    class UnsupportedGrammar < StandardError; end

    EmptyLoopMarker = Struct.new(:symbol, :start, :finish) do
      def to_s
        "empty loop in #{symbol.name.inspect} at #{start}"
      end
    end

    class Packed
      attr_reader :production, :children

      def initialize(production, children, empty_loop=false)
        @production = production
        @children = children
        @empty_loop = empty_loop
        @meta = {}
      end

      def empty_loop?
        @empty_loop
      end

      attr_reader :meta

      def ==(other)
        other.is_a?(Packed) &&
          production == other.production &&
          children == other.children &&
          empty_loop? == other.empty_loop?
      end
      alias eql? ==

      def hash
        [production, children, empty_loop?].hash
      end
    end

    Prefix = Struct.new(:values)

    class TerminalNode
      attr_reader :symbol, :start, :finish, :value

      def initialize(symbol, start, finish, value)
        @symbol = symbol
        @start = start
        @finish = finish
        @value = value
      end

      def alternatives
        []
      end

      def empty_loop?
        false
      end
    end

    class SymbolNode
      attr_reader :symbol, :start, :finish, :alternatives

      def initialize(symbol, start, finish)
        @symbol = symbol
        @start = start
        @finish = finish
        @alternatives = []
      end

      def empty_loop?
        @alternatives.any?(&:empty_loop?)
      end
    end

    class IntermediateNode
      attr_reader :production, :dot, :start, :finish, :alternatives

      def initialize(production, dot, start, finish)
        @production = production
        @dot = dot
        @start = start
        @finish = finish
        @alternatives = []
      end

      def symbol
        production.lhs
      end

      def empty_loop?
        @alternatives.any?(&:empty_loop?)
      end
    end

    class Forest
      attr_reader :root

      def initialize(root, nodes, empty_loops, recognizer=nil, root_symbol=nil, required_finish=nil)
        @root = root
        @nodes = nodes
        @empty_loops = empty_loops
        @recognizer = recognizer
        @root_symbol = root_symbol
        @required_finish = required_finish
      end

      def success?
        !resolved_root.nil?
      end

      def ambiguous?
        @nodes.any? { |node| node.respond_to?(:alternatives) && node.alternatives.size > 1 }
      end

      def empty_loop?
        !@empty_loops.empty?
      end

      attr_reader :empty_loops

      def root
        resolved_root || @root
      end

      def propagate_empty_loops
        propagated = {}
        changed = true
        while changed
          changed = false
          @nodes.each do |node|
            next unless node.respond_to?(:alternatives)
            next unless node.is_a?(SymbolNode)

            node.alternatives.each do |family|
              next if family.empty_loop?
              next if propagated[family]
              next unless family.children.any? do |child|
                child.respond_to?(:empty_loop?) && child.empty_loop?
              end

              propagated[family] = true
              node.alternatives << Packed.new(family.production, family.children, true)
              @empty_loops << EmptyLoopMarker.new(node.symbol, node.start, node.finish)
              changed = true
            end
          end
        end
      end

      def node_count
        @nodes.size
      end

      def alternatives(node=@root)
        node.alternatives
      end

      def value(&selector)
        Evaluator.new(self).value(&selector)
      end

      def raw_value(&selector)
        Evaluator.new(self, true).value(&selector)
      end

      class Evaluator
        include Parslet::Atoms::CanFlatten

        def initialize(forest, raw=false)
          @forest = forest
          @raw = raw
          @values = {}
          @choices = {}
          @active = {}
          @finite = calculate_finite_nodes
        end

        def value(&selector)
          @selector = selector
          raw = evaluate(@forest.root)
          return raw if raw.is_a?(EmptyLoopMarker)
          return raw if @raw
          return flatten_tagged(raw) if tagged?(raw)
          raw
        end

        def tagged?(value)
          value.is_a?(Array) && [:sequence, :maybe, :repetition].include?(value.first)
        end

        private

        def calculate_finite_nodes
          finite = {}
          changed = true
          while changed
            changed = false
            @forest.all_nodes.each do |node|
              next unless node.respond_to?(:alternatives)
              next if finite[node]

              if node.alternatives.any? { |family| finite_family?(family, finite) }
                finite[node] = true
                changed = true
              end
            end
          end
          finite
        end

        def finite_family?(family, finite)
          return false if family.empty_loop?
          family.children.all? do |child|
            child.is_a?(TerminalNode) || finite[child]
          end
        end

        def choose(node)
          return @choices[node] if @choices.has_key?(node)

          families = node.alternatives
          family = if @selector
            @selector.call(families, node)
          else
            families.find { |candidate| @finite[node] && finite_choice?(candidate) } || families.first
          end

          unless families.include?(family)
            raise ArgumentError, "Selector returned an alternative that does not belong to the forest."
          end

          @choices[node] = family
        end

        def finite_choice?(family)
          !family.empty_loop? && family.children.all? do |child|
            child.is_a?(TerminalNode) || @finite[child]
          end
        end

        def evaluate(node)
          return @values[node] if @values.has_key?(node)
          return EmptyLoopMarker.new(node.symbol, node.start, node.finish) if @active[node]

          @active[node] = true
          begin
            value = evaluate_node(node)
            @values[node] = value unless recursive_value?(value)
            value
          ensure
            @active.delete(node)
          end
        end

        def recursive_value?(value)
          value.is_a?(EmptyLoopMarker)
        end

        def evaluate_node(node)
          return node.value if node.is_a?(TerminalNode)

          family = choose(node)
          if family.empty_loop?
            return EmptyLoopMarker.new(node.symbol, node.start, node.finish)
          end

          return Prefix.new(family.children.map { |child| evaluate(child) }) if node.is_a?(IntermediateNode)

          values = family.children.map { |child| evaluate(child) }
          build_symbol(node, family, values)
        end

        def build_symbol(node, family, values)
          symbol = node.symbol
          atom = symbol.atom

          if atom.nil?
            return family.meta[:transparent] ? values.first : unwrap_transparent(values.first)
          elsif atom.is_a?(Parslet::Atoms::Repetition)
            return build_repetition(atom, family, values)
          elsif atom.is_a?(Parslet::Atoms::Sequence)
            return [:sequence, *expand_sequence_values(values, family)]
          elsif atom.is_a?(Parslet::Atoms::Named)
            child = values.first
            child = flatten_tagged(child, true) if tagged?(child)
            return { atom.name => child }
          elsif atom.is_a?(Parslet::Atoms::Ignored)
            return nil
          else
            return values.first
          end
        end

        def build_repetition(atom, family, values)
          return [atom.tag] if family.production.rhs.empty?

          dot = family.meta[:dot] || family.production.rhs.size
          if dot == 1
            child = values.first.is_a?(Prefix) ? values.first.values.first : values.first
            tail = nil
          else
            child = values.first.is_a?(Prefix) ? values.first.values.first : first_prefix_value(values.first)
            tail = unwrap_prefix(values.last)
          end
          result = [atom.tag]
          if tail.nil?
            result << child
          elsif tail.is_a?(Array) && tail.first == atom.tag
            result << child
            result.concat(tail[1..-1])
          else
            result << tail
            result << child
          end
          result
        end

        def flatten_tagged(value, named=false)
          tag, *tail = value
          result = tail.map { |element| tagged?(element) ? flatten_tagged(element) : element }
          return flatten_repetition(result, named) if tag == :repetition
          return result.first || '' if tag == :maybe
          flatten_sequence(result)
        end

        def expand_sequence_values(values, family)
          result = []
          values.each do |value|
            if value.is_a?(Prefix) && family.meta[:transparent]
              value.values.each { |part| result << unwrap_sequence_prefix(part) }
            elsif value.is_a?(Prefix)
              value.values.each do |part|
                part = unwrap_sequence_prefix(part)
                result << part
              end
            else
              result << value
            end
          end
          result
        end

        def unwrap_sequence_prefix(value)
          return value unless value.is_a?(Prefix)
          return value.values.first if value.values.size == 1
          value.values
        end

        def unwrap_prefix(value)
          value.is_a?(Prefix) ? value.values : value
        end

        def first_prefix_value(value)
          value.is_a?(Prefix) ? value.values.first : value
        end

        def unwrap_transparent(value)
          value.is_a?(Prefix) ? value.values.first : value
        end
      end

      def all_nodes
        @nodes
      end

      private

      def resolved_root
        return @resolved_root if defined?(@resolved_root)

        @resolved_root = @root
        if @resolved_root.nil? && @recognizer
          candidates = @nodes.select do |node|
            node.is_a?(SymbolNode) && node.symbol == @root_symbol && node.start.zero?
          end
          candidates = candidates.select { |node| !node.alternatives.empty? }
          candidates = candidates.select { |node| node.finish == @required_finish } unless @required_finish.nil?
          finish = candidates.map(&:finish).max
          @resolved_root = @recognizer.root_node(@root_symbol, finish) if finish
        end
        @resolved_root
      end
    end
  end
end
