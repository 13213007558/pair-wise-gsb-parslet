# @api private
#
# Drives one {Parslet::Transform#apply} call in explicit graph mode.
#
# The session keeps two identity-keyed maps over the *original* graph:
#
# +@in_progress+ maps a node on the depth-first stack to the single,
# shared Parslet::Transform::Reference that stands for its not-yet-finished
# result. Every back edge to that node receives that very same Reference,
# so two parents closing the same cycle see the same controlled reference.
#
# +@finished+ maps a fully transformed node to its result. Every parent of
# a shared node therefore receives the very same result object.
#
# A Reference placed into a Hash/Array result is resolved to its target
# (the finished result) before #apply returns. A Reference placed into an
# object the rule itself constructs is left intact and dereferenced
# explicitly through Reference#target, since the engine does not know how
# to rebuild arbitrary user objects.
#
# Both maps live and die with a single #apply call, so ordinary tree mode
# pays none of this bookkeeping cost and a failed transformation cannot
# leak state into a later call. Nothing here mutates the input graph.
#
class Parslet::Transform::GraphSession
  Reference = Parslet::Transform::Reference

  def initialize(transform, context)
    @transform = transform
    @context = context
    # object_id => Reference (created lazily on the first back edge)
    @in_progress = {}
    @finished = {}      # object_id => transformed result
  end

  def call(obj)
    result = visit(obj, [])
    resolve(result, {})
  end

  private

  # Depth-first, post-order visit of a single original node.
  #
  # +chain+ is the list of original container nodes above this one, from
  # the entry node down to the immediate parent.
  #
  def visit(node, chain)
    return node unless container?(node)

    if @finished.key?(node.object_id)
      return @finished[node.object_id]
    end

    if @in_progress.key?(node.object_id)
      # Back edge. All back edges to this node share one Reference; the
      # chain records the path that closes the cycle, repeated node first.
      return @in_progress[node.object_id] ||= begin
        start = chain.index { |parent| parent.equal?(node) }
        reference_chain = chain[start..-1] + [node]
        Reference.new(node, reference_chain)
      end
    end

    @in_progress[node.object_id] = nil
    begin
      transformed_children = transform_children(node, chain + [node])
      present_refs = collect_refs(transformed_children)
      result = @transform.transform_elt(
        transformed_children, @context, present_refs)
    ensure
      reference = @in_progress.delete(node.object_id)
    end

    # Point every back edge's stand-in at the finished result.
    reference.bind(result) if reference
    @finished[node.object_id] = result
  end

  def transform_children(node, chain)
    case node
    when Hash
      node.each_with_object({}) do |(key, value), new_hash|
        new_hash[key] = visit(value, chain)
      end
    when Array
      node.map { |element| visit(element, chain) }
    end
  end

  # Gathers the forward references introduced while transforming the direct
  # children of a node. A reference hidden inside an already transformed
  # child belongs to that child's own cycle decision, not this node's.
  #
  def collect_refs(node)
    values = case node
    when Hash then node.values
    when Array then node
    else return []
    end
    values.grep(Reference)
  end

  # Replaces every Reference reachable from the root result with the
  # finished result of its target node. Only Hash and Array results are
  # traversed; arbitrary rule objects keep their Reference for explicit
  # dereferencing. Containers reached more than once are processed once.
  #
  def resolve(node, seen)
    if node.is_a?(Reference)
      return resolve(node.target, seen)
    end
    return node unless node.is_a?(Hash) || node.is_a?(Array)
    return node if seen.key?(node.object_id)

    seen[node.object_id] = true
    case node
    when Hash
      node.each do |key, value|
        node[key] = resolve(value, seen)
      end
    when Array
      node.map! { |element| resolve(element, seen) }
    end
    node
  end

  def container?(node)
    node.is_a?(Hash) || node.is_a?(Array)
  end
end
