//===- Adapter.h - the Full adapter generated for one contract ---*- C++ -*-===//
//
// Decision 0007 task 4.  Emits the C source of the Full-facing adapter for a
// validated contract: a registry of typed native storage, the seven operations
// the decision lists, and the invocation of that contract's CORE entry.
//
// What this is and is not:
//
//   * The adapter OWNS its allocations and a registry mapping positive,
//     monotonically issued IDs to them.  An ID is not an address and is never
//     reused while the process lives.
//   * It is not the CORE object.  Allocation and synchronisation live here, on
//     purpose: the zero-undefined-symbol gate applies to the CORE object, and
//     this file is what keeps malloc and pthread out of it.
//   * It is not a security boundary.  The registry stops a forged integer from
//     becoming an address; a caller that passes another LIVE id still reaches
//     that storage, and no unforgeable capability is promised.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_ADAPTER_H
#define SPINEL_MLIR_CORE_ADAPTER_H

#include "spinel-mlir/Core/Boundary.h"

namespace llvm {
class raw_ostream;
} // namespace llvm

namespace spinel_mlir::core {

/// The registry, which is SHARED by every adapter in a program.
///
/// Not one per contract. Ids are "never reused during the process lifetime",
/// and two registries would each issue a 1: a caller that handed one adapter's
/// id to another would name live storage in the wrong registry, and neither
/// could tell. One registry makes an id mean one thing everywhere, which is
/// what the decision says an id is.
void emitRegistryHeader(llvm::raw_ostream &os);
void emitRegistrySource(llvm::raw_ostream &os);

/// The C source of the adapter for `c`.  `headerName` is what the emitted file
/// includes for the CORE entry's declaration.
///
/// `failureSites` (a debugging aid) pairs the adapter with a kernel built with
/// --failure-sites: a failed call prints the entry's failure site to stderr.
/// The object such an adapter links against must define the site global.
void emitAdapterSource(const BoundaryContract &c, llvm::StringRef contractPath,
                       llvm::StringRef headerName, llvm::raw_ostream &os,
                       bool failureSites = false);

/// The generated Ruby module for this contract: the `ffi_func` declarations
/// and the wrappers over them.
///
/// `load` is a wrapper rather than a raw call because the C operation answers
/// with an encoded value OR a negative status, and the decode is per element
/// type. Nothing here is a second validation pass: the single call already
/// validated and read.
void emitAdapterRuby(const BoundaryContract &c, llvm::StringRef contractPath,
                     llvm::raw_ostream &os);

/// Its header: the operations a Full-side caller declares.
void emitAdapterHeader(const BoundaryContract &c, llvm::StringRef contractPath,
                       llvm::raw_ostream &os);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_ADAPTER_H
