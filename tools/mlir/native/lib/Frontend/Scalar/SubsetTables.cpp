//===- SubsetTables.cpp - freestanding subset: the inherited refusals -----===//
//
// Hand-maintained. fsInheritedNodes() lists the Prism node kinds the
// freestanding subset refuses although no input reaches them
// (tests/subset/coverage.tsv marks each unverified-inherited, with the
// reason). They stay in force, named, not removed. Every other refusal, and
// every call name, is in lib/Core/SubsetRefusals.cpp (decision 0026 step 5);
// fsSubsetCheck (FreestandingSubset.cpp) reads that table first, then this one.
//
// Origin: the entries came from FS_ALLOC_NODES and FS_ALLOC_CALLS in
// spinel-llvm's frozen Python generator (tools/mlir/spinel-mlirgen.py), copied
// by its docs/experiments/results/E175/mk_fs_tables.rb, and arrived here with
// the native core slice (docs/provenance.md). Neither is in this repository.
// Since decision 0026 step 1 the table is this project's code;
// ConstantPathNode's reason was changed in 60a67f1 (0014 D5), before it moved
// to SubsetRefusals.cpp.
//
// tests/subset-tables/check.rb pins the key sets and a digest of the reasons
// of both files in tests/subset-tables/pin.tsv: change the pin in the same
// commit.
//
//===----------------------------------------------------------------------===//

#include "FreestandingSubset.h"

namespace spinel_mlir::scalar {
const std::map<std::string, std::string> &fsInheritedNodes() {
  static const std::map<std::string, std::string> t = {
      {"ClassNode",
       "a `class` definition"},
      {"ModuleNode",
       "a `module` definition"},
      {"IndexNode",
       "an index expression (`a[i]`) -- indexable objects are heap objects"},
      {"ConstantWriteNode",
       "a constant assignment"},
      {"RescueNode",
       "a `rescue`"},
      {"EnsureNode",
       "an `ensure`"},
  };
  return t;
}

} // namespace spinel_mlir::scalar
