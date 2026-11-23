//===- Input.h - obtain a contract for one source, once ----------*- C++ -*-===//
//
// Both core tools need the same thing: run the contract reader over one source
// and hand back a ContractModule, refusing if the source changed underneath.
// That check is the reason this is shared rather than copied -- two copies of a
// snapshot guard are two places for it to drift, and a drifted snapshot guard
// is indistinguishable from no snapshot guard.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_INPUT_H
#define SPINEL_MLIR_CORE_INPUT_H

#include "spinel-mlir/Contract/Model.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include <memory>
#include <string>

namespace spinel_mlir::core {

/// Runs `reader` over `source` four times and builds the module. Returns null
/// after reporting through `diag`.
///
/// The source is read before, between and after the reader runs, and any change
/// is a refusal: the four faces must describe ONE source, and a file edited
/// mid-run would otherwise produce a contract describing no version of it.
/// When `inputsOut` is non-empty, the reader is asked to record the files it
/// actually opened there, and the run fails if it cannot. The ledger describes
/// THIS analysis; one taken from a separate run describes that run instead.
///
/// With `withPrelude` (decision 0042 stage 4: `--core`, never the status
/// lane), the reader reads a copy of the source with the definitions of the
/// intrinsics it names placed before the program (Core/Prelude.h), so that a
/// call to one has a type; the prelude's nodes are dropped from the module,
/// the source's are moved back to their own lines, and its file names
/// are the source's. A source that names no intrinsic is read itself. The
/// copy is written in a temporary directory, or beside the source when the
/// source spells `require_relative`, which the parser resolves from the
/// directory of the file it reads; each face's ledger must name the copy,
/// and the ledger handed to the caller names the source.
///
/// `keepMethods` names the methods the caller will lower from outside the
/// program text (its roots): the reader keeps them in the analysis even when
/// nothing in the program calls them, where Spinel would otherwise leave an
/// unnamed method out.
std::unique_ptr<contract::ContractModule>
loadContract(llvm::StringRef source, llvm::StringRef reader,
             llvm::function_ref<void(llvm::StringRef)> diag,
             llvm::StringRef inputsOut = {}, unsigned integerBits = 64,
             bool withPrelude = false,
             llvm::ArrayRef<std::string> keepMethods = {});

/// The reader beside this executable, or empty if there is none.
std::string defaultContractReader(const char *argv0, void *anchor);

} // namespace spinel_mlir::core
#endif
