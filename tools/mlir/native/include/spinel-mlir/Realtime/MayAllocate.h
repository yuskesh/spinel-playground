// Allocation-reachability fixed point, matching frozen spinel_alloc_free.py
// without changing semantics, order or wording: identical inputs must yield
// the same four output faces. Python parses linked .ll text; native uses LLVM
// APIs but observes the same facts: instruction-order calls, CFG successors,
// reverse return reachability and an operand scan reproducing the textual
// address-taken overapproximation. Function::hasAddressTaken() is too narrow.
#ifndef SPINEL_MLIR_REALTIME_MAYALLOCATE_H
#define SPINEL_MLIR_REALTIME_MAYALLOCATE_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Module.h"

#include <map>
#include <set>
#include <string>
#include <vector>

namespace spinel_mlir::realtime {

// llvm-link renames colliding internal symbols to foo.1867; strip that suffix for seed matching but
// retain the full name in reports.
std::string basename(llvm::StringRef fn);

// One call; an empty callee denotes an indirect function-pointer call.
struct CallSite {
  std::string callee;            ///< Empty means indirect.
  const llvm::BasicBlock *block = nullptr;
  const llvm::DILocation *dbg = nullptr;
};

// One defined function in the module.
struct FuncInfo {
  std::string name;
  const llvm::Function *fn = nullptr;
  std::vector<CallSite> calls;
  std::set<const llvm::BasicBlock *> retReach; ///< Blocks that can reach ret.
};

// Parsed linked module: call graph and debug locations.
class ModuleModel {
public:
  explicit ModuleModel(const llvm::Module &m);

  const std::map<std::string, FuncInfo> &funcs() const { return funcs_; }
  const std::set<std::string> &declared() const { return declared_; }
  const std::set<std::string> &addrTaken() const { return addrTaken_; }
  const FuncInfo *func(llvm::StringRef n) const {
    auto it = funcs_.find(n.str());
    return it == funcs_.end() ? nullptr : &it->second;
  }

  // Resolve !dbg through the scope chain to DIFile, such as doom/lib/doom/game.rb:912. Generated C
  // uses #line to name Ruby source; empty if debug info is absent.
  std::string where(const llvm::DILocation *dbg) const;
  // File containing the Ruby method represented by this function, or empty.
  std::string declaredAt(llvm::StringRef name) const;
  bool isRuby(llvm::StringRef name) const;

private:
  std::map<std::string, FuncInfo> funcs_;
  std::set<std::string> declared_;
  std::set<std::string> addrTaken_;
  mutable std::map<std::string, bool> rubyCache_;
};

enum class Indirect { Conservative, AddressTaken };

// Two may_allocate strengths: any includes every path, including raise followed
// by unreachable; it is the default and the only proof. normal considers only
// blocks that can reach ret and is reported alongside it, not as a proof.
class Analysis {
public:
  Analysis(const ModuleModel &m, llvm::ArrayRef<llvm::StringRef> seeds,
           Indirect indirect);

  bool any(llvm::StringRef f) const { return lookup(any_, f); }
  bool normal(llvm::StringRef f) const { return lookup(normal_, f); }
  bool table(llvm::StringRef f, bool normalMode) const {
    return normalMode ? normal(f) : any(f);
  }
  const std::set<std::string> &externalUnknown() const { return externalUnknown_; }

  // One witness-path hop: function name and incoming call debug location.
  using Hop = std::pair<std::string, const llvm::DILocation *>;
  // Terminal cause (kind, what) to its shortest witness path.
  using Causes = std::map<std::pair<std::string, std::string>, std::vector<Hop>>;
  Causes witness(llvm::StringRef entry, bool normalMode) const;

  // Editable frontier: edges from Ruby-defined functions into runtime code.
  struct Site {
    std::string where, caller, callee, kind;
    bool operator<(const Site &o) const {
      return std::tie(where, caller, callee, kind) <
             std::tie(o.where, o.caller, o.callee, o.kind);
    }
  };
  std::vector<Site> boundarySites(llvm::StringRef entry, bool normalMode) const;

  // All entry-reachable functions: the proof domain.
  std::set<std::string> region(llvm::StringRef entry, bool normalMode) const;

  // setjmp calls in the domain; --allow-abort is unsound if this is nonempty.
  struct SetjmpHit { std::string caller, callee; const llvm::DILocation *dbg; };
  std::vector<SetjmpHit> setjmpIn(const std::set<std::string> &region) const;

private:
  bool lookup(const std::map<std::string, bool> &t, llvm::StringRef f) const {
    auto it = t.find(f.str());
    return it == t.end() ? true : it->second; // Assume the worst for unknown names.
  }
  // Value for a name without a body; nullopt when a definition exists.
  std::optional<bool> leaf(llvm::StringRef name);
  void solve();

  const ModuleModel &mod_;
  std::set<std::string> seeds_;
  Indirect indirect_;
  std::map<std::string, bool> any_, normal_;
  std::set<std::string> externalUnknown_;
  std::vector<std::string> indTargets_;
  bool hasIndTargets_ = false;
};

/// Vocabulary from the generated header.
llvm::ArrayRef<llvm::StringRef> seedsAlloc();
llvm::ArrayRef<llvm::StringRef> seedsPause();
llvm::ArrayRef<llvm::StringRef> setjmpNames();
// Whether an undefined name is allowlisted as nonallocating.
bool onAllowlist(llvm::StringRef base);
// Allocation reason for reporting.
llvm::StringRef allocReason(llvm::StringRef name);

} // namespace spinel_mlir::realtime

#endif // SPINEL_MLIR_REALTIME_MAYALLOCATE_H
