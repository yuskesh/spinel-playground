// Tensor table/dispatch output matches frozen table_h/gen_rb bytes. Entry fnv1a64 signatures and
// shape constraints are consumed by Spinel builds; changing bytes changes stale-.vmfb detection.
// Private header for lib/Tensor and spinel-tensor-import.
#ifndef SPINEL_MLIR_TENSOR_EMIT_H
#define SPINEL_MLIR_TENSOR_EMIT_H

#include "Body.h"
#include "Declaration.h"

#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::tensor {

// Frozen fnv1a64 with its highest bit cleared.
uint64_t fnv1a64(llvm::StringRef text);

// One .vmfb entry equals one func.func and one table row.
struct Entry {
  std::string name;
  std::string fq;                    ///< Default: module.<name>.
  std::vector<std::string> params;   ///< Entry params copied from the declaration.
  int64_t dest = -1;                 ///< Index into params, or -1 if absent.
  int retScalar = 0;
  std::string constraints;           ///< Semicolon-joined a:d=b:e constraints.
  std::vector<std::string> dtypes;   ///< Per-tensor surface dtype; empty means all f32.
  // Fuse entries only: kernel identity is generated MLIR text FNV-1a, not reconstructible from
  // declarations.
  std::optional<uint64_t> explicitSig;

  std::vector<std::string> tensors() const;
  int nscalar() const;
  // Number of tensors pushed. Generated destination-passing kernels push all; foreign main(x)->y
  // normally pushes one fewer, with final tensor storing the result.
  std::optional<int> explicitNin;
  int nin() const {
    return explicitNin ? *explicitNin : static_cast<int>(tensors().size());
  }
  int tensorDest() const;
  std::string ranks() const;
  std::string dtypeCodes() const;
  uint64_t sig() const;
};

// Build entries from declaration/body. reduction: :fixed_tree creates <name>__ft_pre and
// <name>__ft_step. Each tree level is a dispatch; N determines level count, but addition order is
// device-independent, the entire guarantee of this mode.
std::vector<Entry> buildEntries(const TensorDecl &decl, const TensorBody &body);

// One tensor_extern becomes one row, no MLIR output. Generate only table row and .gen.rb dispatch
// so foreign entries follow the same Ruby calling discipline.
Entry buildExternEntry(const TensorExtern &x);

// Append tensor_extern dispatch to .gen.rb. Unlike generated kernels, push arguments only; the last
// tensor is result storage.
std::string externDispatch(const std::vector<TensorExtern> &externs);

// Complete sp_tensor_table.h, matching frozen output through the final newline.
std::string tableHeader(llvm::StringRef sourceName,
                        const std::vector<Entry> &entries);

// Complete <name>.gen.rb; decls/bodies share order. entriesPerDecl holds each declaration entries
// (two for fixed_tree). Nonempty fuseDispatch inserts the two explanatory lines and body just after
// the header, preserving header/fuse/extern/tensor_def order.
std::string generatedRuby(llvm::StringRef sourceName,
                          const std::vector<TensorDecl> &decls,
                          const std::vector<TensorBody> &bodies,
                          const std::vector<std::vector<Entry>> &entriesPerDecl,
                          llvm::StringRef fuseSourceName = {},
                          llvm::StringRef fuseDispatch = {});

} // namespace spinel_mlir::tensor
#endif // SPINEL_MLIR_TENSOR_EMIT_H
