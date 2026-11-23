// Allocation-reachability fixed point.
#include "spinel-mlir/Realtime/MayAllocate.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Support/Regex.h"

#include <deque>
#include <optional>

using namespace llvm;

namespace spinel_mlir::realtime {
namespace {
#include "spinel-mlir/Realtime/AllocVocabulary.inc"

// Strip text name prefixes \01 and quotes, matching frozen _clean.
std::string clean(StringRef n) {
  std::string out;
  for (char c : n)
    if (c != '"' && c != '\01')
      out += c;
  return out;
}

// Collect global names appearing in constants. Frozen addr_taken textually overapproximates every
// @name outside call-callee position, including global variables counted by -v.
// Function::hasAddressTaken is too narrow and omits globals.
void collectGlobals(const Constant *c, std::set<std::string> &out,
                    std::set<const Constant *> &seen) {
  if (!c || !seen.insert(c).second)
    return;
  if (const auto *g = dyn_cast<GlobalValue>(c))
    if (!g->getName().empty()) // The printer numbers anonymous globals as @0.
      out.insert(clean(g->getName()));
  for (const Use &u : c->operands())
    if (const auto *sub = dyn_cast<Constant>(u.get()))
      collectGlobals(sub, out, seen);
}

} // namespace

ArrayRef<StringRef> seedsAlloc() { return kVocabAlloc; }
ArrayRef<StringRef> seedsPause() { return kVocabPause; }
ArrayRef<StringRef> setjmpNames() { return kVocabSetjmp; }

bool onAllowlist(StringRef base) {
  for (StringRef p : kVocabAllowPrefix)
    if (base.starts_with(p))
      return true;
  if (llvm::is_contained(kVocabAllow, base))
    return true;
  // The frozen allowlist [a-z]+f suffix intends libm float variants but also matches printf-family
  // names. Preserve this known hole for byte parity; repair belongs to separate work.
  for (StringRef r : kVocabAllowRegex) {
    Regex re(("^(" + r + ")$").str());
    if (re.match(base))
      return true;
  }
  return false;
}

StringRef allocReason(StringRef name) {
  for (const auto &kv : kVocabAllocReason)
    if (kv.name == name && kv.reason != "-")
      return kv.reason;
  return "allocator";
}

std::string basename(StringRef fn) {
  if (fn.starts_with("llvm."))
    return fn.str();
  size_t i = fn.rfind('.');
  if (i != StringRef::npos && i > 0) {
    StringRef tail = fn.substr(i + 1);
    if (!tail.empty() && llvm::all_of(tail, [](char c) { return c >= '0' && c <= '9'; }))
      return fn.substr(0, i).str();
  }
  return fn.str();
}

ModuleModel::ModuleModel(const Module &m) {
  // Definitions and declarations.
  for (const Function &f : m) {
    std::string n = clean(f.getName());
    if (f.isDeclaration()) {
      declared_.insert(n);
      continue;
    }
    FuncInfo info;
    info.name = n;
    info.fn = &f;
    funcs_[n] = std::move(info);
  }
  // Match frozen declared -= funcs ordering, though a name cannot remain in both.
  for (const auto &kv : funcs_)
    declared_.erase(kv.first);

  // Reproduce textual address-taken overapproximation with operand scanning: collect @name outside
  // callee position, including global initializers and aliases.
  std::set<const Constant *> seen;
  // Every @name = ... line matches _AT, so include globals own names, both definitions and
  // declarations.
  for (const GlobalVariable &g : m.globals()) {
    if (!g.getName().empty())
      addrTaken_.insert(clean(g.getName()));
    if (g.hasInitializer())
      collectGlobals(g.getInitializer(), addrTaken_, seen);
  }
  for (const GlobalAlias &a : m.aliases()) {
    addrTaken_.insert(clean(a.getName()));
    collectGlobals(a.getAliasee(), addrTaken_, seen);
  }
  for (const GlobalIFunc &f : m.ifuncs()) {
    addrTaken_.insert(clean(f.getName()));
    collectGlobals(f.getResolver(), addrTaken_, seen);
  }

  for (const Function &f : m) {
    if (f.isDeclaration())
      continue;
    FuncInfo &info = funcs_[clean(f.getName())];
    for (const BasicBlock &bb : f) {
      for (const Instruction &i : bb) {
        const auto *cb = dyn_cast<CallBase>(&i);
        // Frozen _is_call recognizes call/invoke, not callbr.
        if (cb && !isa<CallBrInst>(cb)) {
          CallSite site;
          site.block = &bb;
          site.dbg = i.getDebugLoc().get();
          // Resolve names after pointer casts, not getCalledFunction, which returns null for
          // mismatched call/declaration types and misclassified tail call i32 (...) @sp_oom_die()
          // as indirect. Frozen reads the first @name after call/invoke.
          const Function *callee =
              dyn_cast<Function>(cb->getCalledOperand()->stripPointerCasts());
          if (callee)
            site.callee = clean(callee->getName());
          info.calls.push_back(site);
          // Noncallee names are passed function pointers. Frozen excludes by spelling a.group(1) !=
          // callee, so f(@f) also excludes its equal-name argument.
          std::set<std::string> argNames;
          std::set<const Constant *> argSeen;
          for (const Use &u : cb->args())
            if (const auto *c = dyn_cast<Constant>(u.get()))
              collectGlobals(c, argNames, argSeen);
          if (callee)
            argNames.erase(clean(callee->getName()));
          addrTaken_.insert(argNames.begin(), argNames.end());
          if (!callee)
            if (const auto *c = dyn_cast<Constant>(cb->getCalledOperand()))
              collectGlobals(c, addrTaken_, seen);
          continue;
        }
        for (const Use &u : i.operands())
          if (const auto *c = dyn_cast<Constant>(u.get()))
            collectGlobals(c, addrTaken_, seen);
      }
    }
  }

  // ret_reach: reverse-CFG blocks that can reach ret.
  for (auto &kv : funcs_) {
    FuncInfo &info = kv.second;
    std::vector<const BasicBlock *> stack;
    for (const BasicBlock &bb : *info.fn)
      if (isa<ReturnInst>(bb.getTerminator())) {
        info.retReach.insert(&bb);
        stack.push_back(&bb);
      }
    while (!stack.empty()) {
      const BasicBlock *b = stack.back();
      stack.pop_back();
      for (const BasicBlock *p : predecessors(b))
        if (info.retReach.insert(p).second)
          stack.push_back(p);
    }
  }
}

std::string ModuleModel::where(const DILocation *dbg) const {
  if (!dbg)
    return {};
  unsigned line = dbg->getLine();
  const DIScope *scope = dbg->getScope();
  for (int seen = 0; scope && seen < 33; ++seen) {
    if (const DIFile *f = scope->getFile())
      return (f->getFilename() + ":" + Twine(line)).str();
    const auto *local = dyn_cast<DILocalScope>(scope);
    if (!local)
      break;
    if (isa<DISubprogram>(local))
      break; // Python uses None for DISubprogram parent.
    scope = dyn_cast_or_null<DIScope>(local->getScope());
  }
  return ("?:" + Twine(line)).str();
}

std::string ModuleModel::declaredAt(StringRef name) const {
  const FuncInfo *f = func(name);
  if (!f || !f->fn)
    return {};
  const DISubprogram *sub = f->fn->getSubprogram();
  if (!sub || !sub->getFile())
    return {};
  return sub->getFile()->getFilename().str();
}

bool ModuleModel::isRuby(StringRef name) const {
  auto it = rubyCache_.find(name.str());
  if (it != rubyCache_.end())
    return it->second;
  std::string f = declaredAt(name);
  bool v = !f.empty() && StringRef(f).ends_with(".rb");
  rubyCache_[name.str()] = v;
  return v;
}

Analysis::Analysis(const ModuleModel &m, ArrayRef<StringRef> seeds,
                   Indirect indirect)
    : mod_(m), indirect_(indirect) {
  for (StringRef s : seeds)
    seeds_.insert(s.str());
  solve();
}

std::optional<bool> Analysis::leaf(StringRef name) {
  std::string b = basename(name);
  if (seeds_.count(b))
    return true;
  if (mod_.funcs().count(name.str()))
    return std::nullopt;
  if (onAllowlist(b))
    return false;
  externalUnknown_.insert(b);
  return true; // Unknown external: assume the worst.
}

void Analysis::solve() {
  for (const auto &kv : mod_.funcs()) {
    auto v = leaf(kv.first);
    any_[kv.first] = v.value_or(false);
    normal_[kv.first] = v.value_or(false);
  }
  for (const std::string &n : mod_.declared()) {
    auto v = leaf(n);
    any_[n] = v.value_or(false);
    normal_[n] = v.value_or(false);
  }

  hasIndTargets_ = indirect_ == Indirect::AddressTaken;
  if (hasIndTargets_) {
    for (const std::string &n : mod_.addrTaken())
      if (mod_.funcs().count(n) || mod_.declared().count(n))
        indTargets_.push_back(n);
    llvm::sort(indTargets_);
  }

  auto edge = [&](const CallSite &c) -> std::pair<bool, bool> {
    if (!c.callee.empty())
      return {any(c.callee), normal(c.callee)};
    if (!hasIndTargets_)
      return {true, true};
    bool a = false, n = false;
    for (const std::string &t : indTargets_) {
      a = a || any(t);
      n = n || normal(t);
    }
    return {a, n};
  };

  std::map<std::string, std::set<std::string>> callers;
  for (const auto &kv : mod_.funcs())
    for (const CallSite &c : kv.second.calls) {
      if (!c.callee.empty())
        callers[c.callee].insert(kv.first);
      else
        for (const std::string &t : indTargets_)
          callers[t].insert(kv.first);
    }

  std::deque<std::string> work;
  std::set<std::string> inq;
  for (const auto &kv : mod_.funcs()) {
    work.push_back(kv.first);
    inq.insert(kv.first);
  }
  while (!work.empty()) {
    std::string name = work.front();
    work.pop_front();
    inq.erase(name);
    const FuncInfo *f = mod_.func(name);
    if (!f)
      continue;
    if (leaf(name) == std::optional<bool>(true))
      continue; // Seeds with bodies remain fixed at True.
    bool a = any_[name], n = normal_[name];
    bool na = a, nn = n;
    for (const CallSite &c : f->calls) {
      auto [ca, cn] = edge(c);
      na = na || ca;
      if (f->retReach.count(c.block))
        nn = nn || cn;
    }
    if (na != a || nn != n) {
      any_[name] = na;
      normal_[name] = nn;
      for (const std::string &p : callers[name])
        if (inq.insert(p).second)
          work.push_back(p);
    }
  }
}

namespace {
using Prev = std::map<std::string, std::optional<std::pair<std::string, const DILocation *>>>;

std::vector<Analysis::Hop> pathTo(const Prev &prev, const std::string &fn) {
  std::vector<Analysis::Hop> out;
  std::string n = fn;
  while (true) {
    auto it = prev.find(n);
    if (it == prev.end() || !it->second) {
      out.push_back({n, nullptr});
      break;
    }
    out.push_back({n, it->second->second});
    n = it->second->first;
  }
  std::reverse(out.begin(), out.end());
  return out;
}
} // namespace

Analysis::Causes Analysis::witness(StringRef entry, bool normalMode) const {
  Causes causes;
  Prev prev;
  prev[entry.str()] = std::nullopt;
  std::deque<std::string> q{entry.str()};
  while (!q.empty()) {
    std::string fn = q.front();
    q.pop_front();
    const FuncInfo *f = mod_.func(fn);
    if (!f)
      continue;
    for (const CallSite &c : f->calls) {
      if (normalMode && !f->retReach.count(c.block))
        continue;
      if (c.callee.empty()) {
        auto key = std::make_pair(std::string("indirect"), fn);
        if (!causes.count(key)) {
          auto p = pathTo(prev, fn);
          p.push_back({"(function pointer)", c.dbg});
          causes[key] = p;
        }
        continue;
      }
      std::string b = basename(c.callee);
      if (seeds_.count(b)) {
        auto key = std::make_pair(std::string("alloc"), b);
        if (!causes.count(key)) {
          auto p = pathTo(prev, fn);
          p.push_back({c.callee, c.dbg});
          causes[key] = p;
        }
        continue;
      }
      if (!table(c.callee, normalMode))
        continue;
      if (!mod_.funcs().count(c.callee)) {
        auto key = std::make_pair(std::string("external"), b);
        if (!causes.count(key)) {
          auto p = pathTo(prev, fn);
          p.push_back({c.callee, c.dbg});
          causes[key] = p;
        }
        continue;
      }
      if (!prev.count(c.callee)) {
        prev[c.callee] = std::make_pair(fn, c.dbg);
        q.push_back(c.callee);
      }
    }
  }
  return causes;
}

std::vector<Analysis::Site> Analysis::boundarySites(StringRef entry,
                                                    bool normalMode) const {
  std::map<std::tuple<std::string, std::string, std::string>, std::string> out;
  for (const std::string &fn : region(entry, normalMode)) {
    const FuncInfo *f = mod_.func(fn);
    if (!f || !mod_.isRuby(fn))
      continue;
    for (const CallSite &c : f->calls) {
      if (normalMode && !f->retReach.count(c.block))
        continue;
      std::string kind, tgt;
      if (c.callee.empty()) {
        kind = "indirect";
        tgt = "(function pointer)";
      } else if (mod_.isRuby(c.callee)) {
        continue; // Transitive, not frontier.
      } else if (seeds_.count(basename(c.callee))) {
        kind = "alloc";
        tgt = c.callee;
      } else if (!table(c.callee, normalMode)) {
        continue;
      } else if (!mod_.funcs().count(c.callee)) {
        kind = "external";
        tgt = c.callee;
      } else {
        kind = "runtime";
        tgt = c.callee;
      }
      std::string w = mod_.where(c.dbg);
      if (w.empty())
        w = "?";
      out[{w, fn, tgt}] = kind;
    }
  }
  std::vector<Site> sites;
  for (const auto &kv : out)
    sites.push_back({std::get<0>(kv.first), std::get<1>(kv.first),
                     std::get<2>(kv.first), kv.second});
  llvm::sort(sites);
  return sites;
}

std::set<std::string> Analysis::region(StringRef entry, bool normalMode) const {
  std::set<std::string> seen{entry.str()};
  std::vector<std::string> stack{entry.str()};
  while (!stack.empty()) {
    std::string fn = stack.back();
    stack.pop_back();
    const FuncInfo *f = mod_.func(fn);
    if (!f)
      continue;
    for (const CallSite &c : f->calls) {
      if (normalMode && !f->retReach.count(c.block))
        continue;
      if (!c.callee.empty() && seen.insert(c.callee).second)
        stack.push_back(c.callee);
    }
  }
  return seen;
}

std::vector<Analysis::SetjmpHit>
Analysis::setjmpIn(const std::set<std::string> &region) const {
  std::vector<SetjmpHit> hits;
  for (const std::string &fn : region) {
    const FuncInfo *f = mod_.func(fn);
    if (!f)
      continue;
    for (const CallSite &c : f->calls)
      if (!c.callee.empty() && llvm::is_contained(kVocabSetjmp, basename(c.callee)))
        hits.push_back({fn, c.callee, c.dbg});
  }
  return hits;
}

} // namespace spinel_mlir::realtime
