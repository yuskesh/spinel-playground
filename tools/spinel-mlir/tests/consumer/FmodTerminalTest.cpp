#include "spinel/Conversion/FmodRet.h"
#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Verifier.h"
#include <cstdlib>
using namespace spinel::consumer;
using namespace mlir;
static void require(bool ok,const char *name) {
  if(!ok){llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
int main() {
  MLIRContext context;context.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=ModuleOp::create(UnknownLoc::get(&context));Consumer c(input);c.useIsolatedRegistryForTesting();
  auto loc=c.builder.getUnknownLoc();
  for(int mode=0;mode<3;++mode) {
    c.builder.setInsertionPointToEnd(input.getBody());
    auto p=ebpf::ProgramOp::create(c.builder,loc,"test"+std::to_string(mode),"fmod_ret",c.builder.getStringAttr("test_target"),ArrayAttr{},StringAttr{},false,ArrayAttr{});
    auto block=new Block();p.getBody().push_back(block);c.builder.setInsertionPointToStart(block);
    block->addArgument(ebpf::ContextType::get(&context,"fmod_ret"),loc);
    Value fired;if(mode)fired=arith::ConstantIntOp::create(c.builder,loc,1,1);
    require(succeeded(emitFmodTerminal(c,loc,{},fired,mode!=0,mode==2?std::optional<int64_t>(-1):std::nullopt)),"terminal succeeds");
    if(mode==0)require(block->back().getName().getStringRef()=="ebpf.verdict","plain FMOD_CALL is verdict done");
    if(mode==1)require(block->back().getName().getStringRef()=="ebpf.verdict.if","both call guard keeps verdict.if");
    if(mode==2) {
      auto ret=&block->back();require(ret->getName().getStringRef()=="ebpf.return","replacement guard returns i32");
      auto select=ret->getOperand(0).getDefiningOp<arith::SelectOp>();require(bool(select)&&select.getCondition()==fired,"select uses fired");
      auto yes=select.getTrueValue().getDefiningOp<arith::ConstantIntOp>();
      auto no=select.getFalseValue().getDefiningOp<arith::ConstantIntOp>();
      require(yes&&no&&yes.value()==-1&&no.value()==0,"replacement true -1 / original false 0");
    }
  }
  require(succeeded(verify(input)),"all terminal programs verify");
}
