require 'spec_helper'

require 'parslet'

describe Parslet::Transform do
  include Parslet
  
  let(:transform) { Parslet::Transform.new }
  
  class A < Struct.new(:elt); end
  class B < Struct.new(:elt); end
  class C < Struct.new(:elt); end
  class Bi < Struct.new(:a, :b); end

  describe "delayed construction" do
    context "given simple(:x) => A.new(x)" do
      before(:each) do
        transform.rule(simple(:x)) { |d| A.new(d[:x]) }
      end

      it "should transform 'a' into A.new('a')" do
        transform.apply('a').should == A.new('a')
      end 
      it "should transform ['a', 'b'] into [A.new('a'), A.new('b')]" do
        transform.apply(['a', 'b']).should == 
          [A.new('a'), A.new('b')]
      end
    end
    context "given rules on {:a => simple(:x)} and {:b => :_x}" do
      before(:each) do
        transform.rule(:a => simple(:x)) { |d| A.new(d[:x]) }
        transform.rule(:b => simple(:x)) { |d| B.new(d[:x]) }
      end

      it "should transform {:d=>{:b=>'c'}} into d => B('c')" do
        transform.apply({:d=>{:b=>'c'}}).should == {:d => B.new('c')}
      end
      it "should transform {:a=>{:b=>'c'}} into A(B('c'))" do
        transform.apply({:a=>{:b=>'c'}}).should == A.new(B.new('c'))
      end
    end
    describe "pulling out subbranches" do
      before(:each) do
        transform.rule(:a => {:b => simple(:x)}, :d => {:e => simple(:y)}) { |d|
          Bi.new(*d.values_at(:x, :y))
        }
      end

      it "should yield Bi.new('c', 'f')" do
        transform.apply(:a => {:b => 'c'}, :d => {:e => 'f'}).should ==
          Bi.new('c', 'f')
      end 
    end
  end
  describe "dsl construction" do
    let(:transform) { Parslet::Transform.new do
        rule(simple(:x)) { A.new(x) }
      end 
    }
    
    it "should still evaluate rules correctly" do
      transform.apply('a').should == A.new('a')
    end 
  end
  describe "class construction" do
    class OptimusPrime < Parslet::Transform 
      rule(:a => simple(:x)) { A.new(x) }
      rule(:b => simple(:x)) { B.new(x) }
    end
    let(:transform) { OptimusPrime.new }
    
    it "should evaluate rules" do
      transform.apply(:a => 'a').should == A.new('a')
    end

    context "optionally raise when no match found" do
      class BumbleBee < Parslet::Transform
        def initialize(&block)
          super(raise_on_unmatch: true, &block)
        end
        rule(:a => simple(:x)) { A.new(x) }
      end
      let(:transform) { BumbleBee.new }

      it "should evaluate rules" do
        transform.apply(:a => 'a').should == A.new('a')
      end

      it "should raise when no rules are matched" do
        lambda {
          transform.apply(:z => 'z')
        }.should raise_error(NotImplementedError, /Failed to match/)
      end
    end

    context "with inheritance" do
      class OptimusPrimeJunior < OptimusPrime
        rule(:b => simple(:x)) { B.new(x.upcase) }
        rule(:c => simple(:x)) { C.new(x) }
      end
      let(:transform) { OptimusPrimeJunior.new }

      it "should inherit rules from its parent" do
        transform.apply(:a => 'a').should == A.new('a')
      end

      it "should be able to override rules from its parent" do
        transform.apply(:b => 'b').should == B.new('B')
      end

      it "should be able to define new rules" do
        transform.apply(:c => 'c').should == C.new('c')
      end
    end
  end
  describe "<- #call_on_match" do
    let(:bindings) { { :foo => 'test' } }
    context "when given a block of arity 1" do
      it "should call the block" do
        called = false
        transform.call_on_match(bindings, lambda do |dict|
          called = true
        end)
        
        called.should == true
      end 
      it "should yield the bindings" do
        transform.call_on_match(bindings, lambda do |dict|
          dict.should == bindings
        end)
      end
      it "should execute in the current context"  do
        foo = 'test'
        transform.call_on_match(bindings, lambda do |dict|
          foo.should == 'test'
        end)
      end
    end
    context "when given a block of arity 0" do
      it "should call the block" do
        called = false
        transform.call_on_match(bindings, proc do 
          called = true
        end)
        
        called.should == true
      end 
      it "should have bindings as local variables" do
        transform.call_on_match(bindings, proc do
          foo.should == 'test'
        end)
      end
      it "should execute in its own context" do
        @bar = 'test'
        transform.call_on_match(bindings, proc do
          if instance_variable_defined?("@bar")
            instance_variable_get("@bar").should_not == 'test'
          end
        end)
      end
    end
  end
  
  context "various transformations (regression)" do
    context "hashes" do
      it "are matched completely" do
        transform.rule(:a => simple(:x)) { fail }
        transform.apply(:a => 'a', :b => 'b')
      end 
    end
  end
  
  context "when not using the bindings as hash, but as local variables" do
    it "should access the variables" do
      transform.rule(simple(:x)) { A.new(x) }
      transform.apply('a').should == A.new('a')
    end
    it "should allow context as local variable" do
      transform.rule(simple(:x)) { foo }
      transform.apply('a', :foo => 'bar').should == 'bar'
    end
  end

  describe "composable rewriting" do
    def fold_rule(transform)
      transform.rule([:add, simple(:left), simple(:right)]) do |bindings|
        bindings[:left] + bindings[:right]
      end
    end

    let(:fold) do
      transform = Parslet::Transform.new(traversal: :root)
      fold_rule(transform)
      transform
    end

    let(:postorder_fold) do
      transform = Parslet::Transform.new
      fold_rule(transform)
      transform
    end

    let(:identity) { Parslet::Transform.identity }

    it "distinguishes no match from successful but equal rewriting" do
      fold.try_apply(:unrelated).should be_no_match

      echo = Parslet::Transform.new(traversal: :root) do
        rule(simple(:value)) { |bindings| bindings[:value] }
      end
      result = echo.try_apply(1)
      result.should be_unchanged
      result.should be_success
      result.value.should == 1
    end

    it "folds constants in the existing post-order traversal" do
      input = [:add, [:add, 1, 2], 3]
      result = postorder_fold.try_apply(input)
      result.should be_changed
      result.value.should == 6
    end

    it "keeps no match and equal success distinct during post-order traversal" do
      postorder_fold.try_apply(:unrelated).should be_no_match

      echo = Parslet::Transform.new do
        rule(simple(:value)) { |bindings| bindings[:value] }
      end
      result = echo.try_apply([1, 2])
      result.should be_unchanged
      result.value.should == [1, 2]
    end

    it "sequences strategies and rolls back when a later strategy does not match" do
      input = [:add, 1, 2]
      requires_z = Parslet::Transform.new(traversal: :root) do
        rule(:z => simple(:value)) { value }
      end
      result = fold.compose(requires_z).try_apply(input)
      result.should be_no_match
      result.value.should equal(input)
    end

    it "reports genuine exceptions instead of treating them as no match" do
      failure = Parslet::Transform.new(traversal: :root) do
        rule(:boom) { raise "boom" }
      end
      result = failure.try_apply(:boom)
      result.should be_error
      result.exception.should be_a(RuntimeError)
      result.value.should == :boom
      expect { failure.apply(:boom) }.to raise_error(RuntimeError, "boom")
    end

    it "does not expose a partially rewritten child when a later child fails" do
      increment = Parslet::Transform.new(traversal: :root) do
        rule(simple(:value)) { |bindings| bindings[:value] + 1 }
      end
      input = [1, "not a number"]
      result = increment.all_children.try_apply(input)
      result.should be_error
      result.value.should equal(input)
      input.should == [1, "not a number"]
    end

    it "keeps the input tree intact when a matching rule mutates bindings and fails" do
      failure = Parslet::Transform.new(traversal: :root) do
        rule(:a => simple(:value)) do |bindings|
          bindings[:mutated] = true
          raise "boom"
        end
      end
      input = { :a => 1 }
      result = failure.try_apply(input)
      result.should be_error
      result.value.should equal(input)
      input.should == { :a => 1 }
    end

    it "tries strategies in order and uses the first success" do
      echo = Parslet::Transform.new(traversal: :root) do
        rule(simple(:value)) { |bindings| bindings[:value] }
      end

      fallback = Parslet::Transform.first_success(fold, echo)
      result = fallback.try_apply(:unrelated)
      result.should be_unchanged
      result.value.should == :unrelated
      fallback.try_apply([:add, 1, 2]).value.should == 3
    end

    it "does not fall through after a genuine exception" do
      failure = Parslet::Transform.new(traversal: :root) do
        rule(:boom) { raise "boom" }
      end
      result = Parslet::Transform.first_success(failure, identity).try_apply(:boom)
      result.should be_error
      result.exception.message.should == "boom"
    end

    it "changes only the first child that a strategy matches" do
      increment = Parslet::Transform.new(traversal: :root) do
        rule(simple(:value)) { |bindings| bindings[:value] + 1 }
      end
      input = [1, "ignored", 2]
      result = increment.one_child.try_apply(input)
      result.should be_changed
      result.value.should == [2, "ignored", 2]
      input.should == [1, "ignored", 2]
    end

    it "changes only the first matching hash child" do
      increment = Parslet::Transform.new(traversal: :root) do
        rule(simple(:value)) { |bindings| bindings[:value] + 1 }
      end
      input = { :left => 1, :right => 2 }
      result = increment.one_child.try_apply(input)
      result.should be_changed
      result.value.should == { :left => 2, :right => 2 }
      input.should == { :left => 1, :right => 2 }
    end

    it "changes every child when all children match" do
      rewrite = Parslet::Transform.new(traversal: :root) do
        rule(1) { 10 }
        rule(2) { 20 }
      end
      result = rewrite.all_children.try_apply([1, 2])
      result.should be_changed
      result.value.should == [10, 20]
    end

    it "returns unchanged success when all children match equally" do
      result = identity.all_children.try_apply([1, 2])
      result.should be_unchanged
      result.value.should == [1, 2]
    end

    it "repeats an explicit bottom-up fold until it is stable" do
      child_rewrite = Parslet::Transform.all_children(
        Parslet::Transform.first_success(fold, identity)
      )
      bottom_up = child_rewrite.compose(fold)
      input = [:add, [:add, 1, 2], 3]
      result = bottom_up.repeat_until_stable.try_apply(input)
      result.should be_changed
      result.status.should_not == :cycle
      result.value.should == 6
      result.iterations.should == 1
    end

    it "returns a witness when repeated rewriting forms a cycle" do
      a_to_b = Parslet::Transform.new(traversal: :root) do
        rule(:a) { :b }
      end
      b_to_a = Parslet::Transform.new(traversal: :root) do
        rule(:b) { :a }
      end

      sequential = a_to_b.compose(b_to_a)
      sequential.try_apply(:a).should be_unchanged
      sequential.try_apply(:a).value.should == :a

      result = a_to_b.first_success(b_to_a).repeat_until_stable.try_apply(:a)
      result.should be_cycle
      result.value.should == :a
      result.iterations.should == 2
      result.witness.states.should == [:a, :b]
      result.witness.repeat_from.should == 0
      result.witness.iteration.should == 2
    end

    it "returns the caller-budget state when repetition reaches its budget" do
      a_to_b = Parslet::Transform.new(traversal: :root) do
        rule(:a) { :b }
      end
      b_to_a = Parslet::Transform.new(traversal: :root) do
        rule(:b) { :a }
      end
      rewriter = a_to_b.first_success(b_to_a)

      result = rewriter.repeat_until_stable(budget: 1).try_apply(:a)
      result.should be_budget_exhausted
      result.value.should == :b
      result.iterations.should == 1

      initial = rewriter.repeat_until_stable(budget: 0).try_apply(:a)
      initial.should be_budget_exhausted
      initial.value.should == :a
      initial.iterations.should == 0
    end
  end
end
