//===- Effects.cpp - an application entry's effects, derived --------------===//
#include "spinel-mlir/Core/Effects.h"

#include <set>

using namespace spinel_mlir::contract;
using llvm::StringRef;

namespace spinel_mlir::core {
namespace {

const AstField *field(const Node &n, StringRef key) {
  for (const auto &f : n.fields)
    if (f.key == key) return &f;
  return nullptr;
}
int64_t ref(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Reference ? std::get<int64_t>(f->value) : -1;
}
std::string str(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::String ? std::get<std::string>(f->value) : "";
}
std::vector<int64_t> array(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Array ? std::get<std::vector<int64_t>>(f->value)
                                               : std::vector<int64_t>{};
}

/// THE WRITE SET, as a fixpoint over the closure. A method's parameter is
/// written if the method stores through it (`p[i] = v`, `p[i] op= v`), passes
/// it to an `inout` argument of an extern, or passes it to a parameter of a
/// helper that is written. The last clause is what makes the derivation
/// transitive, and the iteration runs until nothing new is written: the
/// checker refused recursion, so the closure is a DAG and the iteration is
/// bounded by its depth, but the loop does not rely on that.
class Writes {
public:
  Writes(const ContractModule &m, const EligibilityReport &r,
         const BoundaryContract &c)
      : admitted(r), contract(c) {
    for (const auto &n : m.nodes()) nodes[n.id] = &n;
    for (const auto &e : r.callEdges) callees[e.nodeId] = e.callee;
    if (const Node *program = node(m.root()))
      if (const Node *statements = node(ref(*program, "statements")))
        for (auto id : array(*statements, "body"))
          if (const Node *n = node(id))
            if (n->kind == "DefNode" && ref(*n, "receiver") < 0)
              definitions[str(*n, "name")] = n;
  }

  std::set<std::pair<std::string, std::string>> run() {
    for (bool changed = true; changed;) {
      changed = false;
      for (const auto &name : admitted.methods) {
        const Node *def = definitions[name];
        if (!def) continue;
        std::set<std::string> params;
        if (const Node *ps = node(ref(*def, "parameters")))
          for (auto p : array(*ps, "requireds"))
            if (const Node *pn = node(p)) params.insert(str(*pn, "name"));
        walk(ref(*def, "body"), name, params, changed);
      }
    }
    return written;
  }

private:
  const EligibilityReport &admitted;
  const BoundaryContract &contract;
  std::map<int64_t, const Node *> nodes;
  std::map<std::string, const Node *> definitions;
  /// Decision 0026 step 4: each call node eligibility resolved into the
  /// closure, to the method it calls.
  std::map<int64_t, std::string> callees;
  /// (method, parameter) pairs that are written.
  std::set<std::pair<std::string, std::string>> written;

  const Node *node(int64_t id) const {
    auto it = nodes.find(id);
    return id < 0 || it == nodes.end() ? nullptr : it->second;
  }
  std::string localName(int64_t id) const {
    const Node *n = node(id);
    return n && n->kind == "LocalVariableReadNode" ? str(*n, "name") : "";
  }
  void mark(const std::string &method, const std::string &param,
            const std::set<std::string> &params, bool &changed) {
    if (param.empty() || !params.count(param)) return;
    if (written.insert({method, param}).second) changed = true;
  }
  /// The callee's parameter names, for a helper in the closure.
  std::vector<std::string> paramsOf(const std::string &callee) const {
    std::vector<std::string> out;
    auto it = definitions.find(callee);
    if (it == definitions.end()) return out;
    if (const Node *ps = node(ref(*it->second, "parameters")))
      for (auto p : array(*ps, "requireds"))
        if (const Node *pn = node(p)) out.push_back(str(*pn, "name"));
    return out;
  }

  void walk(int64_t id, const std::string &method, const std::set<std::string> &params,
            bool &changed) {
    const Node *n = node(id);
    if (!n) return;
    const std::string &k = n->kind;
    if (k == "IndexOperatorWriteNode" || k == "IndexAndWriteNode" || k == "IndexOrWriteNode")
      mark(method, localName(ref(*n, "receiver")), params, changed);
    if (k == "CallNode") {
      const std::string name = str(*n, "name");
      const auto receiver = ref(*n, "receiver");
      std::vector<int64_t> args;
      if (const Node *a = node(ref(*n, "arguments"))) args = array(*a, "arguments");
      if (receiver >= 0 && name == "[]=") mark(method, localName(receiver), params, changed);
      const Node *recv = node(receiver);
      if (recv && recv->kind == "ConstantReadNode") {
        // An extern: its `inout` arguments are written by the provider.
        if (const ExternDecl *e = contract.findExtern(str(*recv, "name"), name))
          for (size_t i = 0; i < args.size() && i < e->args.size(); ++i)
            if (e->args[i].kind == Param::Kind::Buffer && e->args[i].mode == AccessMode::InOut)
              mark(method, localName(args[i]), params, changed);
      } else if (auto e = callees.find(n->id); e != callees.end()) {
        // A helper: an argument passed for a parameter the helper writes.
        const std::vector<std::string> callee = paramsOf(e->second);
        for (size_t i = 0; i < args.size() && i < callee.size(); ++i)
          if (written.count({e->second, callee[i]}))
            mark(method, localName(args[i]), params, changed);
      }
    }
    for (const auto &f : n->fields) {
      if (f.kind == AstField::Kind::Reference) walk(std::get<int64_t>(f.value), method, params, changed);
      else if (f.kind == AstField::Kind::Array)
        for (auto c : std::get<std::vector<int64_t>>(f.value)) walk(c, method, params, changed);
    }
  }
};

} // namespace

EntryEffects deriveEffects(const ContractModule &module, const EligibilityReport &admitted,
                           const LoopBoundResult &loops, const BoundaryContract &contract) {
  EntryEffects out;
  const auto written = Writes(module, admitted, contract).run();
  for (const BufferParam &b : contract.buffers)
    out.bufferWritten[b.name] = written.count({contract.entry, b.name}) > 0;
  for (size_t i = 0; i < contract.externs.size(); ++i) {
    ExternUse u;
    u.externIndex = i;
    for (const ExternCount &c : loops.externCounts)
      if (c.externIndex == i) {
        u.callsExpr = c.calls;
        u.derived = c.derived;
        u.reason = c.reason;
        u.sites = c.sites;
      }
    out.externs.push_back(u);
  }
  return out;
}

} // namespace spinel_mlir::core
