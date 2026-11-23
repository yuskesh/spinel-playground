// Freestanding gradient declarations and gate 1. Native counterparts of frozen
// spinel-gradfs read_grad_decls/read_params/gate1, preserving all semantics and
// g01..g12 codes/messages. Only the tool prefix changes from spinel-gradfs: to
// spinel-fs-grad:. Read the ContractModule AST face; do not parse Ruby natively.
#ifndef SPINEL_MLIR_FREESTANDING_GRADDECLARATION_H
#define SPINEL_MLIR_FREESTANDING_GRADDECLARATION_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Freestanding/Declaration.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"

#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

/// `freestanding_grad_def :name, wrt: …, mode: …, tol: …, export: …, hvp: …`
struct FsGradDecl {
  std::string name;
  std::vector<std::string> wrt;
  std::string mode = "reverse";
  double tol = 1e-6;
  std::string exportSymbol;
  bool hvp = false;
  int64_t line = 0;

  // Gradient symbol; export: overrides only this one.
  std::string sym() const {
    return exportSymbol.empty() ? ("spinel_grad_" + name) : exportSymbol;
  }
  // Hessian-vector product symbol, always spinel_hvp_<name> independent of export:, matching the
  // profile extern spelling as in frozen Python.
  std::string hvpSym() const { return "spinel_hvp_" + name; }
};

// One gate-1 refusal, also one rejects.tsv row.
struct GradReject {
  std::string target;
  int64_t line = 0;
  std::string code;    ///< g01..g12
  std::string message; ///< Frozen Python wording verbatim
};

// Read only the freestanding_def fields gate 1 needs: name/params/returns/export.
// Do not call readFreestandingDeclarations here: frozen G1-fs runs immediately
// after --dump-ast, leaving def matching to the generator. Otherwise a missing
// def yields D2 instead of g10 for the same input. The library checks the match
// when building kern.ll later. Read failure returns nullopt and error,
// equivalent to frozen ValueError.
std::optional<std::vector<FsDecl>>
readGradBoundaryDeclarations(const contract::ContractModule &module,
                             std::string &error);

// Read freestanding_grad_def in declaration order from the AST. nullopt means
// read failure (frozen ValueError), with one line in error. Duplicate declaration
// g08 is instead a Reject during reading: append to rejects and return nullopt,
// preserving the frozen ordering.
std::optional<std::vector<FsGradDecl>>
readFreestandingGradDeclarations(const contract::ContractModule &module,
                                 std::vector<GradReject> &rejects,
                                 std::string &error);

// Ruby def parameter names in declaration order; nullopt if no matching def exists, as gate-1 g10
// requires.
std::optional<std::vector<std::string>>
readDefParameterNames(const contract::ContractModule &module,
                      llvm::StringRef name);

// Gate G1-fs preserves frozen check order:
// g01, g05, g02, g09, g07, g10, g11, g06, g04/g03, g12.
// Return true on acceptance; otherwise fill out and return false. fs is the
// matching freestanding_def or nullptr; pnames are def arguments or nullptr.
bool checkGradGate1(const FsGradDecl &g, const FsDecl *fs,
                    const std::vector<std::string> *pnames, GradReject &out);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_GRADDECLARATION_H
