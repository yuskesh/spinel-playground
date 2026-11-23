// Freestanding refusals use two closed enums. This preserves the claim that
// frozen Python and native refuse at the same stage/category: a string typo
// must not masquerade as a new category. Extending an enum exposes every switch.
// Stages follow the frozen execution order:
// P1 profile YAML sections/keys/ranges (FsProfile.__init__);
// P2 platform.externs entries (its externs loop);
// D1 freestanding_def (collect_fs_decls); D2 declaration/def matching (generator);
// B body use and buffer direction; C platform extern call sites.
// G inspects generated objects. It was absent at the initial checkpoint, which
// did not generate objects, and was added with in-process UndefGate.cpp.
// ABI/extern checking was not yet native there; those lanes were reserved
// for the later corpus gate.
#ifndef SPINEL_MLIR_FREESTANDING_DIAGNOSTICS_H
#define SPINEL_MLIR_FREESTANDING_DIAGNOSTICS_H

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <string>

namespace spinel_mlir::freestanding {

// P0 resolves a profile through the platform ledger, distinct from P1 checking
// the YAML already read. G checks generated objects' undefined-symbol policy,
// distinct from P1/P2 input declarations and B/C body-subset validation.
enum class Stage { P0, P1, P2, D1, D2, B, C, G };

// The initial ten contract categories. Keep BadBoundaryType and BadExternType
// separate: boundary declarations admit nine scalar types, externs five.
// For example :i8 is valid in freestanding_def but not platform.externs; merging
// the categories could conceal a refusal on the side that should accept it.
enum class Category {
  UnknownProfileKey,
  AbiWidthMismatch,
  BadBoundaryType,
  BadExternType,
  BufferDirectionViolation,
  BufferLenGovernance,
  BufferElemMismatch,
  ExternSignatureMismatch,
  UndeclaredPlatformExtern,
  UndefAllowlistViolation,
  BadExportSymbol,
  // A helper is reachable from roots with incompatible overflow policies.
  // Stage D2 matches declaration to body; preserve frozen Generator.want wording.
  OverflowPolicyConflict,
  // Platform-first resolution failed: unknown platform, wrong architecture, invalid supplies or
  // missing base. Stage P0.
  ProfileError,
  // A top-level reopening of a builtin class the declared methods' operators
  // belong to (docs/core/lowering-inputs.md, defect (ii)). Stage D1.
  ReopenedBuiltin,
  // A required file that does not parse on its own: a definition, block or
  // `end` crosses into the file that requires it (docs/core/lowering-inputs.md,
  // section 5). Stage D1.
  SplitAcrossFiles,
  /// Decision 0042 stage 4: the CORE checkers' spellings.
  ConflictingIntrinsic,
  UnsupportedIntrinsicCall,
};

llvm::StringRef stageName(Stage stage);
llvm::StringRef categoryName(Category category);

// One refusal. subject names an extern, declaration or profile key, but may be
// empty: frozen Python omits the subject for an extern unknown-key diagnostic.
// The 2026-08-31 decision preserves that omission, since adding a name would
// break the A/B subject-symbol comparison. argPos is one-based, or 0 if absent.
struct Rejection {
  Stage stage;
  Category category;
  std::string subject;
  int argPos = 0;
  std::string detail;
};

using FsDiagnosticFn = llvm::function_ref<void(const Rejection &)>;

// One line: spinel-fs:<stage>: <category>: <subject|-> [arg=<n> ]<detail>.
// The A/B runner reads this spelling verbatim.
std::string formatRejection(const Rejection &rejection);

// mlirgen-route spelling only: frozen Python reports
// spinel-mlirgen: unsupported: <detail>, so spinel-fs-emit uses this formatter.
// Do not change formatRejection: spinel-fs-check and spinel-fs-grad also use it,
// matching frozen undef-check.py / abi-check.py across eight recorded invocation
// forms. Changing their shared formatter would silently break that comparison.
// Category remains a field of Rejection.
std::string formatRejectionMlirgen(const Rejection &rejection);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_DIAGNOSTICS_H
