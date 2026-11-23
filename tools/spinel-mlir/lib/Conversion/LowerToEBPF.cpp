#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Pass/Pass.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>
#include <tuple>
using namespace mlir;
namespace spinel {
using namespace consumer;
LogicalResult reportRejection(ModuleOp module) {
  if (text(module, "spinel_facts.status") != "rejected")
    return success();
  SmallVector<Operation *> diagnostics;
  for (auto diagnostic : module.getOps<ir::DiagnosticOp>())
    if (text(diagnostic, "severity") == "error")
      diagnostics.push_back(diagnostic);
  auto key = [](Operation *op) {
    return std::make_tuple(text(op, "file"),
                           op->getAttrOfType<IntegerAttr>("line").getInt(),
                           op->getAttrOfType<IntegerAttr>("col").getInt());
  };
  std::stable_sort(diagnostics.begin(), diagnostics.end(),
                   [&](Operation *a, Operation *b) { return key(a) < key(b); });
  for (auto *op : diagnostics) {
    auto file = text(op, "file");
    auto line = op->getAttrOfType<IntegerAttr>("line").getInt();
    auto col = op->getAttrOfType<IntegerAttr>("col").getInt();
    llvm::errs() << (file.empty() ? StringRef("-") : file);
    if (line)
      llvm::errs() << ":" << line << ":" << col + 1;
    llvm::errs() << ": rejected SB000 (Spinel): spinel refused the program: "
                 << text(op, "message") << "\n";
  }
  return failure();
}

FailureOr<Artifacts> lowerWithDiagnosticGate(Consumer &consumer, Inspection *inspect) {
  if (inspect) *inspect = {};
  consumer.inspectionOutput = inspect;
  // Count MLIR errors without consuming them: the next handler still prints.
  size_t mlirErrors = 0;
  ScopedDiagnosticHandler count(consumer.ctx, [&](Diagnostic &d) {
    if (d.getSeverity() == DiagnosticSeverity::Error)
      ++mlirErrors;
    return failure();
  });
  auto result = consumer.run();
  if (failed(result) && consumer.printedRejections == 0 && mlirErrors == 0) {
    // Probe issues, warnings and `blocking` alone are not a diagnosis (E028).
    StringRef file;
    for (auto source : consumer.input.getOps<ir::SourceOp>())
      if (source->getAttrOfType<IntegerAttr>("file_id").getInt() == 0)
        file = llvm::sys::path::filename(text(source, "path"));
    llvm::errs() << (file.empty() ? StringRef("-") : file)
                 << ": rejected SB017 (InternalEmitter): consumer lowering "
                    "failed without a diagnostic (phase=consumer-lowering)\n";
  }
  return result;
}

FailureOr<Artifacts> lowerToEBPF(ModuleOp input, Inspection *inspect) {
  Consumer consumer(input);
  return lowerWithDiagnosticGate(consumer, inspect);
}
namespace {
struct LowerToEBPFPass : PassWrapper<LowerToEBPFPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LowerToEBPFPass)
  Artifacts *output;
  Inspection *inspect;
  explicit LowerToEBPFPass(Artifacts &result, Inspection *inspection) : output(&result), inspect(inspection) {}
  StringRef getArgument() const final { return "spinel-to-ebpf"; }
  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<ebpf::EBPFDialect, arith::ArithDialect>();
  }
  void runOnOperation() override {
    auto module = getOperation();
    if (failed(reportRejection(module))) {
      signalPassFailure();
      return;
    }
    auto bits = module->getAttrOfType<IntegerAttr>("spinel_facts.integer_bits");
    auto overflow = module->getAttrOfType<StringAttr>("spinel_facts.overflow");
    if (bits.getInt() != 64 || overflow.getValue() != "raise") {
      module.emitOpError("unsupported BPF policy: requires integer_bits=64 and "
                         "overflow=raise");
      signalPassFailure();
      return;
    }
    auto result = lowerToEBPF(module, inspect);
    if (failed(result))
      signalPassFailure();
    else
      *output = std::move(*result);
  }
};
} // namespace
std::unique_ptr<Pass> createLowerToEBPFPass(Artifacts &output, Inspection *inspect) {
  return std::make_unique<LowerToEBPFPass>(output, inspect);
}
} // namespace spinel
