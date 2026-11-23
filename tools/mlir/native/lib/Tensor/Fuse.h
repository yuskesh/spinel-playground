// Private experimentally limited assign! fusion path. Read dest.assign!(expr) for rank 1/2, f32,
// multiply/add/relu; build standard func/linalg/arith MLIR, rewritten Ruby, C table and dispatch in
// memory. Not a production importer: refuses rank 3/4, subtraction/division, reductions, windows,
// quantization and mixed dtype. Used only by lib/Tensor and spinel-tensor-import, not public
// headers.
#ifndef SPINEL_MLIR_TENSOR_FUSE_H
#define SPINEL_MLIR_TENSOR_FUSE_H

#include "spinel-mlir/Contract/Model.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OwningOpRef.h"

#include "llvm/ADT/FunctionExtras.h"
#include "llvm/ADT/StringRef.h"

#include <optional>
#include <vector>
#include <string>

namespace spinel_mlir::tensor {

// Returned only after all semantic checks succeed; callers open output files afterward.
struct FuseArtifacts {
  // Parsed generated MLIR verifies well-formedness. Write mlirText, not printer output: kernel
  // identity is the FNV-1a of that exact text.
  mlir::OwningOpRef<mlir::ModuleOp> module;
  std::string mlirText;
  std::string rewrittenSource;
  std::string tableHeader;
  std::string rubyDispatch;
  unsigned sites = 0;
  unsigned kernels = 0;
  // Entry names in deduplicated appearance order, needed by caller success reporting entries:
  // <comma-joined names>.
  std::vector<std::string> entryNames;
  // One table row; identity is generated MLIR text FNV-1a, not reconstructible from declarations.
  struct TableRow {
    std::string name;
    unsigned nscalar = 0;
    std::string ranks;   ///< Rank per tensor argument ("11", "22", ...).
    std::string shape;   ///< Shape constraints
    uint64_t sig = 0;
  };
  std::vector<TableRow> tableRows;
};

// Closed refusal set: malformed-fuse-site, unsupported-fuse-signature, unsupported-fuse-body; emit
// no other categories.
using FuseDiagnosticFn =
    llvm::function_ref<void(llvm::StringRef category, llvm::StringRef detail)>;

// Report only the first failure through diag, then nullopt.
std::optional<FuseArtifacts>
compileFuse(const contract::ContractModule &module, llvm::StringRef sourceName,
               llvm::StringRef sourceText, mlir::MLIRContext &context,
               FuseDiagnosticFn diag);

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_FUSE_H
