// Private, experimentally limited tensor_extern path for mnist_mlp/cnn_dyn forms: declaration
// validation, foreign MLIR matching, two approved text repairs, C table and Ruby dispatch. Not a
// production importer: refuses mixed dtype, multiple externs, quantization, rank 1 and multiple
// parameters. Repairs are only two line-local rules, not general StableHLO handling. Include only
// from lib/Tensor and spinel-tensor-import, not public headers.
#ifndef SPINEL_MLIR_TENSOR_EXTERN_H
#define SPINEL_MLIR_TENSOR_EXTERN_H

#include "Declaration.h"
#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/FunctionExtras.h"
#include "llvm/ADT/StringRef.h"

#include <optional>
#include <string>

namespace spinel_mlir::tensor {

// Returned only after every semantic check succeeds. The caller must wait until then to open
// outputs, leaving no artifacts on intermediate failure.
struct ExternArtifacts {
  // Success-line body from frozen check_extern_against_mlir: <vm_module> @<entry> ([d,d]:elt ->
  // [d,d]:elt) matches <where>. Caller prefixes spinel-mlirgen: extern-check.
  std::string summary;
  std::string repairedModule; ///< Empty if repair was not requested.
  unsigned convWindowRepairs = 0;
  unsigned dynamicReshapeRepairs = 0;
};

// Three-category closed set, private to externs rather than reusing declaration aliases or creating
// a shared public header.
using ExternDiagnosticFn =
    llvm::function_ref<void(llvm::StringRef category, llvm::StringRef detail)>;

// Build all metadata in memory from sealed contract, source basename and foreign MLIR. First
// failure reports diag and nullopt; caller adds no diagnostic. Match one tensor_extern against its
// external module. collectTensorExterns now owns reading, this path only matching/repair; Emit
// writes all table/dispatch entries together, replacing former one-entry templates.
std::optional<ExternArtifacts>
checkExtern(const TensorExtern &decl, llvm::StringRef foreignModule,
            llvm::StringRef modulePath, ExternDiagnosticFn diag);

// Run --extern-repair before matching, so checking and downstream compilation see the same file. If
// no repair applies, return text unchanged; repairing an already repaired module must preserve
// bytes.
std::optional<ExternArtifacts>
repairExternModule(llvm::StringRef foreignModule, llvm::StringRef where,
                   ExternDiagnosticFn diag);

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_EXTERN_H
