#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
using namespace mlir;
using namespace spinel::consumer;
namespace spinel::consumer { void registerGroupG(Registry &); }
int main(int argc, char **argv) {
  if(argc!=2) return 2;
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);
  if(!input) return 2;
  Consumer c(*input);
  c.useIsolatedRegistryForTesting();
  registerGroupG(c.registry);
  c.registry.addRoot("xdp",[](Consumer &,Operation *) {
    return Dispatch<ProgramDecl>::handled(ProgramDecl{});
  });
  auto result=c.run();
  if(succeeded(result)||c.printedRejections!=1||!c.maps.empty()||!c.programs.empty()) {
    llvm::errs()<<"FAIL unused invalid SockMap must reject before custom root/artifacts\n";
    return 1;
  }
  llvm::outs()<<"unused invalid SockMap/custom XDP rejection GREEN\n";
}
