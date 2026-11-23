// Public reader entry for constructing ContractModule from four saved typedump
// buffers. It accepts bytes only and never launches the producer; Ruby-source
// product wiring belongs to the importer. Unknown record tags/header columns,
// duplicates, omissions and dangling references are refused, not defaulted.
// Diagnostics use <face>:<line>: <category>: <detail>; face-wide omissions
// (such as missing ROOT) use line 0. All diagnostics go to ContractDiagnosticFn.
// Failure returns nullptr without exposing a partial model. printCanonical is
// a test-only dump, not a new frontend protocol; minimal.canonical and
// canonical.test define it. Implementation lives in lib/Contract. Historically,
// the initial declaration-only checkpoint left lit tests failing because the
// tool was not yet implemented.
#ifndef SPINEL_MLIR_CONTRACT_READER_H
#define SPINEL_MLIR_CONTRACT_READER_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <memory>

namespace llvm {
class raw_ostream;
} // namespace llvm

namespace spinel_mlir::contract {

// Four spinel-typedump faces. References to caller-owned buffers; the reader
// does not own them. The module copies the strings it needs.
struct ContractInputs {
  llvm::StringRef ast;
  llvm::StringRef nodes;
  llvm::StringRef locals;
  llvm::StringRef methods;
  /// Decision 0042 stage 4: the first line of the entry file at which an
  /// inserted prelude starts (tools/core/hosted-prelude.rb), or 0 for none,
  /// and its number of lines (Core/Prelude.h, insertPrelude). Every node of
  /// the entry file on those lines, the methods and locals of their scopes,
  /// and their ids in any array are dropped before the cross-face checks,
  /// but the program node and its statements node, which take the position
  /// of the first statement left. Every entry-file node after the prelude
  /// moves `preludeLines` up, in both faces, so the module describes the
  /// source alone at its own lines; a reference left pointing into the
  /// prelude is a dangling reference.
  int64_t preludeLine = 0;
  int64_t preludeLines = 0;
  /// Columns to add back on the source's first program line when that is
  /// its line 1 behind a UTF-8 byte order mark (Core/Prelude.h,
  /// PreludeCopy::firstColumns): the mark stays first in the copy, and the
  /// parser counts it in line 1's columns.
  int64_t preludeColumns = 0;
  /// Decision 0045: the text the buffer rewrite inserted, in the source's
  /// lines and columns, ordered by position (Model.h, ColumnInsert). Applied
  /// after the prelude is dropped: a node of the entry file that starts
  /// after an insertion on its line moves back by its length, and one that
  /// starts inside inserted text takes the insertion's own column.
  std::vector<ColumnInsert> columnInserts;
};

// One diagnostic line: <face>:<line>: <category>: <detail>.
// Required categories fixed by invalid.test:
// unknown-record-tag / duplicate-node / missing-root / dangling-reference /
// duplicate-local-slot / malformed-method-params.
// Add categories together with invalid.test / ReaderTest coverage, never alone.
// ContractDiagnosticFn differs in type and purpose from the foundation's
// spinel_mlir::DiagnosticFn (Support/Diagnostics.h, severity/message callback
// for MLIR diagnostics). Distinct names avoid ambiguous unqualified lookup in
// consumers using both namespaces. Adapt contract strings to that callback
// at the CLI or C ABI boundary.
using ContractDiagnosticFn = llvm::function_ref<void(llvm::StringRef)>;

// Parse all four faces; return a sealed module only after cross-table checks.
// On failure, report the first inconsistency through diag and return nullptr;
// there is no automatic fallback.
std::unique_ptr<ContractModule> readContract(const ContractInputs &inputs,
                                             ContractDiagnosticFn diag);

// Test-only canonical dump; preserves fields and normalizes source/id/slot order
// for differential checking. minimal.canonical defines the format.
void printCanonical(const ContractModule &module, llvm::raw_ostream &os);

} // namespace spinel_mlir::contract

#endif // SPINEL_MLIR_CONTRACT_READER_H
