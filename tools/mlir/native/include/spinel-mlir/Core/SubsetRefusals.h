//===- SubsetRefusals.h - the source constructs the subsets refuse ---------===//
//
// Decision 0026 step 5: one source-level owner for "does this construct
// allocate". The table lists the Prism node kinds and call names the
// freestanding subset refuses, each with the reason its refusal gives, and
// marks the node kinds the CORE checker refuses as heap operations
// (Eligibility.cpp). Only those are what CORE calls allocation; the other
// rows are refusals for other reasons, hence the name.
//
// Data only: it depends on nothing but the standard library, so the
// freestanding routes read it without linking the checker. Whether
// allocation is allowed at all is target policy (FreestandingProfile).
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_SUBSETREFUSALS_H
#define SPINEL_MLIR_CORE_SUBSETREFUSALS_H

#include <map>
#include <string>

namespace spinel_mlir::core {

/// How the CORE checker treats a refused node kind: as a heap operation, or
/// by a rule of its own (runtime state, an unsupported node, ...).
enum class CoreRule { HeapOperation, Refusal };

struct NodeRefusal {
  CoreRule core;
  std::string reason;
};

/// The refused node kinds and call names that a fixture shows
/// (tests/subset/coverage.tsv). The node kinds no input reaches stay in
/// lib/Frontend/Scalar/SubsetTables.cpp, the inherited list.
const std::map<std::string, NodeRefusal> &subsetRefusalNodes();
const std::map<std::string, std::string> &subsetRefusalCalls();

/// The CORE checker's heap operations: the node rows marked HeapOperation.
bool isHeapOperation(const std::string &kind);

} // namespace spinel_mlir::core
#endif
