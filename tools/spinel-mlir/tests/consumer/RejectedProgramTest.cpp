#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
#include <unistd.h>
using namespace spinel::consumer;
using namespace mlir;
static void require(bool ok, const char *name) {
  if (!ok) { llvm::errs() << "FAIL " << name << "\n"; std::exit(1); }
}
static void checkBodies(MLIRContext &context, const char *fixture) {
  for (auto code : {"SB019", "SB001", ""}) {
    auto module = parseSourceFile<ModuleOp>(fixture, &context);
    require(bool(module), "real two-root facts");
    std::string before;
    llvm::raw_string_ostream(before) << *module;
    Consumer c(*module);
    c.useIsolatedRegistryForTesting();
    int first = 0, second = 0;
    c.registry.addRoot("xdp", [&](Consumer &, Operation *) {
      ProgramDecl p;
      p.finalizeBody = [&](Consumer &running) {
        if (running.programName == "first") ++first;
        else if (running.programName == "second") ++second;
        return success();
      };
      return Dispatch<ProgramDecl>::handled(std::move(p));
    });
    c.registry.addStatement("CallNode", [&](Consumer &running,
        llvm::ArrayRef<Operation *> statements, size_t index, unsigned) {
      if (running.programName != "first")
        return Dispatch<StatementResult>::declined();
      if (*code)
        (void)running.diagnostic(statements[index], code, "Test", "body rejected");
      return Dispatch<StatementResult>::error();
    });
    int capture[2];
    require(pipe(capture) == 0, "stderr pipe");
    llvm::errs().flush();
    int saved = dup(STDERR_FILENO);
    require(saved >= 0 && dup2(capture[1], STDERR_FILENO) >= 0, "capture stderr");
    close(capture[1]);
    auto result = c.run();
    llvm::errs().flush();
    require(dup2(saved, STDERR_FILENO) >= 0, "restore stderr");
    close(saved);
    char bytes[8192];
    auto length = read(capture[0], bytes, sizeof(bytes));
    close(capture[0]);
    std::string stderrText = length > 0 ? std::string(bytes, length) : "";
    bool recover = StringRef(code) == "SB019";
    require(failed(result) && first == 0 && second == (recover ? 1 : 0),
            "only body SB019 continues, finalizer counts");
    require(StringRef(stderrText).contains("conditional SB013") == recover,
            "unused diagnostics only after actual recovery");
    if (recover)
      require(!StringRef(stderrText).contains("rejected SB003") &&
                  !StringRef(stderrText).contains("rejected SB001"),
              "failed root remains BPF-side for membership");
    require(c.programs.empty() && c.programBodyRejected == recover,
            "no successful programs published on failed run");
    std::string after;
    llvm::raw_string_ostream(after) << *module;
    require(before == after, "failed run preserves input facts");
    llvm::outs() << "body code=" << (*code ? code : "silent") << " GREEN\n";
  }
}
int main(int argc, char **argv) {
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = ModuleOp::create(FileLineColLoc::get(&context, "recovery.rb", 1, 1));
  for (auto code : {"SB019", "SB034"}) {
    Consumer c(module);
    c.useIsolatedRegistryForTesting();
    std::vector<Consumer::PendingDiagnostic> diagnostics;
    c.runDiagnostics = &diagnostics;
    require(failed(c.diagnostic(module, code, "Test", "real rejection")), "reject");
    require(succeeded(c.recoverRejectedProgram(code)) &&
                c.programBodyRejected && c.declarationRecovery && !c.blocking,
            "actual rejection permits recovery");
  }
  for (unsigned mode = 0; mode != 4; ++mode) {
    Consumer c(module);
    c.useIsolatedRegistryForTesting();
    std::vector<Consumer::PendingDiagnostic> diagnostics;
    c.runDiagnostics = &diagnostics;
    if (mode == 0) {
      c.probing = true;
      (void)c.diagnostic(nullptr, "SB019", "Test", "probe only");
      c.probing = false;
    } else if (mode == 1) {
      c.conditionalDiagnostic(module, "SB019", "Test", "conditional only");
    } else if (mode == 2) {
      (void)c.diagnostic(module, "SB001", "Test", "other rejection");
    }
    bool before = c.blocking;
    require(failed(c.recoverRejectedProgram("SB019")), "missing proof stops");
    require(!c.programBodyRejected && !c.declarationRecovery && c.blocking == before,
            "failure preserves flags");
  }
  Consumer c(module);
  std::vector<Consumer::PendingDiagnostic> diagnostics;
  c.runDiagnostics = &diagnostics;
  (void)c.diagnostic(module, "SB001", "Test", "not recoverable");
  require(failed(c.recoverRejectedProgram("SB001")) &&
              !c.programBodyRejected && !c.declarationRecovery && c.blocking,
          "unapproved code stops even with actual evidence");
  module.erase();
  llvm::outs() << "rejected program evidence GREEN\n";
  if (argc == 2) checkBodies(context, argv[1]);
}
