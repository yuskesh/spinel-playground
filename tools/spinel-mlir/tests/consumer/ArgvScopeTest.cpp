#include "spinel/Conversion/Argv.h"
#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Verifier.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok,const char *name) {
  if(!ok){llvm::outs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
int main() {
  MLIRContext context;context.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  for(int mode=0;mode<4;++mode) {
    auto loc=UnknownLoc::get(&context);OwningOpRef<ModuleOp> module(ModuleOp::create(loc));
    Consumer c(*module);c.useIsolatedRegistryForTesting();c.activeKind="ksyscall";
    c.builder.setInsertionPointToEnd(module->getBody());
    auto p=ebpf::ProgramOp::create(c.builder,loc,"test","ksyscall",c.builder.getStringAttr("execve"),ArrayAttr{},c.builder.getStringAttr("x86_64"),false,ArrayAttr{});
    auto block=new Block();p.getBody().push_back(block);c.contextValue=block->addArgument(ebpf::ContextType::get(&context,"ksyscall"),loc);
    c.builder.setInsertionPointToStart(block);c.probing=mode==1;
    unsigned arrays=0,slots=0;std::vector<int64_t> indices;
    auto made=emitArgvSlots(c,loc,[&](Consumer &c,Location l)->FailureOr<Value> {
      ++arrays;
      if(mode==3)return arith::ConstantIntOp::create(c.builder,l,0,64).getResult();
      OperationState s(l,"ebpf.ksyscall.arg");s.addOperands(c.contextValue);s.addTypes(ebpf::UserStrArrayType::get(&context));s.addAttribute("n",c.builder.getI64IntegerAttr(2));
      return c.builder.create(s)->getResult(0);
    },[&](Consumer &c,Value string,int64_t k,Location l) {
      ++slots;indices.push_back(k);require(isa<ebpf::UserStrType>(string.getType()),"slot is user string");
      if(mode==2&&k==7){c.bindings["rollback"]={nullptr,nullptr,string};return failure();}
      arith::ConstantIntOp::create(c.builder,l,k,32);return success();
    });
    if(mode!=0) {
      require(failed(made),"Probe/partial failure/wrong array type fail loudly");
      require(block->empty(),"no partial array/read/regions in live IR");
      require(c.bindings.empty(),"failed callback binding restored");
      require(c.builder.getInsertionBlock()==block,"insertion point restored");
      if(mode==1)require(arrays==0&&slots==0,"Probe invokes no emit callback");
      if(mode==2)require(arrays==1&&slots==8,"slot7 fails after staged prefix");
      if(mode==3)require(arrays==1&&slots==0,"wrong array type rejected before slots");
      continue;
    }
    require(succeeded(made)&&arrays==1&&slots==20,"one array and twenty slots");
    unsigned seen=0,loops=0;Operation *previous=nullptr;
    module->walk([&](ebpf::UserStrAtOp at) {
      require(at.getIndex()==seen,"literal index order 0..19");
      if(previous)require(at->getParentRegion()==&previous->getRegion(0),"next slot is inside previous present");
      auto branch=at->getNextNode();require(branch&&isa<ebpf::IfOp>(branch)&&branch->getOperand(0)==at.getPresent(),"present controls immediate if");
      require(branch->getRegion(1).front().getOperations().size()==1&&isa<ebpf::IfYieldOp>(branch->getRegion(1).front().back()),"absent arm ends without another slot");
      previous=branch;++seen;
    });
    module->walk([&](ebpf::LoopOp){++loops;});
    require(seen==20&&loops==0,"twenty straight-line nested reads, no loop");
    c.builder.setInsertionPointToEnd(block);ebpf::VerdictOp::create(c.builder,loc,"done");
    require(succeeded(verify(*module)),"published argv structure verifies");
  }
  llvm::outs()<<"argv-scope: nested20, Probe0, failed-publication0\n";
}
