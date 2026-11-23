#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Diagnostics.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
using namespace mlir;
using namespace spinel::consumer;
int main(int argc,char **argv) {
  if(argc!=2)return 2;
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&ctx);if(!module)return 2;
  Consumer c(*module);c.useIsolatedRegistryForTesting();
  // Deliberately omit the family's semantic verdict check in this test only.
  c.registry.addRoot("fentry",[](Consumer &running,Operation *node) {
    ProgramDecl p;p.kind="fentry";p.analysisContext="obj_BPF::FentryCtx";
    auto args=running.args(node);
    if(args.size()<2||text(args[1],"kind")!="StringNode")return Dispatch<ProgramDecl>::error();
    p.attachTarget=running.spelling(args[1],false).str();
    return Dispatch<ProgramDecl>::handled(std::move(p));
  });
  unsigned errors=0;
  ScopedDiagnosticHandler observer(&ctx,[&](Diagnostic &d) {
    if(d.getSeverity()==DiagnosticSeverity::Error)++errors;
    return failure(); // Keep the real verifier diagnostic visible.
  });
  auto result=spinel::lowerWithDiagnosticGate(c);
  if(succeeded(result)||errors!=1||c.printedRejections!=0) {
    llvm::errs()<<"FAIL post-lowering invalid IR gate\n";return 2;
  }
  llvm::outs()<<"post-lowering invalid verdict: MLIR error=1 artifacts=0\n";
  return 1;
}
