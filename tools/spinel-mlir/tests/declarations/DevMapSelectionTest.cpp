#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/raw_ostream.h"
using namespace mlir;
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                  arith::ArithDialect>();
  auto input = parseSourceFile<ModuleOp>(argv[1], &ctx);
  if (!input) return 2;
  std::string before;
  llvm::raw_string_ostream snapshot(before); input->print(snapshot);
  // Keep production registrations, including the custom xdp root. This tests
  // select(), not an isolated direct invocation of the declaration callback.
  spinel::consumer::Consumer consumer(*input);
  auto result = consumer.run();
  std::string after;
  llvm::raw_string_ostream output(after); input->print(output);
  if (succeeded(result) || consumer.printedRejections != 1 ||
      !consumer.maps.empty() || !consumer.programs.empty() || before != after) {
    llvm::errs() << "FAIL DevMap selection must reject without replacement IR\n";
    return 1;
  }
  llvm::outs() << "DevMap selection rejection GREEN\n";
}
