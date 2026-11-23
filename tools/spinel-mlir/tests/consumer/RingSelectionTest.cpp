// E029 addendum D (A): an invalid RingBuf declaration is selected by
// Consumer::select under the production registry (custom xdp root included)
// and rejected with Go's whole stderr; the control arm without the RingBuf
// declaration handler shows the selection assertion can fail.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
#include <fcntl.h>
#include <functional>
#include <unistd.h>
using namespace mlir;
using namespace spinel::consumer;

static void require(bool ok, const std::string &name) {
  // stdout: a failure inside captureStderr must still reach the log.
  if (!ok) {
    llvm::outs() << "FAIL " << name << "\n";
    llvm::outs().flush();
    std::exit(1);
  }
  llvm::outs() << "ok " << name << "\n";
}

static std::string workDir;

static std::string captureStderr(const std::function<void()> &fn) {
  std::string pattern = workDir + "/stderr-XXXXXX";
  std::vector<char> path(pattern.begin(), pattern.end());
  path.push_back('\0');
  int fd = mkstemp(path.data());
  if (fd < 0)
    require(false, "mkstemp");
  llvm::errs().flush();
  int saved = dup(2);
  dup2(fd, 2);
  fn();
  llvm::errs().flush();
  dup2(saved, 2);
  close(saved);
  close(fd);
  auto buffer = llvm::MemoryBuffer::getFile(path.data());
  unlink(path.data());
  return buffer ? (*buffer)->getBuffer().str() : std::string();
}

static bool ringSelected(Consumer &c) {
  return llvm::any_of(c.selectedTop, [&](Operation *n) {
    return text(n, "kind") == "ConstantWriteNode" &&
           field(n, "strings", "name") == "Events";
  });
}

int main(int argc, char **argv) {
  if (argc != 2) {
    llvm::errs() << "usage: spinel-ring-selection-test FACTS.mlir\n";
    return 2;
  }
  workDir = llvm::sys::path::parent_path(argv[1]).str();
  if (workDir.empty())
    workDir = ".";
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                  arith::ArithDialect>();
  auto oracle = llvm::MemoryBuffer::getFile(SPINEL_E029_RG_NOT_RECORD_STDERR);
  require(bool(oracle), "read the Go build.stderr");
  // E034 continues after the declaration's rejection, so the whole Go stderr
  // (the rejection, then the unused map's conditional SB013) is the oracle.
  auto goAll = (*oracle)->getBuffer().str();

  // Production registry: the declaration is selected and rejected.
  {
    auto input = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(input), "parse rg_not_record facts");
    std::string before;
    llvm::raw_string_ostream snapshot(before);
    input->print(snapshot);
    Consumer consumer(*input);
    FailureOr<spinel::Artifacts> result = failure();
    auto err = captureStderr([&] { result = consumer.run(); });
    require(ringSelected(consumer), "(a) the RingBuf declaration is selected");
    require(failed(result), "(b) the run fails");
    require(consumer.printedRejections == 1,
            "(c) exactly one printed rejection (" +
                std::to_string(consumer.printedRejections) + ")");
    require(err == goAll, "(c) stderr is Go's build.stderr byte for byte: " +
                              err);
    require(consumer.rings.empty() && consumer.badRings.count("Events") &&
                consumer.programs.empty(),
            "(d) no ring, Events in badRings, no program");
    std::string after;
    llvm::raw_string_ostream output(after);
    input->print(output);
    require(before == after, "(e) the input module is unchanged");
  }

  // Control: without the RingBuf declaration handler the declaration is not
  // selected — the assertion (a) above can fail.
  {
    auto input = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(input), "parse rg_not_record facts (control)");
    Consumer consumer(*input);
    Registry r = consumer.registry;
    llvm::erase_if(r.declarations, [](const auto &entry) {
      return entry.first.receiver == "BPF::RingBuf" &&
             entry.first.method == "new";
    });
    consumer.useIsolatedRegistryForTesting(std::move(r));
    (void)captureStderr([&] { (void)consumer.run(); });
    require(!ringSelected(consumer),
            "control: without the handler the declaration is not selected");
  }
  return 0;
}
