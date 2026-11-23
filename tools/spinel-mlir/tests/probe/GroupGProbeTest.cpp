#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGProbe.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok, const char *message) {
  if (!ok) { llvm::errs() << "FAIL " << message << "\n"; std::exit(1); }
}
int main(int argc, char **argv) {
  require(argc == 2, "one real raw_tp facts fixture");
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto input = parseSourceFile<ModuleOp>(argv[1], &context);
  require(bool(input), "parse facts");
  Consumer c(*input);
  c.useIsolatedRegistryForTesting();
  registerGroupGProbe(c.registry);
  Operation *root = nullptr;
  for (auto table : input->getOps<spinel::ir::TableOp>())
    if (text(table, "phase") == "pristine")
      root = c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  require(root && succeeded(c.select(root)), "select real root");
  Operation *entry = nullptr;
  unsigned roots = 0;
  for (auto node : c.selectedTop)
    if (text(node, "kind") == "CallNode" && field(node, "strings", "name") == "raw_tp") {
      entry = node; ++roots;
    }
  require(roots == 1, "one selected root");
  auto result = c.dispatchRoot(entry);
  require(result.state == Disposition::Handled && bool(result.value),
          "probe root handler reached without production registrations");
  auto &p = *result.value;
  require(p.kind == "raw_tp" && p.attachTarget == "sys_enter" &&
              p.analysisContext == "obj_BPF::RawTpCtx" && p.arch.empty(),
          "raw_tp context and target retain source meaning");
  require(bool(p.payload) && bool(p.finalizeBody), "owned metadata and finalizer");
  c.programs.push_back(p);
  auto exported = c.dispatchProgramExport(0, true);
  require(exported.state == Disposition::Handled && bool(exported.value),
          "probe owns program exporter");
  llvm::outs() << "probe root metadata and isolated registration GREEN\n";
}
