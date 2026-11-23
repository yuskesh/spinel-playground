// Freestanding object generation. The compiler library owns semantics; the CLI
// owns only I/O and subprocess execution. Two-stage inference, target policy
// and pass pipelines live here and must not be reconstructed by the CLI.
#ifndef SPINEL_MLIR_FREESTANDING_EMIT_H
#define SPINEL_MLIR_FREESTANDING_EMIT_H

#include "spinel-mlir/Freestanding/Declaration.h"
#include "spinel-mlir/Freestanding/Diagnostics.h"
#include "spinel-mlir/Freestanding/Profile.h"

#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"

#include "mlir/IR/BuiltinOps.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/FunctionExtras.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/raw_ostream.h"

#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

// The CLI owns subprocess execution. The library requests operations with a closed argv list, never
// a shell string.
using RunToolFn = llvm::function_ref<int(
    llvm::StringRef tool, llvm::ArrayRef<llvm::StringRef> argv,
    llvm::StringRef stdoutPath, llvm::StringRef stderrPath)>;

// The CLI owns temporary names and their directory lifetime.
using TempPathFn = llvm::function_ref<std::string(llvm::StringRef name)>;

struct EmitRequest {
  std::string sourcePath;   ///< Original source, the canonical identity.
  std::string profilePath;
  std::string typedumpPath;
  /// spinel-fs-codegen, which turns the .ll into the object.
  std::string codegenPath;
  std::string objPath;      ///< Required.
  std::string llPath;       ///< Required.
  std::string headerPath;   ///< Required.
  std::string mlirPath;     ///< Optional module output with debug locations.
  // The product -o extension selects the artifact kind. Direct invocation takes
  // objPath/llPath/headerPath separately and always uses Obj; only product
  // invocation changes this field.
  enum class EmitKind { Mlir, Ll, Obj };
  EmitKind emitKind = EmitKind::Obj;
  // Repeatable --method / -m; empty means no declaration filtering.
  std::vector<std::string> methods;
  // --emit-undef-tsv writes only after object creation and a successful gate run.
  // Matches frozen if args.emit_undef_tsv and undef: no output for .mlir/.ll,
  // --no-undef-check, or a DENY that terminates execution.
  std::string undefTsvPath;
  // --no-undef-check skips the gate and its TSV output.
  bool noUndefCheck = false;
  // Platform ledger tools/platform/menus.yaml, needed only for platform-first
  // resolution. An empty path cannot resolve that form: the caller supplies the
  // locateDefaultLedger result. Legacy profiles never read it.
  std::string menusPath;
  /// Decision 0019's tools/core/int64-allow.tsv; empty: the repository's.
  std::string int64AllowPath;
  // Probe acceptance only: return Probed without writing bytes. Follow exactly
  // the emission path; there is no separate probe-only admission function.
  bool probe = false;
  // --admit continues into emission after acceptance, returning Emitted on
  // success rather than stopping at the probe point. Like probe it silences
  // InputRejected: rc 3 routes to frozen Python and is not a user-facing failure.
  // Do not combine with probe.
  bool admit = false;
};

// Four result categories. A bool cannot distinguish an out-of-subset input
// from infrastructure failure, so the CLI could not separate rc 3 from rc 1.
enum class EmitStatus {
  Emitted,        ///< Finished writing object / ll / header.
  Probed,         ///< Accepted request.probe without writing output.
  InputRejected,  ///< Input outside this backend subset; diagnostic already reported.
  Infrastructure, ///< Infrastructure: missing files / typedump / codegen / temporary files / writes.
};

// One call runs from stage 1 through object generation; the CLI handles only
// arguments, files and subprocesses. Failures go to structured diag or note
// for unstructured infrastructure issues. In probe mode, InputRejected is
// silent: rc 3 routes to frozen Python rather than reporting a user failure.
// Read a tier declaration only from comments in the first two source lines;
// a shebang consumes a slot. No declaration returns nullopt, malformed spelling
// returns an empty string for the caller to compare against core|arena|full.
// If line is nonnull, write the declaration's one-based line number.
std::optional<std::string> readDeclaredTier(llvm::StringRef sourceText,
                                            int *line = nullptr);

EmitStatus compileFreestanding(const EmitRequest &request, RunToolFn runTool,
                               TempPathFn tempPath, FsDiagnosticFn diag,
                               llvm::raw_ostream &note);

// Return the generated LLVM Module without writing an object or .ll file.
// Grad uses the same in-process path as compileFreestanding and returns just
// after translateModuleToLLVMIR, rather than spawning spinel-mlirgen. The same
// profile produces the same data layout, structurally avoiding a shim mismatch;
// the caller still keeps frozen Python's checks. objPath/llPath/headerPath are
// ignored. A null result sets status to InputRejected (subset) or Infrastructure.
std::unique_ptr<llvm::Module>
emitFreestandingModule(const EmitRequest &request, llvm::LLVMContext &context,
                       RunToolFn runTool, TempPathFn tempPath,
                       FsDiagnosticFn diag, llvm::raw_ostream &note,
                       EmitStatus &status);

// Internal library interfaces exposed for direct control checks.

// Check exports against every generated symbol: declaration-derived names,
// existing importer symbols including reachable helpers, and reserved names
// for future trap hooks. Also check that boundary types have C spellings.
// This previously happened only in writeBoundaryHeader after opening the file,
// so a successful probe could still refuse after opening output. Check before
// probing; keep the header writer's check as defense for standalone callers.
bool checkExportSymbols(mlir::ModuleOp module, const FreestandingProfile &profile,
                        llvm::ArrayRef<FsDecl> decls, FsDiagnosticFn diag);

bool addBoundaryWrappers(mlir::ModuleOp module, const FreestandingProfile &profile,
                         llvm::ArrayRef<FsDecl> decls, llvm::StringRef dataLayout,
                         FsDiagnosticFn diag);

bool writeBoundaryHeader(llvm::raw_ostream &os, llvm::StringRef sourceName,
                         llvm::StringRef profileName,
                         const FreestandingProfile &profile,
                         llvm::ArrayRef<FsDecl> decls, FsDiagnosticFn diag);

} // namespace spinel_mlir::freestanding
#endif
