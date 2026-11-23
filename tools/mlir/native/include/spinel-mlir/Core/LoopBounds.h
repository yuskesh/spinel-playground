//===- LoopBounds.h - loop and work bounds of an admitted CORE entry -*- C++ -*-===//
//
// Decision 0010, step 1: derive and REPORT. Nothing here refuses anything, and
// nothing here reaches code generation.
//
// The analysis runs over the same analysed source the eligibility checker
// walked, and only over a closure the checker has already admitted. It reads
// the admitted report and the entry facts and changes neither: admission is
// the checker's, and an observation that could move it would not be one.
//
// Every loop in the closure is classified once, in the terms of its own
// method: a bound over that method's parameters and constants when the rules
// of 0010 establish one, or a reason code when they do not. The entry's work
// bound is then composed by expanding the acyclic call graph from the entry,
// substituting each call's arguments into its callee's bounds and multiplying
// by the bounds of the loops around the call.
//
// Bounds are expressions over mathematical integers, not over i64: checked
// arithmetic already refuses an induction variable that would wrap, and the
// value of an expression is a count, not a machine word. The grammar is
// documented in docs/core/core-report.md.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_LOOPBOUNDS_H
#define SPINEL_MLIR_CORE_LOOPBOUNDS_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Core/Eligibility.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::core {

/// The rendering version that prefixes the digested header text. A change to
/// the canonical rendering must bump it, so that a contract written against the
/// old rendering is stale on purpose rather than by accident.
inline constexpr unsigned kLoopDigestVersion = 1;

/// Which conjunct of `A && B && ...` supplied the bound.
struct LoopConjunct {
  unsigned index = 0;     ///< 0-based, in source order
  std::string rendering;  ///< canonical rendering of that conjunct
};

/// One loop of the closure, classified in its own method's terms.
struct LoopFinding {
  std::string method;
  unsigned ordinal = 0;   ///< source order within the method, from 0
  std::string id;         ///< `method#ordinal`
  std::string header;     ///< `while <canonical predicate rendering>`
  std::string digest;     ///< sha256 of `v<version>:<header>`
  std::string parent;     ///< enclosing loop in the same method, or empty
  int64_t line = 0, column = 0;
  bool pass = false;
  std::string reason;     ///< empty when `pass`
  std::string detail;     ///< human text; for some reasons a leading token
  std::optional<LoopConjunct> conjunct;
  std::string bound;      ///< iterations over the method's parameters, when `pass`
};

/// One occurrence of a loop in the call-expanded entry.
struct WorkTerm {
  std::string loop;                  ///< the loop's id
  /// From the entry inward: `loop:<id>` for each enclosing loop and
  /// `call:<method>@<line>:<col>` for each call on the way. The loop itself is
  /// not repeated here.
  std::vector<std::string> context;
  std::string iterations;            ///< over entry parameters; empty when unknown
  std::string reason;                ///< empty when known
  std::string detail;
};

/// Decision 0014: one extern call site in the call-expanded entry, with the
/// number of times it runs per invocation -- the product of the enclosing
/// derived bounds, composed through the helpers on the way. Both arms of a
/// conditional count.
struct ExternTerm {
  size_t externIndex = 0;           ///< into EntryFacts::externs
  std::vector<std::string> context; ///< as WorkTerm::context, ending `extern:<M.fn>@<line>:<col>`
  std::string calls;                ///< over entry parameters; empty when unknown
  std::string reason;               ///< empty when known
  std::string detail;
};

/// Decision 0014: an extern's total call count per invocation, the sum over
/// its sites. `derived` is false when any site's multiplicity is unknown or
/// the expansion stopped; then `calls` is empty and `reason` says why.
struct ExternCount {
  size_t externIndex = 0;
  std::string calls;
  bool derived = false;
  std::string reason;
  size_t sites = 0;
};

struct LoopBoundResult {
  /// Methods in the admitted closure's order, loops by ordinal within each.
  std::vector<LoopFinding> loops;
  std::vector<WorkTerm> terms;
  /// Decision 0014: extern call sites and per-extern totals, in the order of
  /// the entry facts' externs. Empty for a version 1 entry.
  std::vector<ExternTerm> externTerms;
  std::vector<ExternCount> externCounts;
  bool workKnown = true;
  /// Sum of every term's iterations when `workKnown`; `0` with no loop.
  std::string work;
  /// Empty, or the limit the analysis met: `too-many-terms` when the
  /// expansion stopped, `expression-too-large` when the sum grew past what a
  /// report holds. Either one makes the work bound unknown.
  std::string limit;
};

/// `admitted` must be a report for which `checked()` holds, produced from
/// `module` with `facts`.
LoopBoundResult deriveLoopBounds(const contract::ContractModule &module,
                                 const EligibilityReport &admitted,
                                 const EntryFacts &facts);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_LOOPBOUNDS_H
