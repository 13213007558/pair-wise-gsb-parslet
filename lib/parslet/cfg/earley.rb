
module Parslet
  module CFG
    class Earley
      Item = Struct.new(:production, :dot, :start)

      def initialize(compiler, input, source=nil)
        @compiler = compiler
        @input = input
        @source = source || Parslet::Source.new(input)
        @length = input.length
        @charts = Array.new(@length + 1) { [] }
        @items = Array.new(@length + 1) { {} }
        @waiters = Array.new(@length + 1) { Hash.new { |hash, key| hash[key] = [] } }
        @symbol_nodes = Array.new(@length + 1) { {} }
        @intermediate_nodes = Array.new(@length + 1) { {} }
        @terminal_nodes = {}
        @nodes = []
        @empty_loops = []
      end

      def parse(root_symbol, consume_all=true)
        @compiler.productions_by_symbol[root_symbol.id].each do |production|
          add_item(0, production, 0, 0)
        end

        process(0)
        scan(0)

        (1..@length).each do |position|
          process(position)
          scan(position) unless position == @length
        end

        mark_empty_loops
        forest = Forest.new(nil, @nodes, @empty_loops, self, root_symbol, consume_all ? @length : nil)
        forest.propagate_empty_loops
        forest
      end

      def root_node(root_symbol, finish)
        @symbol_nodes[finish][[root_symbol.id, 0, finish]]
      end

      private

      def process(position)
        queue = @charts[position].dup

        until queue.empty?
          item = queue.shift

          if finished?(item)
            completed_node = symbol_node(item.production.lhs, item.start, position)
            if item.production.rhs.empty?
              add_family(completed_node, Packed.new(item.production, [], false))
            end
            complete(position, item, completed_node, queue)
            next
          end

          symbol = item.production.rhs[item.dot]
          register_waiter(position, item)

          if symbol.terminal?
            next
          end

          @compiler.productions_by_symbol[symbol.id].each do |production|
            predicted = add_item(position, production, 0, position)
            queue << predicted if predicted
          end
        end
      end

      def complete(position, item, completed_node, queue)
        completed_symbol = item.production.lhs

        @waiters[item.start][completed_symbol.id].each do |waiter|
          create_family(position, waiter, item.start, completed_node)
          new_item = add_item(position, waiter.production, waiter.dot + 1, waiter.start)
          queue << new_item if new_item
        end
      end

      def register_waiter(position, item)
        symbol = item.production.rhs[item.dot]
        waiters = @waiters[position][symbol.id]
        waiters << item unless waiters.include?(item)
      end

      def create_family(position, waiter, child_start, child_node)
        old_dot = waiter.dot
        new_dot = old_dot + 1
        if old_dot == 0 && new_dot == waiter.production.rhs.size && waiter.production.lhs.atom.nil?
          node = symbol_node(waiter.production.lhs, waiter.start, position)
          family = Packed.new(waiter.production, [child_node], false)
          family.meta[:dot] = new_dot
          family.meta[:transparent] = true
          add_family(node, family)
          return node
        end

        children = if old_dot == 0
          [child_node]
        else
          [intermediate_node(waiter.production, old_dot, waiter.start, child_start), child_node]
        end

        node = if new_dot == waiter.production.rhs.size
          symbol_node(waiter.production.lhs, waiter.start, position)
        else
          intermediate_node(waiter.production, new_dot, waiter.start, position)
        end
          family = Packed.new(waiter.production, children, false)
          family.meta[:dot] = new_dot
          add_family(node, family)
      end

      def scan(position)
        @waiters[position].each do |symbol_id, waiters|
          symbol = @compiler.symbols[symbol_id]
          next unless symbol.terminal?

          node = terminal_node(symbol, position)
          next unless node

          finish = node.finish
          waiters.each do |waiter|
            create_family(finish, waiter, position, node)
            add_item(finish, waiter.production, waiter.dot + 1, waiter.start)
          end
        end
      end

      def terminal_node(symbol, start)
        key = [symbol.id, start]
        return @terminal_nodes[key] if @terminal_nodes.has_key?(key)

        value = read_terminal(symbol.atom, start)
        return nil unless value

        node = TerminalNode.new(symbol, start, start + value.length, value)
        @terminal_nodes[key] = node
        @nodes << node
        node
      end

      def read_terminal(atom, start)
        @source.bytepos = byte_position(start)
        if atom.is_a?(Parslet::Atoms::Str)
          return nil unless @source.matches?(Regexp.new(Regexp.escape(atom.str)))
          @source.consume(atom.str.size)
        elsif @source.matches?(atom.re)
          @source.consume(1)
        end
      end

      def byte_position(char_position)
        @input.byteslice(0, char_position).bytesize
      end

      def add_item(position, production, dot, start)
        item = Item.new(production, dot, start)
        key = [production.id, dot, start]
        return nil if @items[position].has_key?(key)

        @items[position][key] = item
        @charts[position] << item

        if dot == 0
          node = intermediate_node(production, 0, start, position)
          family = Packed.new(production, [], false)
          family.meta[:dot] = 0
          add_family(node, family)
        end

        item
      end

      def finished?(item)
        item.dot == item.production.rhs.size
      end

      def add_family(node, family)
        return false if node.alternatives.include?(family)
        node.alternatives << family
        true
      end

      def symbol_node(symbol, start, finish)
        key = [symbol.id, start, finish]
        return @symbol_nodes[finish][key] if @symbol_nodes[finish].has_key?(key)

        node = SymbolNode.new(symbol, start, finish)
        @symbol_nodes[finish][key] = node
        @nodes << node

        node
      end

      def intermediate_node(production, dot, start, finish)
        key = [production.id, dot, start]
        return @intermediate_nodes[finish][key] if @intermediate_nodes[finish].has_key?(key)

        node = IntermediateNode.new(production, dot, start, finish)
        @intermediate_nodes[finish][key] = node
        @nodes << node
        node
      end

      def mark_empty_loops
        @symbol_nodes.each do |nodes_at_finish|
          nodes_at_finish.each_value do |node|
            next unless node.start == node.finish
            next unless @compiler.looping_nonterminal?(node.symbol)

            node.alternatives << Packed.new(nil, [], true) unless node.alternatives.any?(&:empty_loop?)
            @empty_loops << EmptyLoopMarker.new(node.symbol, node.start, node.finish)
          end
        end
      end
    end
  end
end
