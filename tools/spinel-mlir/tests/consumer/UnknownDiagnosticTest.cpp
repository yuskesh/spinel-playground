#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include <cstdlib>
#include <unistd.h>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool value, const char *why) {
  if (!value) { llvm::errs() << "FAIL " << why << '\n'; std::exit(1); }
}
// The old public diagnostic route makes the missing Unknown behavior observable
// before the new entry exists; no replacement renderer is implemented here.
template<class C> static auto unknown(C &c, Operation *n, int)
    -> decltype(c.unknownDiagnostic(n, "SB004", "UnknownEdge", "dynamic edge", true)) {
  return c.unknownDiagnostic(n, "SB004", "UnknownEdge", "dynamic edge", true);
}
template<class C> static LogicalResult unknown(C &c, Operation *n, long) {
  return c.diagnostic(n, "SB004", "UnknownEdge", "dynamic edge", true);
}
template<class C> static auto typed(C &c, Operation *n, int) -> decltype(c.typed(n)) {
  return c.typed(n);
}
template<class C> static LogicalResult typed(C &c, Operation *n, long) {
  return c.known(n);
}
int main(int argc, char **argv) {
  require(argc == 2, "fixture");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  auto module = parseSourceFile<ModuleOp>(argv[1], &ctx);
  require(bool(module), "parse");
  {
    Consumer typing(*module);
    typing.probing = true;
    require(succeeded(typed(typing, typing.nodes.lookup(9), 0)),
            "real Integer type is not a missing sentinel");
    require(failed(typed(typing, typing.nodes.lookup(0), 0)),
            "unknown sentinel fails the semantic typed guard");
    require(!typing.blocking && typing.probeIssues.size() == 1 &&
                typing.probeIssues.front().unknown,
            "missing sentinel is speculative Unknown, not a real rejection");
  }
  {
    Consumer probe(*module);
    probe.useIsolatedRegistryForTesting();
    probe.probing = true;
    probe.activeDiagnosticPath = {"outer", "helper"};
    require(failed(unknown(probe, probe.nodes.lookup(10), 0)), "Probe fails locally");
    require(!probe.blocking && probe.printedRejections == 0 && probe.probeIssues.size() == 1,
            "Probe does not publish a blocking diagnostic");
    auto savedIssue = probe.probeIssues.front();
    probe.probing = false;
    probe.activeDiagnosticPath = {"different"};
    std::vector<Consumer::PendingDiagnostic> queued;
    probe.runDiagnostics = &queued;
    require(failed(probe.issue(savedIssue)), "replay blocks");
    require(queued.size() == 1 && queued[0].rejectedCode.empty() &&
                queued[0].verdict == Consumer::DiagnosticVerdict::Unknown &&
                queued[0].code == "SB004",
            "Unknown identity is structured, never recovery evidence");
    require(queued[0].text.find(": unknown SB004 (UnknownEdge): dynamic edge [path: outer -> helper]") != std::string::npos,
            "Probe replay retains original label/name/path");
    require(failed(probe.recoverRejectedProgram("SB034")) && probe.blocking,
            "Unknown cannot recover as an SB034 rejection");
    probe.runDiagnostics = nullptr;
  }
  Consumer c(*module);
  c.useIsolatedRegistryForTesting();
  c.registry.addRoot("xdp", [](Consumer &, Operation *) {
    ProgramDecl p;
    p.finalizeBody = [](Consumer &running) {
      return unknown(running, running.activeDef, 0);
    };
    return Dispatch<ProgramDecl>::handled(std::move(p));
  });
  int fds[2]; require(pipe(fds) == 0, "pipe");
  llvm::errs().flush();
  int saved = dup(STDERR_FILENO);
  require(saved >= 0 && dup2(fds[1], STDERR_FILENO) >= 0, "redirect");
  close(fds[1]);
  auto result = c.run();
  llvm::errs().flush();
  require(dup2(saved, STDERR_FILENO) >= 0, "restore"); close(saved);
  char buffer[4096]; auto count = read(fds[0], buffer, sizeof(buffer)); close(fds[0]);
  std::string output = count > 0 ? std::string(buffer, count) : "";
  require(failed(result), "Unknown blocks artifacts");
  require(output.find(": unknown SB004 (UnknownEdge): dynamic edge [path: count_pkts]\n") != std::string::npos,
          "queued Unknown preserves verdict/name/path");
  require(output.find("rejected") == std::string::npos, "Unknown is not a rejection");
  require(c.printedRejections == 1, "printed Unknown prevents extra SB017");
  llvm::outs() << "unknown diagnostic: queued label and failure gate passed\n";
}
