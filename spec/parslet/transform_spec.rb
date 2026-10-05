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
    let(:fold) do
      Parslet::Transform.new do
        rule(:op => :add, :l => simple(:l), :r => simple(:r)) do |d|
          { :value => d[:l] + d[:r] }
        end
        rule(:value => simple(:value)) { |d| d[:value] }
      end
    end
    let(:identity) do
      Parslet::Transform.new do
        rule(:value => simple(:value)) { |d| d }
      end
    end
    let(:ping_pong) do
      Parslet::Transform.new do
        rule(:a => simple(:x)) { |d| { :b => d[:x] } }
        rule(:b => simple(:x)) { |d| { :a => d[:x] } }
      end
    end

    it "distinguishes no match, equal success, and a real change" do
      fold.apply_result(:unknown => 1).should be_no_match
      identity.apply_result(:value => 1).should be_unchanged
      fold.apply_result(:value => 1).should be_changed
    end

    it "lets exceptions propagate instead of treating them as mismatches" do
      raising = Parslet::Transform.new do
        rule(:value => simple(:value)) { raise "real failure" }
      end
      fallback = Parslet::Transform.new do
        rule(:value => simple(:value)) { |d| d[:value] }
      end

      expect {
        raising.first_successful(fallback).apply(:value => 1)
      }.to raise_error(RuntimeError, "real failure")
    end

    it "propagates exceptions from the postorder transform itself" do
      raising = Parslet::Transform.new do
        rule(:value => simple(:value)) { raise "postorder failure" }
      end

      expect {
        raising.apply_result(:value => 1)
      }.to raise_error(RuntimeError, "postorder failure")
    end

    describe "sequential composition" do
      it "applies the second rewrite after the first" do
        tree = { :op => :add, :l => { :value => 1 }, :r => { :value => 2 } }
        result = fold.and_then(identity).apply_result(tree)

        result.should be_changed
        result.value.should == { :value => 3 }
      end

      it "continues after a success that leaves the value equal" do
        increment = Parslet::Transform.new do
          rule(:value => simple(:value)) { |d| { :value => d[:value] + 1 } }
        end
        result = identity.and_then(increment).apply_result(:value => 1)

        result.should be_changed
        result.value.should == { :value => 2 }
      end

      it "rolls back to the input when either step does not match" do
        tree = { :unknown => true }
        result = identity.and_then(fold).apply_result(tree)

        result.should be_no_match
        result.value.should equal(tree)
      end

      it "reports equal success from both steps" do
        result = identity.and_then(identity).apply_result(:value => 1)

        result.should be_unchanged
        result.value.should == { :value => 1 }
      end

      it "does not run the fallback after a real exception" do
        raising = Parslet::Transform.new do
          rule(:value => simple(:value)) { raise "sequential failure" }
        end

        expect {
          raising.and_then(identity).apply(:value => 1)
        }.to raise_error(RuntimeError, "sequential failure")
      end
    end

    describe "first successful rewrite" do
      it "uses the first match even when it leaves the value equal" do
        increment = Parslet::Transform.new do
          rule(:value => simple(:value)) { |d| { :value => d[:value] + 1 } }
        end
        result = identity.first_successful(increment).apply_result(:value => 1)

        result.should be_unchanged
        result.value.should == { :value => 1 }
      end

      it "falls back only for a mismatch" do
        result = fold.first_successful(identity).apply_result(:value => 1)

        result.should be_changed
        result.value.should == 1
      end

      it "returns no match only when every rewrite mismatches" do
        tree = { :unknown => true }
        result = fold.first_successful(identity).apply_result(tree)

        result.should be_no_match
        result.value.should equal(tree)
      end
    end

    describe "one child" do
      it "rewrites only the first matching direct child" do
        tree = { :first => { :value => 1 }, :second => { :value => 2 } }
        result = fold.one_child.apply_result(tree)

        result.should be_changed
        result.value.should == { :first => 1, :second => { :value => 2 } }
      end

      it "does not try later children after a real exception" do
        raising = Parslet::Transform.new do
          rule(:value => 1) { raise "first child failed" }
        end
        tree = [ { :value => 1 }, { :value => 2 } ]

        expect {
          raising.one_child.apply(tree)
        }.to raise_error(RuntimeError, "first child failed")
        tree.should == [ { :value => 1 }, { :value => 2 } ]
      end

      it "reports equal success when the matched child stays equal" do
        tree = { :first => { :value => 1 }, :second => { :value => 2 } }
        result = identity.one_child.apply_result(tree)

        result.should be_unchanged
        result.value.should == tree
      end

      it "mismatches a parent with no matching children" do
        tree = { :first => { :unknown => 1 } }
        result = fold.one_child.apply_result(tree)

        result.should be_no_match
        result.value.should equal(tree)
      end
    end

    describe "all children" do
      it "treats a leaf as vacuous equal success" do
        result = fold.all_children.apply_result(1)

        result.should be_unchanged
        result.value.should == 1
      end

      it "treats an empty container as vacuous equal success" do
        empty = []
        result = fold.all_children.apply_result(empty)

        result.should be_unchanged
        result.value.should == []
      end

      it "rewrites every direct child" do
        result = fold.all_children.apply_result(
          [ { :value => 1 }, { :value => 2 } ]
        )

        result.should be_changed
        result.value.should == [1, 2]
      end

      it "reports equal success when every matched child stays equal" do
        result = identity.all_children.apply_result(
          [ { :value => 1 }, { :value => 2 } ]
        )

        result.should be_unchanged
      end

      it "returns the original tree when one child does not match" do
        tree = [ { :value => 1 }, { :unknown => 2 } ]
        result = fold.all_children.apply_result(tree)

        result.should be_no_match
        result.value.should equal(tree)
      end

      it "does not leave earlier rebuilt children when a later child raises" do
        raising = Parslet::Transform.new do
          rule(:value => simple(:value)) do |d|
            raise "later child failed" if d[:value] == 2
            d[:value]
          end
        end
        tree = [ { :value => 1 }, { :value => 2 } ]
        tree.each(&:freeze)
        tree.freeze

        expect {
          raising.all_children.apply(tree)
        }.to raise_error(RuntimeError, "later child failed")
        tree.should == [ { :value => 1 }, { :value => 2 } ]
      end
    end

    describe "repeat until stable" do
      it "folds constants until no rule matches" do
        tree = {
          :op => :add,
          :l => { :op => :add, :l => { :value => 1 }, :r => { :value => 2 } },
          :r => { :value => 3 }
        }
        result = fold.repeat_until_stable(10).apply_result(tree)

        result.should be_stable
        result.iterations.should == 3
        result.value.should == 6
      end

      it "returns a witness when rules rewrite in a cycle" do
        result = ping_pong.repeat_until_stable(10).apply_result(:a => 1)

        result.should be_cycle
        result.iterations.should == 2
        result.value.should == { :a => 1 }
        result.witness.should == [ { :a => 1 }, { :b => 1 }, { :a => 1 } ]
      end

      it "returns the state reached at the caller's budget" do
        result = ping_pong.repeat_until_stable(1).apply_result(:a => 1)

        result.should be_budget_exceeded
        result.iterations.should == 1
        result.budget.should == 1
        result.value.should == { :b => 1 }
      end

      it "reports an immediate equal success as stable" do
        result = identity.repeat_until_stable(2).apply_result(:value => 1)

        result.should be_stable
        result.iterations.should == 1
        result.value.should == { :value => 1 }
      end

      it "propagates real exceptions instead of reporting a cycle" do
        raising = Parslet::Transform.new do
          rule(:value => simple(:value)) { raise "repeat failure" }
        end

        expect {
          raising.repeat_until_stable(2).apply(:value => 1)
        }.to raise_error(RuntimeError, "repeat failure")
      end
    end
  end
end
