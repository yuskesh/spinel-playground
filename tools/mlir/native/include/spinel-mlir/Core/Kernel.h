//===- Kernel.h - a checked scalar CORE kernel from a contract ---*- C++ -*-===//
//
// Decision 0007 task 2.  Takes the contract task 1 validated and the source it
// names, and produces ONE object defining `spinel_core_<entry>` with the
// status/result-pointer ABI the generated header declares.
//
// What this is and is not:
//
//   * It is not a second admissibility opinion.  Admission comes from
//     checkEligibility() in `CheckedScalar` mode, on the same analysed module
//     the contract was resolved against.
//   * It is not a second failure channel.  There is no raise, no trap hook and
//     no sentinel: a failing operation returns one of the boundary's own
//     status values, and the result is written only on success.
//   * It does not forward a predecessor trap code.  The freestanding lane's
//     codes and these share some numbers and mean different things; nothing
//     here reads one and translates it.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_KERNEL_H
#define SPINEL_MLIR_CORE_KERNEL_H

#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Eligibility.h"
#include "spinel-mlir/Core/Emit.h"

#include <string>
#include <vector>

namespace spinel_mlir::core {

struct CoreKernelRequest {
  std::string outputPath;              ///< the object to write
  std::string clangPath;               ///< resolved by the caller
  std::vector<std::string> clangArgs;  ///< target flags, from the caller
  /// When set, the MLIR module is also written here.  Diagnostic aid only.
  std::string emitMlirPath;
  /// When set, receives a copy of the eligibility report that admitted the
  /// entry, once the object has been written. Decision 0010's build report
  /// reads it; nothing in emission does, and it is copied only at the end.
  EligibilityReport *admitted = nullptr;
  /// When set, the object is emitted in two steps and THE IR CODE GENERATION
  /// CONSUMED is left here, for decision 0010's build report: the final call
  /// graph and the frame sizes are both read from it, so that an inlined call
  /// correctly has no frame and the two agree by construction rather than by
  /// being taken from artifacts that might not match.
  ///
  /// The object is unchanged by this: measured byte for byte on col, stepall
  /// and renderall (HostEmitRequest::optimisedIrPath carries the figures).
  /// The target's pointer width, 32 or 64. The descriptor check "base + size
  /// stays inside the address space" is asked in unsigned 64-bit arithmetic,
  /// so on a 32-bit target it must also refuse a limit above 2^32 - 1: there,
  /// base + size never wraps in i64, and an accepted range could leave the
  /// address space while every index stayed below the count (decision 0014,
  /// Task 2 audit, 2026-09-22). The host's width leaves the emission unchanged.
  unsigned pointerBits = 64;
  std::string optimisedIrPath;
  /// Decision 0014 §10: the verification lowering, which records every
  /// cross-context access through the recorder's two hooks.
  bool recordCross = false;
  /// A debugging aid, off when empty: each place a failure starts stores its
  /// site's id in `spinel_core_<entry>_failure_site` (an exported i32, zeroed
  /// by the wrapper on entry) before the status returns, and the sites are
  /// written here as a table. The status ABI and the result are unchanged,
  /// and so is the object when this is empty.
  std::string failureSitesPath;
};

/// The contract's declaration as facts about the source, in declaration
/// order. The kernel admits with these, and the build report analyses the
/// closure with the same ones.
EntryFacts entryFactsFor(const BoundaryContract &c);

/// Admission alone: the checker in the checked mode with the contract's facts,
/// and for an application entry (decision 0014) the rule that every loop in
/// its closure has a derived bound. Every refusal is reported through `diag`
/// and nullopt is returned; otherwise the report that admitted the entry, the
/// one the emission lowers from. `emitCoreKernel` calls this first, and the
/// kernel's `--admit-only` calls it alone.
std::optional<EligibilityReport> admitCoreKernel(const PreparedBoundary &prepared,
                                                 CoreDiagnosticFn diag);

/// Emits the kernel for `prepared`.  Reuses CoreEmitStatus: the four outcomes
/// are the same four, and a second enum with the same members would be a
/// second thing for a caller to switch on.
CoreEmitStatus emitCoreKernel(const PreparedBoundary &prepared,
                              const CoreKernelRequest &request,
                              RunToolFn runTool, TempPathFn tempPath,
                              CoreDiagnosticFn diag);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_KERNEL_H
