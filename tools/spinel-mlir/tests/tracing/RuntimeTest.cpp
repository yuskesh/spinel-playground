#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGRuntime.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool yes, const char *name) {
  if (!yes) { llvm::errs()<<"FAIL "<<name<<'\n'; std::exit(1); }
}
int main(int argc, char **argv) {
  require(argc == 2, "raw_tp facts path");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  for (int mode=0; mode<3; ++mode) {
    auto input=parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(input), "parse facts");
    Consumer c(*input); c.useIsolatedRegistryForTesting();
    registerGroupGRuntime(c.registry);
    Operation *call=nullptr;
    for (auto &item:c.nodes)
      if (field(item.second,"strings","name")=="pid_tgid" &&
          c.constant(c.ref(item.second,"receiver"))=="BPF") {call=item.second;break;}
    require(call, "actual pid call");
    if (mode==1) {
      auto id=c.id(call);
      for(auto evidence:c.evidence[id]) evidence->setAttr("callee",StringAttr::get(&ctx,"Other.pid_tgid"));
    }
    if (mode==2) c.evidence[c.id(call)].clear();
    auto result=c.dispatchExpression("CallNode",call);
    if(mode) {require(result.state==Disposition::Error && c.blocking,"bad or missing callee blocks");continue;}
    require(result.state==Disposition::Handled && result.value,"runtime handled");
    auto expr=*result.value;
    auto interval=llvm::cantFail(expr->range.interval.finite());
    require(expr->kind=="gkernel.pid_tgid" && expr->range.wide &&
      expr->range.form==spinel::range::Form::PidTgid &&
      interval.str()=="[0, 18446744073709551615]","pid range/form");
    auto output=ModuleOp::create(UnknownLoc::get(&ctx));
    c.builder.setInsertionPointToEnd(output.getBody());
    auto emitted=c.dispatchEmitter(expr->kind,expr);
    require(emitted.state==Disposition::Handled && emitted.value &&
      isa<ebpf::TaskPidTgidOp>((*emitted.value).getDefiningOp()) &&
      (*emitted.value).getType().isInteger(64) &&
      (*emitted.value).getLoc()==outputLoc(call),"typed op and Ruby loc");
    output.erase();
  }
  llvm::outs()<<"runtime pid: typed op/range/loc and two blocking controls GREEN\n";
}
