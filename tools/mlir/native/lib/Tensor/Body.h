// Tensor def/body structure, matching frozen _read_params/build/_build_assign. Emit owns expression
// traversal (_scan/_expr) because it also generates IR. Here check declaration/def parameter
// kind/count, a single assign/sum/max/min body root, and assign receiver matching dest:. Preserve
// frozen diagnostic wording.
#ifndef SPINEL_MLIR_TENSOR_BODY_H
#define SPINEL_MLIR_TENSOR_BODY_H

#include "Declaration.h"
#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::tensor {

// Top-level defs indexed by name.
std::map<std::string, int64_t> topLevelDefs(const contract::ContractModule &module);

// Node-kind blurbs match frozen NODE_BLURB; unknown kinds use a <Kind>.
std::string nodeBlurb(llvm::StringRef kind);

// One tensor source read by an expression, ordered by first appearance as TensorFunc.sources.
struct TensorSource {
  enum class Kind { Param, Matvec, Window, Mode, Tap, Bilinear, Hist };
  Kind kind = Kind::Param;
  std::string name;   ///< Param: parameter name; otherwise the read tensor parameter name.
  int64_t node = -1;  ///< Matvec: its CallNode.
  std::string mat, vec; ///< Matvec operands; for Mode, mat is the coefficient matrix.
  std::string win, op;  ///< Window name and conv2d/depthwise operation.
  // Reduction axis for mode_mul/tap_mul: 0 is d0, 1 is d1.
  int axis = 0;
  // tap_mul tap-index and weight tensors, both shaped (n_out,K).
  std::string idx, wgt;
};

// Def/body structure for one declaration.
struct TensorBody {
  std::vector<std::string> paramNames;  ///< Required def parameter names.
  std::map<std::string, int> rank;      ///< Parameter name to rank
  std::string root;                     ///< "assign" | "sum" | "max" | "min"
  int64_t rootNode = -1;                ///< Root CallNode.
  int64_t exprNode = -1;                ///< Only assign argument, or reducer receiver.
  int ewRank = 1;                       ///< Rank of the elementwise iteration space.
  std::vector<TensorSource> sources;    ///< Expression sources in first-appearance order.
  // Whether a prologue op lacks native generation. Always false after the additional operation
  // family was implemented; retained as an interface for future families.
  bool hasUnimplementedPrologue = false;
};

// Match decl to defNode; on first failure report one frozen-worded diagnostic and nullopt.
std::optional<TensorBody>
readTensorBody(const contract::ContractModule &module, const TensorDecl &decl,
               int64_t defNode, DeclDiagnosticFn diag);

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_BODY_H
