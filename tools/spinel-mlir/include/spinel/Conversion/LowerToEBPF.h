#ifndef SPINEL_LOWER_TO_EBPF_H
#define SPINEL_LOWER_TO_EBPF_H
#include "mlir/IR/BuiltinOps.h"
#include "spinel/Conversion/Inspection.h"
#include <string>
#include <memory>
namespace mlir { class Pass; }
namespace spinel {
struct Artifacts {
  std::string schema;
  std::string maps;
  std::string records;
  std::vector<UprobeTarget> uprobeTargets;
};
mlir::FailureOr<Artifacts> lowerToEBPF(mlir::ModuleOp input, Inspection *inspect = nullptr);
namespace consumer { class Consumer; }
// The wrapper boundary of lowerToEBPF: a failed run that printed no rejection
// and raised no MLIR error gains one SB017 line (E028). Consumer::run called
// directly is outside the gate.
mlir::FailureOr<Artifacts> lowerWithDiagnosticGate(consumer::Consumer &, Inspection *inspect = nullptr);
std::unique_ptr<mlir::Pass> createLowerToEBPFPass(Artifacts &output, Inspection *inspect = nullptr);
}
#endif
