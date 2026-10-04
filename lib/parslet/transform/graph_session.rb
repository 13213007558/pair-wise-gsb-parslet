require 'delegate'

class Parslet::Transform
  # Raised in graph mode when transformation reaches a node that is still
  # being transformed (a back edge) and the winning rule for that node did
  # not declare <tt>recursive: true</tt>. The message contains the reference
  # chain that closes the cycle.
  #
  class CyclicReferenceError < StandardError; end

  # A controlled stand-in for the result of a node that is part of a cycle.
  # While the cycle's rule block is running, the ref transparently delegates
  # to the node's result once that result is known. A rule that needs to
  # build explicit cyclic data structures can call #resolve! with a value
  # of its choosing.
  #
  class RecursiveRef < SimpleDelegator
    def initialize
      @resolved = false
      super(nil)
    end

    # @return [Boolean] whether the reference has been resolved already
    def resolved?
      @resolved
    end

    # Explicitly points this reference at +value+.
    #
    # @return +value+
    def resolve!(value)
      if @resolved
        raise CyclicReferenceError,
          "recursive reference was already resolved"
      end
      @resolved = true
      __setobj__(value)
      value
    end

    # @api private
    #
    # Binds the reference to the result of its own node unless the rule
    # resolved it explicitly.
    def __bind_result__(result)
      resolve!(result) unless @resolved
    end
  end

  # @api private
  #
  # Performs one #apply call in graph mode. The session is throw-away:
  # every call to Parslet::Transform#apply creates a fresh instance, so the
  # node cache never leaks between calls and a failed transformation leaves
  # neither cached results nor mutated input behind.
  #
  class GraphSession
    # @object the original node
    # @ref    the controlled reference owned by this node (created when a
    #         descendant references the node before it is finished)
    # @edges  reference edges touching this node while it was on the stack;
    #         each edge is [parent, accessor, target]
    Node = Struct.new(:object, :ref, :edges)

    def initialize(transform)
      @transform = transform
      # Object identity -> transformed result. Keys are object ids so that
      # equal but distinct leafs (e.g. two copies of the same String) are not
      # collapsed, while one shared node is transformed exactly once.
      @results = {}
      # object id -> Node for frames currently on the traversal stack.
      @active = {}
    end

    def apply(object, context)
      result = visit(object, context)
      unwrap(result)
    end

    private

    def visit(object, context)
      id = object.object_id

      return @results[id] if @results.key?(id)

      frame = @active[id]
      if frame
        # Back edge: hand out the controlled reference for the in-progress
        # node. The caller records where the reference came from.
        frame.ref ||= RecursiveRef.new
        return frame.ref
      end

      frame = Node.new(object, nil, [])
      @active[id] = frame
      begin
        transformed_children = descend(object, context, frame)
        result = match_and_call(object, transformed_children, context, frame)
        @results[id] = result
        result
      ensure
        @active.delete(id)
      end
    end

    # Builds a fresh container with transformed children, recording the
    # accessor of every back edge on the target node's frame. The original
    # container is never modified.
    def descend(object, context, frame)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), new_hash|
          new_hash[key] = child_value(object, frame, key, value, context)
        end
      when Array
        object.each_with_index.map do |value, index|
          child_value(object, frame, index, value, context)
        end
      else
        object
      end
    end

    def child_value(parent, frame, accessor, value, context)
      child = visit(value, context)
      target_frame = @active[value.object_id]
      if child.is_a?(RecursiveRef) && target_frame
        record_back_edge(frame, target_frame, parent, accessor)
      end
      child
    end

    def record_back_edge(parent_frame, target_frame, parent, accessor)
      edge = [parent, accessor, target_frame.object]
      [parent_frame, target_frame].each do |frame|
        already = frame.edges.any? do |edge_parent, edge_accessor, edge_target|
          edge_parent.equal?(parent) &&
            edge_accessor == accessor &&
            edge_target.equal?(target_frame.object)
        end
        frame.edges << edge unless already
      end
    end

    def match_and_call(object, transformed_children, context, frame)
      matched = @transform.match_rule(transformed_children, context)

      if frame.edges.any?
        unless matched && matched[2][:recursive]
          raise CyclicReferenceError, cycle_message(frame, matched)
        end
      end

      unless matched
        return unmatched(transformed_children)
      end

      bindings, block, _options = matched
      result = @transform.call_on_match(bindings, block, frame.ref)

      bind_ref(frame, result, transformed_children)
      unwrap(result, frame)
    end

    def unmatched(element)
      if @transform.raise_on_unmatch? && element.is_a?(Hash)
        elt_types = element.map do |key, value|
          [key, value.class]
        end.to_h
        raise NotImplementedError, "Failed to match `#{elt_types.inspect}`"
      end
      element
    end

    def bind_ref(frame, result, transformed_children)
      return unless frame.ref

      if result.equal?(frame.ref)
        # Returning the node's own ref means "the node is the transformed
        # container itself", which may legitimately contain the ref.
        frame.ref.resolve!(transformed_children)
      else
        frame.ref.__bind_result__(result)
      end
    end

    # A rule that returns a recursive reference means "the node I am
    # building"; resolve to that node's result.
    def unwrap(result, frame=nil)
      if frame && result.is_a?(RecursiveRef) && result.resolved?
        return result.__getobj__ if frame&.ref&.equal?(result)
      end
      result
    end

    def cycle_message(frame, matched)
      chain = frame.edges.map do |from, accessor, to|
        "  #{node_label(from)}#{accessor_label(accessor)} -> #{node_label(to)}"
      end.join("\n")

      declaration = if matched
        "the matching rule did not declare recursive: true"
      else
        "no rule matched the cyclic node"
      end

      "cyclic reference reached while transforming #{node_label(frame.object)}; " \
        "#{declaration}. Reference chain:\n#{chain}\n" \
        "Declare a cycle-capable rule with `recursive: true` to build a " \
        "controlled reference."
    end

    def accessor_label(accessor)
      "[#{accessor.inspect}]"
    end

    def node_label(object)
      kind = object.is_a?(Hash) ? 'Hash' : object.is_a?(Array) ? 'Array' : object.class.name
      "#{kind}0x#{object.object_id.to_s(16)}"
    end
  end
end
