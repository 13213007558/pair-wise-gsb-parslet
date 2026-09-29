require 'spec_helper'

describe Parslet::Scope do
  let(:scope) { described_class.new }
  
  describe 'simple store/retrieve' do
    before(:each) { scope[:foo] = :bar }
    it "allows storing objects" do
      scope[:obj] = 42
    end 
    it "raises on access of empty slots" do
      expect {
        scope[:empty]
      }.to raise_error(Parslet::Scope::NotFound)
    end 
    it "allows retrieval of stored values" do
      scope[:foo].should == :bar
    end 
  end
  
  describe 'snapshot/restore' do
    it 'restores captures made after the snapshot' do
      scope[:foo] = :bar
      snap = scope.snapshot
      scope[:foo] = :baz
      scope[:other] = 1

      scope.restore(snap)
      scope[:foo].should == :bar
      expect { scope[:other] }.to raise_error(Parslet::Scope::NotFound)
    end

    it 'detaches the snapshot from later mutations' do
      scope[:foo] = :bar
      snap = scope.snapshot
      scope[:foo] = :baz

      scope.restore(snap)
      scope[:foo].should == :bar
    end

    it 'preserves the scope chain' do
      scope[:depth] = 1
      scope.push
      scope[:depth] = 2
      snap = scope.snapshot
      scope.pop
      scope[:depth] = 3

      scope.restore(snap)
      scope[:depth].should == 2
      scope.pop
      scope[:depth].should == 1
    end
  end

  describe 'scoping' do
    before(:each) { scope[:depth] = 1 }
    before(:each) { scope.push }
    
    let(:depth) { scope[:depth] }
    subject { depth }
    
    it { should == 1 }
    describe 'after a push' do
      before(:each) { scope.push }
      it { should == 1 }
      
      describe 'and reassign' do
        before(:each) { scope[:depth] = 2 }
        
        it { should == 2 }

        describe 'and a pop' do
          before(:each) { scope.pop }
          it { should == 1 }
        end
      end
    end
  end
end
