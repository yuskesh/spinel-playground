// Check freestanding_def declarations and bodies. Classify refusals at D1
// (declaration), D2 (matching def), B (body use) and C (extern call). Input is
// the sealed four-face ContractModule, as for the scalar importer; native code
// does not parse Ruby. Do not rely on inferred types: kernels uncalled in the
// initial corpus have unknown node types. Boundary scalar/buffer and numeric
// types come from freestanding_def, since the declaration is the contract.
#ifndef SPINEL_MLIR_FREESTANDING_DECLARATION_H
#define SPINEL_MLIR_FREESTANDING_DECLARATION_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Freestanding/Profile.h"

#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

struct FsDecl {
  std::string name;
  std::string exportSymbol;
  std::string returns;
  std::string overflow; ///< Profile default or declaration override.
  std::string bounds;   ///< trap (default) / unchecked
  std::vector<FsParam> params;
  int64_t line = 0;
};

// Stages D1/D2: collect declarations and match def bodies; any refusal returns
// nullopt. Zero declarations is also refused: --freestanding compiles declared
// boundaries rather than selecting arbitrary methods from the file.
std::optional<std::vector<FsDecl>>
readFreestandingDeclarations(const contract::ContractModule &module,
                             const FreestandingProfile &profile,
                             FsDiagnosticFn diag);

// Stages B/C: walk declared kernels for stores to :in buffers and platform
// extern calls. Decision 0042 stage 4 also checks CORE intrinsic calls and
// top-level definitions of intrinsic names. integerBits is the body width
// (0 means the profile width), deciding whether 64-bit forms are refused.
bool checkFreestandingBodies(const contract::ContractModule &module,
                             const FreestandingProfile &profile,
                             llvm::ArrayRef<FsDecl> decls,
                             FsDiagnosticFn diag, unsigned integerBits = 0);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_DECLARATION_H
