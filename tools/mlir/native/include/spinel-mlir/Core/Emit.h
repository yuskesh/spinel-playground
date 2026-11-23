//===- Emit.h - lower a checked core closure to an object ---------*- C++ -*-===//
//
// Decision 0005 task 4.  Turns the closure the eligibility checker admitted
// into one object file defining one symbol.
//
// What this is not: it is not a second selection or a second subset.  The
// closure comes from the scalar importer that the freestanding lane already
// uses, and the admission comes from checkEligibility().  Nothing here reads a
// declaration, and no synthetic caller is inserted to make inference succeed --
// the evidence has to be in the source the caller handed over.
//
// The emitted function's NAME is supplied by the caller, from the mapping the
// hosted compiler wrote.  It is not derived here.  Two derivations of one name
// are two chances to disagree, and this side must not be the second.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_EMIT_H
#define SPINEL_MLIR_CORE_EMIT_H

#include "spinel-mlir/Contract/Model.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <string>
#include <vector>

namespace llvm {
class raw_ostream;
} // namespace llvm

namespace spinel_mlir::core {

/// One selected root: the identity the checker admitted, and the symbol the
/// hosted compiler said its declaration will use.  Both come from the same
/// snapshot; this side never invents either.
struct CoreRootRequest {
  std::string identity;  ///< the resolved method identity, e.g. `lower`
  std::string symbol;    ///< the mapped symbol, e.g. `spc_<snapshot>_lower`
  /// The prototype the hosted side will DECLARE, copied from the mapping. This
  /// side lowers machine-width integers; if the hosted boundary is anything
  /// else the two disagree about the call, and the link does not notice --
  /// measured: under `--int-overflow=promote` inference boxes the boundary to
  /// `sp_RbVal`, the object stayed `i64`, and the program printed 0.
  std::string signature;
};

struct CoreEmitRequest {
  std::vector<CoreRootRequest> roots;
  std::string outputPath;              ///< the object to write
  std::string clangPath;               ///< resolved by the caller
  std::vector<std::string> clangArgs;  ///< target flags, from the caller
  /// When set, the MLIR module is also written here.  Diagnostic aid only; the
  /// object is the artifact.
  std::string emitMlirPath;
  /// When set, the C header of the core object's failure hook (decision 0015)
  /// is written here: its prototype and the numbers of its two arguments. The
  /// hosted program defines the hook against it.
  std::string headerPath;
  /// When set, the C source of the hosted shim that DEFINES that hook
  /// (decision 0015) is written here. It is compiled as its own translation
  /// unit, includes no runtime header, and calls the one runtime entry
  /// `sp_abort_uncaught`.
  std::string shimPath;
};

enum class CoreEmitStatus {
  Ok,
  /// The source is not admissible: eligibility refused it, or the closure holds
  /// something the subset cannot lower.  A build failure, not a tool failure.
  InputRejected,
  /// The request itself is malformed -- an empty symbol, a root the checker
  /// admitted but the selector could not find, and so on.
  BadRequest,
  /// Something outside the source failed: clang could not be run, a file could
  /// not be written.
  Infrastructure,
};

/// Subprocess launching and temporary paths belong to the CLI, as they do in
/// the scalar and freestanding lanes.  This library says what it wants to
/// happen and never spawns anything itself.
using RunToolFn = llvm::function_ref<int(
    llvm::StringRef tool, llvm::ArrayRef<llvm::StringRef> argv,
    llvm::StringRef stdoutPath, llvm::StringRef stderrPath)>;
using TempPathFn = llvm::function_ref<std::string(llvm::StringRef name)>;
using CoreDiagnosticFn = llvm::function_ref<void(llvm::StringRef)>;

/// Decision 0015: the C header of `scalar::kCoreFailHook`, generated from the
/// importer's own enums so the two cannot drift apart.
void emitCoreFailHeader(llvm::raw_ostream &os);

/// Decision 0015: the C source of the hosted shim that defines the hook. A
/// failure becomes an uncaught exception through the vendor's abort entry: the
/// at_exit hooks run, the uncaught text is printed, the uncaught status is the
/// exit status, and no rescue frame is consulted. Generated from the same enums
/// as the header.
void emitCoreFailShim(llvm::raw_ostream &os);

CoreEmitStatus emitCoreObject(const contract::ContractModule &module,
                              const CoreEmitRequest &request, RunToolFn runTool,
                              TempPathFn tempPath, CoreDiagnosticFn diag);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_EMIT_H
