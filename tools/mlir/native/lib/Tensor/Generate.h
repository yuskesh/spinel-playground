// Tensor module generation, the generation half of frozen TensorFunc. The original SAXPY-only
// prototype handled one f32 rank-1 elementwise declaration; this handles declaration sets. Staged
// support recorded elementwise/reduction (f32 rank 1..4, multiple defs), u8 boundaries
// (widen/quantize/bitcast), and matvec as complete, with window support in progress. Refuse
// unimplemented forms with nullopt and let callers record pending.tsv rather than generating
// incorrect comparison artifacts. Private to lib/Tensor and spinel-tensor-import.
#ifndef SPINEL_MLIR_TENSOR_GENERATE_H
#define SPINEL_MLIR_TENSOR_GENERATE_H

#include "Body.h"
#include "Declaration.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OwningOpRef.h"

#include "llvm/ADT/StringRef.h"

#include <string>
#include <vector>

namespace spinel_mlir::tensor {

// Resolved pad_via:auto choice per declaration, returned for a module-header note. Roundtrip
// removes notes, not refusal diagnostics, so resolve it here.
struct PadChoice {
  std::string kernel;
  std::string got;   ///< "index" | "pad_op"
  std::string why;   ///< Nonempty reason, matching frozen padwhy.
};

// Build one module from declaration/body pairs. device is cpu/metal/empty. pad_via:auto with
// border:zero needs a device profile; refuse its absence with frozen wording. If a declaration
// cannot be generated, report one native diagnostic and nullopt. Python may support it, so this
// unmatched case belongs in pending.tsv; the gap shrinks with implementation stages.
mlir::OwningOpRef<mlir::ModuleOp>
generateTensorModule(const contract::ContractModule &module,
                     const std::vector<TensorDecl> &decls,
                     const std::vector<TensorBody> &bodies,
                     mlir::MLIRContext &context, llvm::StringRef device,
                     std::vector<PadChoice> &padChoice, DeclDiagnosticFn diag);

// Whether any declaration uses device-dependent pad_via:auto, matching has_auto. Answer before
// building to choose one module versus per-profile modules.
bool tensorHasAutoPadVia(const std::vector<TensorDecl> &decls);

// Frozen PAD_DEVICE_PROFILES.
llvm::ArrayRef<llvm::StringRef> tensorPadDeviceProfiles();

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_GENERATE_H
