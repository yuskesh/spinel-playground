#include "spinel/Conversion/Consumer.h"
#include "mlir/Parser/Parser.h"
#include <cstdio>
using namespace mlir;
using namespace spinel::consumer;
int main(int argc,char **argv) {
  if (argc!=2) return 2;
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&ctx);if (!module) return 2;
  Consumer c(*module);
  Operation *root=nullptr,*def=nullptr,*entry=nullptr;
  for (auto table:module->getOps<spinel::ir::TableOp>())
    if (text(table,"phase")=="pristine") root=c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  for (auto n:c.array(c.ref(root,"statements"),"body")) {
    if (text(n,"kind")=="DefNode") def=n;
    if (text(n,"kind")=="CallNode" && c.constant(c.ref(n,"receiver"))=="BPF") entry=n;
  }
  if (!def || !entry) return 2;
  auto params=c.array(c.ref(def,"parameters"),"requireds");if (params.size()!=1) return 2;
  spinel::Inspection inspection;c.inspectionOutput=&inspection;
  c.inspectionRootDefinition=def;c.rootEntries.push_back(entry);
  c.noteInspectionBody(params.front());
  if (c.inspectionGraphAvailable || !c.inspectionDomain.functions.empty()) {
    std::fprintf(stderr,"FAIL inspection-parameter-is-not-body\n");return 1;
  }
  c.noteInspectionBody(entry);
  if (c.inspectionGraphAvailable) return 1;
  c.noteInspectionBody(c.ref(def,"body"));
  if (!c.inspectionGraphAvailable || c.inspectionDomain.functions.empty()) {
    std::fprintf(stderr,"FAIL inspection-root-body-identity\n");return 1;
  }
  return 0;
}
