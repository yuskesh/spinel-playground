#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/SourceAudits.h"
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
  for (int mode = 0; mode != 6; ++mode) {
    auto module = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(module), "parse");
    Consumer c(*module);
    auto node = c.nodes.lookup(2148);
    c.activeDef = c.nodes.lookup(2140);
    c.programName = "prog";
    for (auto &[id, candidate] : c.nodes)
      if (text(candidate,"kind")=="CallNode" && field(candidate,"strings","name")=="xdp" && c.constant(c.ref(candidate,"receiver"))=="BPF")
        c.rootEntries.push_back(candidate);
    std::vector<Consumer::PendingDiagnostic> diagnostics;
    c.runDiagnostics = &diagnostics;
    require(failed(auditProgramSource(c,{})), "real source audit records SB016");
    require(diagnostics.size()==1 && diagnostics[0].code=="SB016" && diagnostics[0].verdict==Consumer::DiagnosticVerdict::Unknown,
            "actual structured source Unknown");
    c.sourceAuditUnknown = true;
    c.blocking = false;
    if (mode == 1) diagnostics.clear(); // A stale flag is insufficient.
    if (mode == 2) {
      auto analyzed = c.analyzed.lookup(c.id(node));
      auto attrs = NamedAttrList(analyzed->getAttrOfType<DictionaryAttr>("integers"));
      attrs.set("bx_copy",c.builder.getStringAttr("-2"));
      analyzed->setAttr("integers",attrs.getDictionary(&ctx));
    }
    if (mode == 3) c.evidence[c.id(node)].clear();
    if (mode == 4) c.registry.rejectOnlyScalarChecks.clear();
    if (mode == 5) {
      c.registry.rejectOnlyScalarChecks.clear();
      c.registry.rejectOnlyScalarChecks.push_back([](Consumer &, Operation *) {
        return Dispatch<bool>::handled(true);
      });
    }
    auto before = c.input.getBody()->getOperations().size();
    auto result = c.scalar(node);
    require(failed(result) && c.blocking, "operator check only rejects");
    require(c.input.getBody()->getOperations().size()==before && c.programs.empty(), "no value/IR/program publication");
    require(!diagnostics.empty() && diagnostics.back().rejectedCode==(mode==0 ? "SB009" : mode==5 ? "SB017" : "SB001"),
            "exact rejection proof or original identity gate");
    c.runDiagnostics = nullptr;
  }
  llvm::outs() << "source operator rejection: proof/stale/missing-clone/missing-evidence/empty/invalid-Handled passed\n";
}
