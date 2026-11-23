#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool value, const char *why) {
  if (!value) { llvm::errs() << "FAIL " << why << '\n'; std::exit(1); }
}
int main(int argc, char **argv) {
  require(argc == 2, "fixture");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  for (int mode = 0; mode != 4; ++mode) {
    auto module = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(module), "parse");
    Consumer c(*module);
    c.useIsolatedRegistryForTesting();
    // The fixture is group A; root dispatch is intentionally isolated so no
    // production source/packet registration influences these audit controls.
    c.registry.addRoot("xdp", [](Consumer &, Operation *) {
      return Dispatch<ProgramDecl>::handled(ProgramDecl{});
    });
    c.sourceAuditUnknown = true; // A previous run's flag must not be evidence.
    int later = 0;
    c.registry.sourceAudits.push_back([&](Consumer &running, auto) {
      if (mode == 3) return failure(); // No actual diagnostic.
      auto *node = running.nodes.lookup(10);
      (void)running.unknownDiagnostic(node,"SB016","DynamicProgram","source audit control");
      if (mode == 2)
        (void)running.diagnostic(node,"SB001","UnsupportedConstruct","mixed failure");
      return failure();
    });
    if (mode == 1)
      c.registry.sourceAudits.push_back([](Consumer &, auto) { return failure(); });
    c.registry.sourceAudits.push_back([&](Consumer &, auto) { ++later; return success(); });
    auto result = c.run();
    require(failed(result), "source Unknown/error never publishes artifacts");
    require(later == (mode == 0 ? 1 : 0), "only a fresh unmixed SB016 allows continuation");
    require(c.sourceAuditUnknown == (mode < 2), "run reset and actual diagnostic evidence");
    require(c.programs.empty(), "failure leaves no published programs");
  }
  llvm::outs() << "source audit continuation: new/stale/mixed/undiagnosed gates passed\n";
}
