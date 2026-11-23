// Read tensor_def with the same acceptance/refusal wording as frozen collect_tensor_decls; the
// earlier prototype supported SAXPY only. Emit one <where>: <detail> line, where is tensor_def
// :<name> (line <n>); CLI adds spinel-mlirgen: unsupported:, matching frozen die. Private header
// for lib/Tensor and spinel-tensor-import only.
#ifndef SPINEL_MLIR_TENSOR_DECLARATION_H
#define SPINEL_MLIR_TENSOR_DECLARATION_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/FunctionExtras.h"
#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::tensor {

// One refusal, with frozen wording.
using DeclDiagnosticFn = llvm::function_ref<void(llvm::StringRef detail)>;

// params: spelling to rank, preserving TENSOR_RANK ordering used by
// sorted(TENSOR_RANK,key=TENSOR_RANK.get) diagnostics.
int rankOf(llvm::StringRef sym);

// One tensor_def: declaration facts only, without inspecting its body.
struct TensorDecl {
  std::string name;
  std::string dtype;                  ///< "f32" | "u8"
  std::vector<std::string> params;    ///< "scalar" | "vec" | "mat" | "ten3" | "ten4"
  std::vector<std::string> dtypes;    ///< Matches params length; defaults to repeated dtype.
  int64_t dest = -1;
  std::string returns = "none";       ///< "none" | "scalar"
  std::string reduction = "default";  ///< "default" | "fixed_tree"
  int64_t treeArity = 2;
  std::string quant = "half_even";    ///< "half_even" | "half_up"
  // Declared window coefficients as f32 after folding window_scale:, matching generation and
  // contributing to module text/signature hash.
  std::map<std::string, std::vector<std::vector<float>>> windows;
  int64_t channels = 1;
  std::string border = "zero";        ///< "zero" | "clamp" | "reflect"
  std::string padVia = "index";       ///< "index" | "pad_op" | "auto"
  // Window keywords actually present, in fixed Python order rather than declaration order;
  // Entry.sig reads them.
  std::vector<std::string> windowKw;
  int64_t line = 0;

  // Diagnostic prefix: tensor_def :name (line n).
  std::string where() const;
};

// One tensor_extern names an entry in a foreign .vmfb; no body exists, so its signature must be
// explicit.
struct TensorExtern {
  std::string name;
  std::string dtype;                 ///< Default entry element type.
  std::string vmModule, entry;
  std::vector<std::string> params;   ///< "vec" | "mat" | "ten3" | "ten4"
  // Per-parameter shapes: fixed integer dimensions or :name dimension variables.
  struct Dim { bool fixed = false; int64_t value = 0; std::string sym; };
  std::vector<std::vector<Dim>> shapes;
  std::string returns;
  std::vector<Dim> returnsShape;
  // dtypes:/returns_dtype: override individual tensors for mixed signatures.
  std::vector<std::string> dtypes;   ///< Empty means unspecified.
  std::string returnsDtype;          ///< Empty means unspecified.
  int64_t line = 0;

  std::string where() const;
};

// Collect tensor_externs in declaration order, stopping at first failure with one frozen-worded
// diag and nullopt.
std::optional<std::vector<TensorExtern>>
collectTensorExterns(const contract::ContractModule &module, DeclDiagnosticFn diag);

// Collect tensor_defs in declaration order; first failure reports one diagnostic and nullopt,
// matching frozen Unsupported.
std::optional<std::vector<TensorDecl>>
collectTensorDecls(const contract::ContractModule &module, DeclDiagnosticFn diag);

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_DECLARATION_H
