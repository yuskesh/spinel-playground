// Stage 1 refuses allocating syntax by name, matching frozen fs_subset_check. Called only for
// --freestanding; hosted check order is unchanged.
#ifndef SPINEL_MLIR_FRONTEND_SCALAR_FREESTANDINGSUBSET_H
#define SPINEL_MLIR_FRONTEND_SCALAR_FREESTANDINGSUBSET_H

#include "llvm/ADT/StringRef.h"

#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace spinel_mlir::contract { struct Node; }

namespace spinel_mlir::scalar {

struct ScalarRootDesc;

// Node id to node, or nullptr; borrow the ModuleGen-owned table.
using FsNodeLookup = std::function<const contract::Node *(int64_t)>;

// Reachable nodes in the same last-in-first-out order as frozen Ast.subtree.
std::vector<const contract::Node *> fsSubtree(const FsNodeLookup &lookup,
                                              const contract::Node &root);

/// node id -> the reader's type of that node ("" when it has none).
using FsTypeLookup = std::function<std::string(int64_t)>;

// Stage 1 returns the frozen Unsupported detail, or nullopt on acceptance.
// Decision 0042 stage 2: typeOf distinguishes Integer#<< shifts from refused
// heap appends. Decision 0044: lent names helper parameters holding caller-lent
// buffers, permitting indexing and walking as for declared buffers.
std::optional<std::string> fsSubsetCheck(const FsNodeLookup &lookup,
                                         const FsTypeLookup &typeOf,
                                         const contract::Node &def,
                                         llvm::StringRef name,
                                         const ScalarRootDesc *decl,
                                         const std::set<std::string> &lent = {});

/// The refused node kinds no input reaches, with their reasons (SubsetTables.cpp,
/// hand-maintained). The others, and the call names, are
/// core::subsetRefusalNodes() and core::subsetRefusalCalls().
const std::map<std::string, std::string> &fsInheritedNodes();

} // namespace spinel_mlir::scalar
#endif
