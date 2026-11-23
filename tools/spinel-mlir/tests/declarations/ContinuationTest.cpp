#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
#include <unistd.h>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok, const char *message) {
  if (!ok) { llvm::errs() << "FAIL " << message << "\n"; std::exit(1); }
}
template <class F> static std::string capture(F body) {
  int fd; llvm::SmallString<128> path;
  require(!llvm::sys::fs::createTemporaryFile("e034-stderr", "txt", fd, path), "capture file");
  llvm::errs().flush(); int previous = dup(STDERR_FILENO);
  require(previous >= 0 && dup2(fd, STDERR_FILENO) >= 0, "redirect stderr");
  body(); llvm::errs().flush();
  require(dup2(previous, STDERR_FILENO) >= 0, "restore stderr");
  close(fd); close(previous);
  auto bytes = llvm::MemoryBuffer::getFile(path);
  require(bool(bytes), "read diagnostics"); auto out = (*bytes)->getBuffer().str();
  llvm::sys::fs::remove(path); return out;
}
int main(int argc, char **argv) {
  require(argc == 2, "one unused_map facts fixture");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  for (unsigned mode : {0u, 1u, 2u, 3u}) {
    bool reject = mode == 1 || mode == 2;
    auto input = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(input), "parse real facts");
    std::string before; llvm::raw_string_ostream snapshot(before); input->print(snapshot);
    Consumer consumer(*input); consumer.useIsolatedRegistryForTesting();
    if (mode == 3) {
      // Synthetic combined unused-global/map ordering control. The global's
      // source position follows Spare, although its callback queues it first.
      Operation *later = nullptr;
      for (const auto &item : consumer.nodes)
        if (text(item.second, "kind") == "DefNode" &&
            field(item.second, "strings", "name") == "prog")
          later = item.second;
      require(later != nullptr, "synthetic global warning position");
      consumer.conditionalDiagnostic(later, "SB013", "MapDeclShape",
                                     "global Unused is declared but unused");
    }
    unsigned declarations = 0;
    consumer.registry.addDeclaration({"BPF::ArrayMap", "new"},
        [&](Consumer &c, Operation *node) {
          ++declarations;
          auto name = field(node, "strings", "name");
          if (reject && (name == "Counts" || mode == 2)) {
            (void)c.diagnostic(node, "SB013", "MapDeclShape",
                               "test " + name.str() + " declaration refused");
            return Dispatch<bool>::error();
          }
          return Dispatch<bool>::declined();
        });
    bool accepted = false;
    auto diagnostics = capture([&] { accepted = succeeded(consumer.run()); });
    llvm::outs() << (reject ? "rejected run: " : "control run: ") << diagnostics;
    require(declarations == 2, "declaration-continuation reaches Spare");
    if (!reject) {
      require(accepted && diagnostics.find("spinelbpf: warning: ") == 0 &&
                  diagnostics.find("map Spare is declared") != std::string::npos,
              "control keeps warning prefix and successful artifacts");
      if (mode == 3)
        require(diagnostics.find("map Spare is declared") <
                    diagnostics.find("global Unused is declared"),
                "combined global/map conditional source order");
    } else if (mode == 1) {
      require(!accepted, "declaration refusal never becomes success");
      auto first = diagnostics.find("rejected SB013");
      auto next = diagnostics.find("conditional SB013");
      require(first < next && next != std::string::npos &&
                  diagnostics.find("map Spare is declared") != std::string::npos &&
                  diagnostics.find("spinelbpf: warning:") == std::string::npos,
              "declaration-continuation retains following conditional");
      require(consumer.programs.empty() && consumer.maps.size() == 1 &&
                  consumer.maps[0].name == "Spare",
              "only valid declarations retained and rejected programs discarded");
      std::string after; llvm::raw_string_ostream os(after); input->print(os);
      require(before == after, "failure publishes no replacement IR");
    } else {
      require(!accepted && consumer.maps.empty() && consumer.programs.empty(),
              "multiple rejected declarations never publish artifacts");
      require(diagnostics.find("test Counts declaration refused") <
                  diagnostics.find("test Spare declaration refused") &&
                  diagnostics.find("conditional") == std::string::npos,
              "all declaration errors retained and failed declarations not unused");
    }
  }
  for (unsigned mode : {0u, 1u, 2u}) {
    auto input = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(input), "parse dependency control facts");
    Consumer consumer(*input); consumer.useIsolatedRegistryForTesting();
    bool audited = false;
    consumer.registry.sourceAudits.push_back([&](Consumer &, ArrayRef<Operation *>) {
      audited = true; return success();
    });
    consumer.registry.addDeclaration({"BPF::ArrayMap", "new"}, [&](Consumer &c, Operation *node) {
      auto name = field(node,"strings","name");
      if (name == "Counts" && mode != 1) {
        (void)c.diagnostic(node,"SB013","MapDeclShape","dependency control refusal");
        return Dispatch<bool>::error();
      }
      if (name == "Spare") {
        if (mode != 2) c.dependentDeclarationErrors.insert(c.id(node));
        return Dispatch<bool>::error();
      }
      return Dispatch<bool>::declined();
    });
    bool accepted = false;
    auto diagnostics = capture([&] { accepted = succeeded(consumer.run()); });
    require(!accepted && consumer.programs.empty(), "dependency controls publish no artifacts");
    require(audited == (mode == 0), mode == 0
        ? "diagnosed marked dependency continues to audit"
        : mode == 1 ? "mark without prior rejection stops" : "unmarked silent Error stops");
  }
  llvm::outs() << "declaration continuation GREEN\n";
}
