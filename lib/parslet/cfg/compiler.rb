
module Parslet
  module CFG
    class Compiler
      Symbol = Struct.new(:id, :kind, :atom, :index) do
        def terminal?
          kind == :terminal
        end

        def name
          atom.respond_to?(:inspect) ? atom.inspect : id.to_s
        end
      end

      Production = Struct.new(:id, :lhs, :rhs, :step) do
        def step?
          step == true
        end
      end

      attr_reader :symbols, :productions, :productions_by_symbol

      def initialize
        @symbols = []
        @productions = []
        @productions_by_symbol = Hash.new { |hash, key| hash[key] = [] }
        @compiled = {}
        @terminal_symbols = {}
        @repetition_symbols = {}
      end

      def compile(root, input_length=nil)
        @input_length = input_length
        start = nonterminal(nil)
        child = compile_atom(root)
        add_production(start, [child], false)

        calculate_nullable_and_empty_loops
        start
      end

      def looping_nonterminal?(symbol)
        @looping.include?(symbol)
      end

      private

      def compile_atom(atom)
        return @compiled[atom.object_id] if @compiled.has_key?(atom.object_id)

        symbol = case atom
        when Parslet::Atoms::Entity
          compile_entity(atom)
        when Parslet::Atoms::Alternative
          compile_alternative(atom)
        when Parslet::Atoms::Sequence
          compile_sequence(atom)
        when Parslet::Atoms::Repetition
          compile_repetition(atom, 0)
        when Parslet::Atoms::Named, Parslet::Atoms::Ignored
          compile_wrapper(atom)
        when Parslet::Atoms::Str
          compile_string(atom)
        when Parslet::Atoms::Re
          terminal(atom)
        when Parslet::Parser
          compile_atom(atom.root)
        else
          raise UnsupportedGrammar,
            "#{atom.class} is not a side-effect free CFG atom."
        end

        @compiled[atom.object_id] = symbol
        symbol
      end

      def compile_entity(entity)
        symbol = nonterminal(entity)
        @compiled[entity.object_id] = symbol
        definition = compile_atom(entity.parslet)
        add_production(symbol, [definition], false)
        symbol
      end

      def compile_alternative(atom)
        symbol = nonterminal(atom)
        atom.alternatives.each do |alternative|
          add_production(symbol, [compile_atom(alternative)], false)
        end
        symbol
      end

      def compile_sequence(atom)
        symbol = nonterminal(atom)
        rhs = atom.parslets.map { |child| compile_atom(child) }
        add_production(symbol, rhs, false)
        symbol
      end

      def compile_wrapper(atom)
        symbol = nonterminal(atom)
        add_production(symbol, [compile_atom(atom.parslet)], false)
        symbol
      end

      def compile_string(atom)
        if atom.str.empty?
          symbol = nonterminal(atom)
          add_production(symbol, [], false)
          return symbol
        end

        terminal(atom)
      end

      def compile_repetition(atom, count)
        key = [atom.object_id, count]
        return @repetition_symbols[key] if @repetition_symbols.has_key?(key)

        symbol = nonterminal(atom, count)
        @repetition_symbols[key] = symbol
        child = compile_atom(atom.parslet)

        build_repetition_chain(atom, child) if count.zero?

        symbol
      end

      def build_repetition_chain(atom, child)
        if atom.max.nil?
          build_unbounded_repetition_chain(atom, child)
        else
          build_bounded_repetition_chain(atom, child)
        end
      end

      def repetition_symbol(atom, count)
        @repetition_symbols[[atom.object_id, count]]
      end

      def build_unbounded_repetition_chain(atom, child)
        cap = if atom.min.zero?
          0
        elsif @input_length
          [atom.min, @input_length].min
        else
          atom.min
        end

        (1..cap).each do |count|
          @repetition_symbols[[atom.object_id, count]] ||= nonterminal(atom, count)
        end

        (0..cap).each do |count|
          symbol = repetition_symbol(atom, count)
          add_production(symbol, [], false) if count >= atom.min

          if count < atom.min && count < cap
            add_production(symbol, [child, repetition_symbol(atom, count + 1)], true)
          else
            add_production(symbol, [child, symbol], true)
          end
        end
      end

      def build_bounded_repetition_chain(atom, child)
        (1..atom.max).each do |count|
          @repetition_symbols[[atom.object_id, count]] ||= nonterminal(atom, count)
        end

        (0..atom.max).each do |count|
          symbol = repetition_symbol(atom, count)
          add_production(symbol, [], false) if count >= atom.min

          if count < atom.max
            add_production(symbol, [child, repetition_symbol(atom, count + 1)], true)
          end
        end
      end

      def nonterminal(atom, index=nil)
        symbol = Symbol.new(@symbols.size, :nonterminal, atom, index)
        @symbols << symbol
        symbol
      end

      def terminal(atom)
        return @terminal_symbols[atom.object_id] if @terminal_symbols.has_key?(atom.object_id)

        symbol = Symbol.new(@symbols.size, :terminal, atom, nil)
        @symbols << symbol
        @terminal_symbols[atom.object_id] = symbol
      end

      def add_production(lhs, rhs, step)
        production = Production.new(@productions.size, lhs, rhs, step)
        @productions << production
        @productions_by_symbol[lhs.id] << production
        production
      end

      def calculate_nullable_and_empty_loops
        nullable = {}
        changed = true

        while changed
          changed = false
          @productions.each do |production|
            next if nullable[production.lhs]
            if production.rhs.all? { |symbol| !symbol.terminal? && nullable[symbol] }
              nullable[production.lhs] = true
              changed = true
            end
          end
        end

        edges = Hash.new { |hash, key| hash[key] = [] }
        @productions.each do |production|
          next unless nullable[production.lhs]
          next unless production.rhs.all? { |symbol| !symbol.terminal? && nullable[symbol] }

          production.rhs.each { |symbol| edges[production.lhs.id] << symbol.id }
        end

        @looping = strongly_connected(edges).map do |id|
          @symbols[id]
        end
      end

      def strongly_connected(edges)
        index = 0
        indices = {}
        stack = []
        low = {}
        result = []
        on_stack = {}

        @symbols.each do |symbol|
          next unless symbol.kind == :nonterminal
          id = symbol.id
          next if indices.has_key?(id)

          work = [[id, 0]]

          until work.empty?
            current, edge_index = work.last

            unless indices.has_key?(current)
              indices[current] = low[current] = index
              index += 1
              stack.push(current)
              on_stack[current] = true
            end

            target = edges[current][edge_index]

            if target
              work.last[1] += 1
              if !indices.has_key?(target)
                work.push([target, 0])
              elsif on_stack[target]
                low[current] = [low[current], indices[target]].min
              end
            else
              work.pop
              if work.any?
                parent = work.last.first
                low[parent] = [low[parent], low[current]].min
              end

              next unless low[current] == indices[current]

              component = []
              loop do
                member = stack.pop
                on_stack[member] = false
                component << member
                break if member == current
              end

              cyclic = component.size > 1 || edges[current].include?(current)
              result.concat(component) if cyclic
            end
          end
        end

        result
      end
    end
  end
end
