#include "spinel-mlir/Core/Eligibility.h"
#include "spinel-mlir/Core/BlockLoops.h"
#include "spinel-mlir/Core/BufferSpelling.h"
#include "spinel-mlir/Core/BorrowFacts.h"
#include "spinel-mlir/Core/Intrinsics.h"
#include "spinel-mlir/Core/SubsetRefusals.h"

#include <algorithm>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <cerrno>
#include <cstdlib>
#include <optional>
#include <string>

using namespace spinel_mlir::contract;
using llvm::StringRef;

namespace spinel_mlir::core {
namespace {
const AstField *field(const Node &n, StringRef key) {
  for (const auto &f : n.fields)
    if (f.key == key) return &f;
  return nullptr;
}
int64_t number(const Node &n, StringRef key, AstField::Kind kind,
               int64_t fallback = -1) {
  const auto *f = field(n, key);
  return f && f->kind == kind ? std::get<int64_t>(f->value) : fallback;
}
int64_t ref(const Node &n, StringRef key) {
  return number(n, key, AstField::Kind::Reference);
}
std::string str(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::String
             ? std::get<std::string>(f->value) : "";
}
std::vector<int64_t> array(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Array
             ? std::get<std::vector<int64_t>>(f->value) : std::vector<int64_t>{};
}
bool scalar(StringRef t) { return t == "int" || t == "bool"; }

class Checker {
  const ContractModule &module;
  const EligibilityMode mode;
  // The body's Integer width (decision 0019): what a literal must fit, and
  // what the integer-representation diagnostics name.
  const unsigned integerBits;
  std::string signedBits() const { return "signed " + std::to_string(integerBits) + " bits"; }
  EligibilityReport report;
  std::map<int64_t, const Node *> nodes;
  std::map<int64_t, const NodeType *> types;
  std::map<int64_t, const Method *> methods;
  std::map<std::string, std::vector<const Node *>> definitions;
  std::set<int64_t> topDefinitions;
  std::map<std::string, unsigned> state;
  std::set<int64_t> edgeNodes;  ///< the call nodes report.callEdges holds
  std::vector<std::string> path;
  std::set<int64_t> activeNodes;

  const Node *node(int64_t id) const {
    auto it = nodes.find(id);
    return it == nodes.end() ? nullptr : it->second;
  }
  std::string type(int64_t id) const {
    auto it = types.find(id);
    const std::string producer = it == types.end() ? "unknown" : it->second->type;
    return factType(id, producer);
  }
  std::string location(const Node *n) const {
    std::string file = module.sourceFile().str();
    int64_t line = 0, col = 0;
    if (n) {
      line = number(*n, "node_line", AstField::Kind::Integer, 0);
      col = number(*n, "node_col", AstField::Kind::Integer, 0);
      auto fileId = number(*n, "node_file", AstField::Kind::Integer);
      for (const auto &s : module.sources())
        if (s.id == fileId) file = s.path;
    }
    return file + ":" + std::to_string(line) + ":" + std::to_string(col);
  }
  void issue(const Node *n, StringRef reason, StringRef detail,
             StringRef verdict = "UNKNOWN") {
    std::string chain;
    for (const auto &p : path) {
      if (!chain.empty()) chain += " -> ";
      chain += p;
    }
    report.diagnostics.push_back({verdict.str(), path.empty() ? "-" : path.back(),
                                 location(n), reason.str(), chain, detail.str()});
  }
  const Method *binding(const Node &def) const {
    auto anchor = ref(def, "parameters");
    if (anchor < 0) anchor = ref(def, "body");
    auto ty = types.find(anchor);
    if (ty == types.end()) return nullptr;
    auto m = methods.find(ty->second->scope);
    if (m == methods.end() || m->second->name != str(def, "name") ||
        m->second->className != "-") return nullptr;
    return m->second;
  }
  // Only metadata is universally ignorable. Unknown semantic fields must be
  // reviewed before a newer producer can enlarge this checker's subset.
  void shape(const Node &n, std::initializer_list<StringRef> keys) {
    for (const auto &f : n.fields) {
      if (f.key == "node_line" || f.key == "node_col" || f.key == "node_file")
        continue;
      // Upstream (2026-10) writes Prism's `depth` on every local variable
      // node: how many scopes up the variable lives. 0 is the method's own
      // scope, which is all this subset has, so 0 is known and anything else
      // stays the unknown field it was before the producer wrote it.
      // DECISION 0041: inside an admitted loop's block, a local of an
      // enclosing scope is up to as many scopes up as there are blocks around.
      if (f.key == "depth" && StringRef(n.kind).starts_with("LocalVariable") &&
          f.kind == AstField::Kind::Integer && std::get<int64_t>(f.value) >= 0 &&
          std::get<int64_t>(f.value) <= blockDepth)
        continue;
      if (std::find(keys.begin(), keys.end(), f.key) == keys.end())
        issue(&n, "unsupported-field", n.kind + "." + f.key);
    }
  }
  bool need(const Node &n, StringRef key, AstField::Kind kind) {
    const auto *f = field(n, key);
    if (f && f->kind == kind) return true;
    issue(&n, "missing-field", n.kind + "." + key.str());
    return false;
  }
  void definitionShape(const Node &def) {
    shape(def, {"name", "parameters", "body", "receiver", "locals"});
    need(def, "name", AstField::Kind::String);
    need(def, "receiver", AstField::Kind::Reference);
    need(def, "parameters", AstField::Kind::Reference);
    need(def, "body", AstField::Kind::Reference);
    // Upstream (2026-11) writes Prism's local table on a def: its local
    // names, joined with commas. The locals face already says the same thing
    // for the method's scope, so the field is known only when it repeats that
    // face: its names are the method's leading slots, in slot order. The
    // slots after them are the analysis's own (a block's parameters hoisted
    // into the method), which Prism's table of the def does not list. A def
    // the analysis pruned (nothing names it) has no method row to compare and
    // is never lowered, so there the string is enough. Any other def with no
    // method to compare it to, or a list that differs, stays the unknown
    // field.
    if (const auto *f = field(def, "locals")) {
      const Method *m = binding(def);
      bool pruned = false;
      for (const auto &rw : module.analysisRewrites())
        if (rw.rewrite == contract::AnalysisRewrite::Kind::PrunedMethod &&
            rw.id == def.id)
          pruned = true;
      bool known = f->kind == AstField::Kind::String;
      if (known && !pruned) {
        std::vector<std::pair<int64_t, std::string>> face;
        if (m)
          for (const auto &l : module.locals())
            if (l.scope == m->scope) face.push_back({l.slot, l.name});
        std::sort(face.begin(), face.end());
        llvm::SmallVector<StringRef> names;
        StringRef(std::get<std::string>(f->value)).split(names, ',');
        known = m && names.size() <= face.size();
        for (size_t i = 0; known && i < names.size(); ++i)
          known = names[i] == face[i].second;
      }
      if (!known)
        issue(&def, "unsupported-field", def.kind + ".locals");
    }
  }
  // Whether the call is written with the ordinary `.` (or with no operator).
  // The pinned producer wrote `call_operator`, exactly "." or "&."; upstream
  // (f5e8252ff) writes the integer `safe_nav`, only when Prism set
  // SAFE_NAVIGATION, and no operator at all. The two say the same thing, so
  // either is read: a safe navigation is never ordinary.
  bool ordinaryCall(const Node &n) const {
    if (const auto *op = field(n, "call_operator"))
      if (op->kind != AstField::Kind::String ||
          std::get<std::string>(op->value) != ".")
        return false;
    if (const auto *sn = field(n, "safe_nav"))
      if (sn->kind != AstField::Kind::Integer || std::get<int64_t>(sn->value) != 0)
        return false;
    return true;
  }
  void callShape(const Node &n) {
    shape(n, {"name", "call_operator", "safe_nav", "attr_write", "receiver",
              "arguments", "block", "vcall", "ignore_visibility"});
    need(n, "name", AstField::Kind::String);
    // Upstream (2026-11) writes Prism's IGNORE_VISIBILITY flag: the call may
    // reach a private method, which Ruby allows only without a receiver or
    // with a literal `self`. This subset has no visibility, so the flag is
    // known exactly where Prism can set it; anywhere else it is unknown.
    if (const auto *iv = field(n, "ignore_visibility")) {
      const Node *recv = node(ref(n, "receiver"));
      if (iv->kind != AstField::Kind::Integer || std::get<int64_t>(iv->value) != 1 ||
          (ref(n, "receiver") != -1 && !(recv && recv->kind == "SelfNode")))
        issue(&n, "unsupported-field", n.kind + ".ignore_visibility");
    }
    // Upstream's PM_CALL_NODE_FLAGS_ATTRIBUTE_WRITE: the call is written as an
    // assignment (`recv.x = v`, `a[i] = v`). Known on exactly those calls; the
    // name is what every rule below reads, and it already says `=`.
    if (const auto *aw = field(n, "attr_write"))
      if (aw->kind != AstField::Kind::Integer || std::get<int64_t>(aw->value) != 1 ||
          !StringRef(str(n, "name")).ends_with("="))
        issue(&n, "unsupported-field", n.kind + ".attr_write");
    need(n, "receiver", AstField::Kind::Reference);
    need(n, "arguments", AstField::Kind::Reference);
    need(n, "block", AstField::Kind::Reference);
    if (field(n, "vcall") &&
        (number(n, "vcall", AstField::Kind::Integer) != 1 ||
         ref(n, "receiver") != -1 || ref(n, "arguments") != -1))
      issue(&n, "unsupported-call", "vcall must be an implicit zero-argument call");
  }
  void parameters(const Node &def, const Method &method) {
    auto id = ref(def, "parameters");
    std::vector<int64_t> required;
    if (id >= 0) {
      const auto *p = node(id);
      if (!p || p->kind != "ParametersNode") {
        issue(&def, "parameter-shape", "expected positional parameters");
        return;
      }
      for (const auto &f : p->fields) {
        if (f.key == "node_line" || f.key == "node_col" || f.key == "node_file") continue;
        if (f.key == "requireds" && f.kind == AstField::Kind::Array) {
          required = std::get<std::vector<int64_t>>(f.value);
          continue;
        }
        if ((f.kind == AstField::Kind::Array &&
             std::get<std::vector<int64_t>>(f.value).empty()) ||
            (f.kind == AstField::Kind::Reference && std::get<int64_t>(f.value) == -1))
          continue;
        issue(p, "parameter-shape", "only required positional parameters are supported");
      }
    }
    if (required.size() != method.parameters.size())
      issue(&def, "parameter-shape", "AST and inferred parameter list disagree");
    for (size_t i = 0; i < required.size(); ++i) {
      const auto *p = node(required[i]);
      if (!p || p->kind != "RequiredParameterNode" ||
          i >= method.parameters.size() || str(*p, "name") != method.parameters[i].name)
        issue(p, "parameter-shape", "parameter identity is not established");
    }
    // With facts supplied, the derivation is what these read: the producer has
    // no types to offer for a source nothing calls, and that is the case the
    // declaration exists to answer. `isCell` and `nullableInt` still come from
    // the producer -- those are analyses, not types, and nothing here derives
    // them.
    for (size_t i = 0; i < method.parameters.size(); ++i) {
      const auto &p = method.parameters[i];
      const std::string t = derivedParamType(method, i, p.type);
      // A declared buffer is an address, not an integer. It is admitted here
      // as `buffer` and nowhere else: only the entry has them, and only the
      // contract can say so.
      const Borrow held = borrowOfName(method.name, p.name);
      if (held.kind == Borrow::Kind::Conflict) {
        issue(&def, "borrow-conflict",
              "parameter " + p.name + " is reached as " + held.element +
                  "; one helper parameter cannot be two different buffers");
        continue;
      }
      if (held.isBuffer()) {
        if (t != "buffer")
          issue(&def, "type-evidence", "buffer parameter " + p.name + " is " + t);
        continue;
      }
      if (t != "int")
        issue(&def, "type-evidence", "parameter " + p.name + " is " + t);
    }
    {
      const std::string t = derivedMethodResult(method, method.returnType);
      if (t == "buffer" && arrayLocals.count(method.name))
        // DECISION 0041 STAGE 2: its own arrays are freed by this very return.
        issue(&def, "array-escape",
              "this returns a Core::Buffer of the data stack, and the return "
              "frees the buffers its method made", "REFUSED");
      else if (t == "buffer")
        // DECISION 0008 TASK 3. A borrowed address that leaves the method
        // outlives the call that lent it. There is no ownership in this ABI to
        // say how long it stays valid, so the address does not travel: what
        // crosses a boundary is a value.
        issue(&def, "buffer-escape",
              "this returns a borrowed buffer; an address does not outlive the "
              "call that lent it, and this ABI has nothing that would say how "
              "long it stays valid", "REFUSED");
      else if (t == "bool" && entryBuffers && method.name != entryBuffers->entry) {
        // DECISION 0008 TASK 3. An INTERNAL helper may answer a boolean: a
        // predicate the closure computes and a branch consumes is an ordinary
        // part of a program, and forcing it through 0 and 1 in the source
        // would be writing C in Ruby. It does not reach the boundary -- the
        // entry's result is the contract's, and a bool there is refused below.
      } else if (t != "int")
        issue(&def, "type-evidence",
              method.name == (entryBuffers ? entryBuffers->entry : std::string())
                  ? "the entry's result is " + t +
                        ", and the contract exports an integer"
                  : "method result is " + t);
    }
    std::set<std::string> seenParams;
    for (const auto &l : module.locals()) {
      if (l.scope != method.scope) continue;
      if (l.isParam) seenParams.insert(l.name);
      if (l.isCell) issue(&def, "runtime-state", "captured local " + l.name, "REFUSED");
      // `nullableInt` is the producer's answer about HOSTED Ruby, where
      // `buf[i]` off the end is nil. It is the wrong question for the checked
      // route, which has no nil: the contract declares each buffer's element
      // type and count, and an access outside it is SPINEL_CORE_BOUNDS. The
      // producer therefore calls a local nullable as soon as one of its
      // assignments is a buffer read and it is rebound across a branch --
      //
      //     t = link[0]
      //     if c then t = 0 else t = link[t] end
      //
      // -- which is the ordinary shape of walking a linked structure, and
      // which the derivation below types as `int` because every load widens
      // to i64 whatever element type it came from.
      //
      // So with facts supplied the derivation answers, as it already does for
      // the parameter and result types just above. It is not a weaker check.
      // The shapes where a value really is nil in this subset are refused by
      // the derivation itself and were measured to be: an `if` with no else
      // taken as a value, and a `while` taken as a value -- both come back
      // `conflicting` from `derivedLocalType`, with or without this bit. What
      // this bit was adding on top of those was the false refusal above.
      if (l.nullableInt && !factsSupplied)
        issue(&def, "nullable-integer", "local " + l.name + " may contain nil");
      const std::string t = derivedLocalType(method, l.name, l.type);
      const bool isBuffer = borrowsName(method.name, l.name);
      if (t == "unread") continue;   // nothing reads it; it cannot matter
      if (isBuffer ? t != "buffer" : !scalar(t))
        issue(&def, "type-evidence", "local " + l.name + " is " + t);
    }
    for (const auto &p : method.parameters)
      if (!seenParams.count(p.name))
        issue(&def, "type-evidence", "missing local evidence for parameter " + p.name);
  }

  // True when `name` is one method of the closure: the call resolves to it.
  bool visitMethod(const std::string &name, const Node *call = nullptr) {
    if (state[name] == 1) {
      path.push_back(name);
      issue(call, "recursive-call", "recursive call cycles are not supported");
      path.pop_back();
      return false;
    }
    if (state[name] == 2) return true;
    path.push_back(name);
    auto it = definitions.find(name);
    if (it == definitions.end()) {
      issue(call, call ? "unresolved-call" : "missing-method", name);
      path.pop_back();
      return false;
    }
    if (it->second.size() != 1 || !topDefinitions.count(it->second[0]->id)) {
      issue(call ? call : it->second[0], "ambiguous-method",
            "requires one unconditional top-level definition of " + name);
      path.pop_back();
      return false;
    }
    state[name] = 1;
    report.methods.push_back(name);
    const Node &def = *it->second[0];
    definitionShape(def);
    const Method *m = binding(def);
    if (!m) {
      issue(&def, "type-evidence", "cannot bind method to an inferred scope");
    } else {
      parameters(def, *m);
      if (auto shadow = core::findShadowedParameter(
              def, [&](int64_t id) { return node(id); }))
        issue(node(shadow->node), "unsupported-block",
              "the block's `" + shadow->name +
                  "` has the name of a local of an enclosing scope; Ruby "
                  "would make it a variable of its own, and this subset "
                  "gives a method one variable per name. Rename it",
              "REFUSED");
      walk(ref(def, "body"), *m);
    }
    state[name] = 2;
    path.pop_back();
    return true;
  }

  /// DECISION 0041 stage 1: the loop shape of a CallNode with a block.
  core::BlockLoopShape blockLoopShape(const Node &n) const {
    return core::classifyBlockLoop(n, [&](int64_t id) { return node(id); });
  }
  /// The written names the admitted loops of `owner` declare, and the slots
  /// the analysis keeps them in (BlockLoops.h, blockSlotName).
  std::set<std::string> blockSlots(const Method &owner, const std::string &name) const {
    std::set<std::string> out;
    const Node *def = definitionNamed(owner.name);
    if (!def) return out;
    auto hasSlot = [&](StringRef slot) {
      for (const auto &l : module.locals())
        if (l.scope == owner.scope && l.name == slot) return true;
      return false;
    };
    for (const core::BlockLoop &loop :
         core::blockLoopsUnder(*def, [&](int64_t id) { return node(id); })) {
      if (std::find(loop.params.begin(), loop.params.end(), name) == loop.params.end() &&
          std::find(loop.locals.begin(), loop.locals.end(), name) == loop.locals.end())
        continue;
      out.insert(core::blockSlotName(
          name, loop, [&](int64_t id) { return node(id); },
          [&](int64_t id) {
            auto t = types.find(id);
            return t == types.end() ? std::string() : t->second->detail;
          },
          hasSlot));
    }
    return out;
  }
  /// The checks of an admitted loop: the walk of `inspect` for one.
  void blockLoop(const Node &n, const core::BlockLoop &loop, const Method &owner) {
    using K = core::BlockLoop::Kind;
    const std::string name = core::blockLoopName(loop.kind).str();
    if (mode != EligibilityMode::CheckedScalar) {
      issue(&n, "unsupported-node", "a `" + name + "` loop with a block");
      return;
    }
    if (!inStatementPos(n.id))
      issue(&n, "loop-value",
            "the value of a `" + name + "` loop is used; a loop with a block "
            "is a statement in this subset, and its value (the receiver) is "
            "not given", "REFUSED");
    if (loop.kind == K::Each || loop.kind == K::EachWithIndex) {
      const Node *r = node(loop.receiver);
      if (!r || r->kind != "LocalVariableReadNode" ||
          !borrowOfName(owner.name, str(*r, "name")).isBuffer()) {
        issue(&n, "unsupported-block",
              "`" + name + "` is a loop only on a buffer this method holds; "
              "this receiver is not one", "REFUSED");
        return;
      }
    } else {
      walk(loop.receiver, owner);
      if (type(loop.receiver) != "int")
        issue(&n, "type-evidence",
              "the receiver of `" + name + "` must be a proven integer");
    }
    if (loop.limit >= 0) {
      walk(loop.limit, owner);
      if (type(loop.limit) != "int")
        issue(&n, "type-evidence",
              "the argument of `" + name + "` must be a proven integer");
    }
    if (loop.body < 0) return;
    ++loopDepth;
    ++blockDepth;
    walk(loop.body, owner);
    --blockDepth;
    --loopDepth;
  }

  void walk(int64_t id, const Method &owner) {
    const Node *n = node(id);
    if (!n) { issue(nullptr, "missing-node", "missing required expression"); return; }
    if (!activeNodes.insert(id).second) {
      issue(n, "cyclic-ast", "cyclic AST references"); return;
    }
    ++report.nodes;
    inspect(*n, owner);
    activeNodes.erase(id);
  }
  void child(const Node &n, StringRef key, const Method &owner, bool optional = false) {
    if (!need(n, key, AstField::Kind::Reference)) return;
    auto id = ref(n, key);
    if (id < 0 && optional) return;
    walk(id, owner);
  }
  void list(const Node &n, StringRef key, const Method &owner) {
    if (!need(n, key, AstField::Kind::Array)) return;
    const auto ids = array(n, key);
    if (ids.empty()) issue(&n, "empty-expression", "empty " + key.str());
    for (auto id : ids) walk(id, owner);
  }
  /// The exact value of an integer literal, or nullopt if this node does not
  /// name one.
  ///
  /// Measured, and the reason this is not just `value`: for a literal outside
  /// signed 64 bits the producer emits a SATURATED `value` beside the exact
  /// decimal text in `bigval` -- `9223372036854775808` arrives as
  /// `value 9223372036854775807, bigval 9223372036854775808`. Reading `value`
  /// alone would silently accept a bignum as INT64_MAX. So where `bigval` is
  /// present it is authoritative, and the node is a literal only if the two
  /// agree exactly.
  ///
  /// `-9223372036854775808` is a single IntegerNode here, not a unary minus
  /// applied to a literal that does not fit: the producer folds it, and both
  /// fields say so.
  std::optional<int64_t> literalValue(const Node &n) const {
    const AstField *f = field(n, "value");
    if (!f || f->kind != AstField::Kind::Integer) return std::nullopt;
    const int64_t value = std::get<int64_t>(f->value);
    const AstField *big = field(n, "bigval");
    if (!big) return value;
    if (big->kind != AstField::Kind::String) return std::nullopt;
    const std::string &text = std::get<std::string>(big->value);
    errno = 0;
    char *end = nullptr;
    const long long parsed = std::strtoll(text.c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0') return std::nullopt;
    if (static_cast<int64_t>(parsed) != value) return std::nullopt;
    return value;
  }

  /// core_u32's argument (decision 0042 stage 4): an Integer literal in
  /// 0..2**32-1, its exact value read as Core/Intrinsics.h reads it.
  std::optional<int64_t> u32Literal(int64_t id) const {
    const Node *n = node(id);
    if (!n || n->kind != "IntegerNode") return std::nullopt;
    const AstField *f = field(*n, "value");
    if (!f || f->kind != AstField::Kind::Integer) return std::nullopt;
    const AstField *big = field(*n, "bigval");
    if (big && big->kind != AstField::Kind::String) return std::nullopt;
    return u32LiteralValue(std::get<int64_t>(f->value),
                           big ? &std::get<std::string>(big->value) : nullptr);
  }

  void expressionType(const Node &n) {
    if (!scalar(type(n.id))) issue(&n, "type-evidence", "expression is " + type(n.id));
  }

  void inspect(const Node &n, const Method &owner) {
    const auto &k = n.kind;
    // DECISION 0014 §7: text as bytes. In an application entry a string
    // literal is admitted in exactly one place -- as the argument for an `in`
    // `u8` buffer parameter of a helper or an extern, where the call recorded
    // it -- and is refused by position anywhere else. Outside an application
    // it stays what it was: a heap object this subset does not have.
    if (k == "StringNode" && application()) {
      if (admittedLiterals.count(n.id)) {
        shape(n, {"content", "fzl", "unescaped", "opening", "closing", "frozen"});
        return;
      }
      issue(&n, "literal-position",
            "a string literal is admitted only as the argument for an `in` u8 "
            "buffer parameter of a helper or an extern", "REFUSED");
      return;
    }
    // Decision 0026 step 5: the heap operations are the rows the subset
    // refusal table marks so (SubsetRefusals.cpp), the one owner of what
    // allocates.
    if (isHeapOperation(k)) {
      issue(&n, "heap-operation", k + " requires heap semantics", "REFUSED"); return;
    }
    // `ConstantReadNode` is the one Constant* kind the checked boundary
    // resolves on its own, and it is decided below. DECISION 0014 D5 adds one
    // more on the application lane: a single-level `Mod::NAME`, where `Mod` is
    // a module of this source and `NAME` an integer literal written in its
    // body -- the notation the generated board package uses (`Led::COUNT`).
    // Everything else keeps this refusal: a `ConstantWriteNode` inside a
    // method body is a definition this boundary cannot place, and a deeper
    // path is a lookup.
    const bool readsAdmittedConstant =
        (k == "ConstantReadNode" && mode == EligibilityMode::CheckedScalar) ||
        (k == "ConstantPathNode" && mode == EligibilityMode::CheckedScalar &&
         application());
    if (!readsAdmittedConstant &&
        (StringRef(k).starts_with("GlobalVariable") ||
         StringRef(k).starts_with("InstanceVariable") ||
         StringRef(k).starts_with("ClassVariable") ||
         StringRef(k).starts_with("Constant") || k == "SelfNode")) {
      issue(&n, "runtime-state", k, "REFUSED"); return;
    }
    if (k == "StatementsNode") {
      shape(n, {"body"}); list(n, "body", owner); return;
    }
    if (k == "ElseNode") {
      shape(n, {"statements"}); child(n, "statements", owner); return;
    }
    if (k == "ArgumentsNode") {
      shape(n, {"arguments"}); list(n, "arguments", owner); return;
    }
    if (k == "IfNode" || k == "UnlessNode") {
      // `unless` is `if` with the arms swapped -- the same rule and the same
      // walker. It was reaching the default refusal here while the derivation
      // had always handled both. The FIELD is spelled differently, measured:
      // prism gives an `if` a `subsequent` and an `unless` an `else_clause`.
      const char *elseKey = k == "UnlessNode" ? "else_clause" : "subsequent";
      shape(n, {"predicate", "statements", elseKey});
      // An `if` whose arms both leave the method has no value, and that is not
      // a defect: `if b == 0 then return 1 else return a + b end` is the early
      // return the decision admits. Whether anything CONSUMES the missing
      // value is decided where it would be consumed -- a local bound to it
      // becomes conflicting, and the method result is the join of the returns.
      // "void" here is the non-fallthrough case only: both arms left the
      // method. An `if` that yields nil is NOT this, and stays refused.
      if (!(mode == EligibilityMode::CheckedScalar &&
            (type(n.id) == "void" || inStatementPos(n.id))))
        expressionType(n);
      // DECISION 0008 TASK 4. A missing `else` is admitted in STATEMENT
      // position, where nothing reads what the branch would have produced. In
      // value position it is still nil and still refused.
      const bool stmtPos = mode == EligibilityMode::CheckedScalar && inStatementPos(n.id);
      if (ref(n, "statements") < 0 || (ref(n, elseKey) < 0 && !stmtPos))
        issue(&n, "implicit-nil",
              stmtPos ? "both conditional branches must have explicit scalar results"
                      : "this branch has no value on the path not taken, and "
                        "nil is not in this subset; a conditional with no else "
                        "is admitted only where nothing reads its value");
      child(n, "predicate", owner); child(n, "statements", owner);
      child(n, elseKey, owner, true); return;
    }
    if (k == "LocalVariableOperatorWriteNode") {
      // `x op= e` is `x = x op e` written once. It was missing here while the
      // derivation already handled it, so `n += 1` was an unsupported node
      // while `n = n + 1` was admitted -- two spellings of one statement
      // getting two answers.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"name", "binary_operator", "value"});
      if (!need(n, "name", AstField::Kind::String) ||
          !need(n, "binary_operator", AstField::Kind::String) ||
          !need(n, "value", AstField::Kind::Reference))
        return;
      const std::string op = str(n, "binary_operator");
      // The same operators the checked mode admits as calls, and no more.
      // `&&=` and `||=` arrive here with `&&` / `||` as the operator: they
      // short-circuit, which changes when the assignment happens, so they are
      // a different statement and stay out.
      if (op != "+" && op != "-" && op != "*" && op != "/" && op != "%" &&
          op != "<<" && op != ">>" && op != "&" && op != "|" && op != "^" &&
          op != "**") {
        issue(&n, "unsupported-node",
              "`" + op + "=` is not in this subset");
        return;
      }
      const std::string name = str(n, "name");
      if (borrowsName(owner.name, name)) {
        issue(&n, "buffer-rebound",
              name + " holds a borrowed buffer; version 1 resolves an "
                     "indexed receiver only as a parameter by name, so it "
                     "cannot be reassigned",
              "REFUSED");
        return;
      }
      expressionType(n);
      size_t matches = 0;
      std::set<std::string> slots = blockSlots(owner, name);
      slots.insert(name);
      for (const auto &l : module.locals())
        if (l.scope == owner.scope && slots.count(l.name)) ++matches;
      // DECISION 0041: a block's name may have a slot of its own and the
      // method one too; at least one slot is evidence for it.
      if (matches > 1 && slots.size() > 1) matches = 1;
      auto t = types.find(n.id);
      if (matches != 1 || (!factsSupplied && (t == types.end() ||
                                              t->second->scope != owner.scope)))
        issue(&n, "type-evidence", "local scope identity is not established");
      child(n, "value", owner);
      return;
    }
    if (k == "ConstantReadNode") {
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "runtime-state", "constant lookup is a runtime operation", "REFUSED");
        return;
      }
      shape(n, {"name"});
      if (!need(n, "name", AstField::Kind::String)) return;
      const std::string name = str(n, "name");
      if (!constantValues.count(name)) {
        issue(&n, "unresolved-constant",
              name + " is not a single unconditional top-level assignment of an "
                     "integer literal in this source", "REFUSED");
        return;
      }
      expressionType(n);
      return;
    }
    // DECISION 0014 D5: `Mod::NAME`, one level, resolved against the modules
    // of this source. Each way it can fail is named where it fails: a deeper
    // path, a module that is not here, a name that module does not carry.
    if (k == "ConstantPathNode") {
      // Only an application lane reaches here: the admission gate above
      // refuses every Constant* kind the mode does not admit, this one
      // included, so there is no second refusal of that case to write.
      shape(n, {"name", "parent"});
      if (!need(n, "name", AstField::Kind::String) ||
          !need(n, "parent", AstField::Kind::Reference))
        return;
      const Node *parent = node(ref(n, "parent"));
      if (!parent || parent->kind != "ConstantReadNode") {
        issue(&n, "unresolved-constant",
              std::string("a constant path that is not `Mod::NAME` (") + pathText(n) +
                  "): a board constant names one module of this source and one "
                  "integer written in its body, so neither a deeper path nor a "
                  "path from the root resolves here", "REFUSED");
        return;
      }
      const std::string key = str(*parent, "name") + "::" + str(n, "name");
      if (!moduleNames.count(str(*parent, "name"))) {
        issue(&n, "unresolved-constant",
              key + ": " + str(*parent, "name") + " is not a module of this source",
              "REFUSED");
        return;
      }
      if (!constantValues.count(key)) {
        issue(&n, "unresolved-constant",
              key + " is not an integer literal written in that module's body",
              "REFUSED");
        return;
      }
      expressionType(n);
      return;
    }
    if (k == "ReturnNode") {
      // Decision 0007: "The admission rules include `while`, local assignment,
      // conditionals, early return and direct helper calls." Early return was
      // missing here, so a `return` anywhere in a checked closure was refused
      // as an unsupported node -- and the multi-return shape that the result
      // join exists to handle could not be written at all.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"arguments"});
      if (!need(n, "arguments", AstField::Kind::Reference)) return;
      const auto argumentsId = ref(n, "arguments");
      const Node *a = argumentsId < 0 ? nullptr : node(argumentsId);
      std::vector<int64_t> items;
      if (a && a->kind == "ArgumentsNode") {
        shape(*a, {"arguments"});
        if (need(*a, "arguments", AstField::Kind::Array)) items = array(*a, "arguments");
      }
      if (items.size() != 1) {
        // A bare `return` is nil, and nil is not in this subset.
        issue(&n, "implicit-nil",
              "`return` needs exactly one scalar value");
        return;
      }
      child(n, "arguments", owner);
      return;
    }
    if (k == "ArgumentsNode") {
      shape(n, {"arguments"});
      if (!need(n, "arguments", AstField::Kind::Array)) return;
      list(n, "arguments", owner);
      return;
    }
    if (k == "TrueNode" || k == "FalseNode") {
      // DECISION 0008 TASK 4. A boolean LITERAL. `&&` and `||` need statically
      // boolean operands and an internal helper may answer a boolean, so the
      // two constants that produce one are in the subset. They are not 1 and
      // 0: nothing converts between a boolean and an integer here.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {});
      expressionType(n);
      return;
    }
    if (k == "IndexOperatorWriteNode") {
      // DECISION 0008 TASK 4. `buf[i] op= v`, on a buffer this method holds
      // WRITABLE. The receiver and the index are evaluated once each and the
      // order is fixed -- bounds, load, compute, narrow, store -- with no
      // store if any of the checks fails. The checker's job here is the shape
      // and the permission; the order is the generator's and is measured by
      // running it.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"receiver", "arguments", "value", "binary_operator"});
      const std::string op = str(n, "binary_operator");
      static const std::set<std::string> kOps = {"+", "-", "*", "/", "%", "<<",
                                                 ">>", "&", "|", "^", "**"};
      if (!kOps.count(op)) {
        issue(&n, "unsupported-node",
              "`[]" + op + "=` is not in this subset");
        return;
      }
      const auto recv = ref(n, "receiver");
      const Node *r = recv < 0 ? nullptr : node(recv);
      std::string bufName;
      Borrow held;
      if (r && r->kind == "LocalVariableReadNode" &&
          (bufName = str(*r, "name"), true))
        held = borrowOfName(owner.name, bufName);
      if (!held.isBuffer()) {
        issue(&n, "heap-operation",
              "Ruby indexing has no ownership-free scalar contract", "REFUSED");
        return;
      }
      if (held.readOnly) {
        issue(&n, "readonly-write",
              bufName + " is borrowed read-only here, and `" + op +
                  "=` writes to it", "REFUSED");
        return;
      }
      std::vector<int64_t> idx;
      const auto argsId = ref(n, "arguments");
      const Node *a = argsId < 0 ? nullptr : node(argsId);
      if (a && a->kind == "ArgumentsNode") idx = array(*a, "arguments");
      if (idx.size() != 1) {
        issue(&n, "arity-mismatch", "`[]" + op + "=` takes one index");
        return;
      }
      child(n, "arguments", owner);
      child(n, "value", owner);
      if (type(idx[0]) != "int")
        issue(&n, "type-evidence", "a buffer index must be a proven integer");
      const auto v = ref(n, "value");
      if (v >= 0 && type(v) != "int")
        issue(&n, "type-evidence", "a buffer element must be a proven integer");
      return;
    }
    if (k == "AndNode" || k == "OrNode") {
      // DECISION 0008 TASK 4. `&&` and `||` with STATICALLY BOOLEAN operands
      // and real short circuiting. The right operand may call a helper that
      // writes a buffer or fails, so whether it is evaluated is observable --
      // which is why the rule is about the operands' types and not about
      // whether the operator could be folded.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"left", "right", "operator_loc"});
      expressionType(n);
      if (!need(n, "left", AstField::Kind::Reference) ||
          !need(n, "right", AstField::Kind::Reference))
        return;
      child(n, "left", owner);
      child(n, "right", owner);
      const char *spelling = k == "AndNode" ? "&&" : "||";
      for (const char *side : {"left", "right"}) {
        const auto id = ref(n, side);
        if (id < 0) continue;
        const std::string ty = type(id);
        if (ty == "bool" || ty == "unknown") continue;
        issue(&n, "non-boolean-operand",
              std::string("`") + spelling + "` has a " + ty + " " + side +
                  " operand; Ruby's truthiness makes every integer true, 0 "
                  "included, and this subset does not have it", "REFUSED");
      }
      return;
    }
    if (k == "ParenthesesNode") {
      // Decision 0007 task 2 admits parentheses, and decision 0015 admits them
      // in the scalar slice, where they group its arithmetic. The body is
      // walked like any other expression, so what they contain is checked by
      // its own rule.
      shape(n, {"body"});
      expressionType(n);
      if (!need(n, "body", AstField::Kind::Reference)) return;
      child(n, "body", owner);
      return;
    }
    if (k == "BreakNode" || k == "NextNode") {
      // DECISION 0008 TASK 4. `break` and `next` leave or restart the NEAREST
      // enclosing loop. There is no labelled loop here, so nearest is the only
      // rule there is, and a value has nowhere to go: a loop is a statement in
      // this subset and produces nothing.
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"arguments"});
      const auto argumentsId = ref(n, "arguments");
      if (argumentsId >= 0) {
        issue(&n, "loop-control-value",
              "`" + std::string(k == "BreakNode" ? "break" : "next") +
                  "` carries a value; a loop is a statement here and produces "
                  "nothing for it to become", "REFUSED");
        return;
      }
      if (loopDepth == 0) {
        issue(&n, "loop-control-outside-loop",
              "`" + std::string(k == "BreakNode" ? "break" : "next") +
                  "` is outside any loop", "REFUSED");
        return;
      }
      if (!inStatementPos(n.id))
        issue(&n, "loop-control-value",
              "`" + std::string(k == "BreakNode" ? "break" : "next") +
                  "` is in value position, and it produces nothing", "REFUSED");
      return;
    }
    if (k == "WhileNode") {
      if (mode != EligibilityMode::CheckedScalar) {
        issue(&n, "unsupported-node", k);
        return;
      }
      shape(n, {"flags", "predicate", "statements"});
      if (!need(n, "flags", AstField::Kind::Integer) ||
          !need(n, "predicate", AstField::Kind::Reference) ||
          !need(n, "statements", AstField::Kind::Reference))
        return;
      // Bit 2 is prism's BEGIN_MODIFIER: `begin ... end while` runs its body
      // before the first test, which is a different loop. Measured rather than
      // assumed -- a plain `while` carries flags 1 here and the post-test form
      // carries 5.
      //
      // Stated as a whitelist rather than as "not bit 2": bits 0 and 1 are
      // prism's NEWLINE and STATIC_LITERAL, which say nothing about the loop,
      // and any OTHER bit is a spelling this checker has never seen. Refusing
      // what is not listed is the rule; listing what to refuse would admit
      // every flag added after this was written.
      const auto flags = number(n, "flags", AstField::Kind::Integer);
      if ((flags & ~static_cast<int64_t>(3)) != 0)
        issue(&n, "unsupported-node",
              "a `while` with loop flags " + std::to_string(flags) +
                  "; only a plain pre-test `while` is admitted");
      // No expression type: a `while` is nil-valued in Ruby, and nil is not in
      // this subset. Using one as a value fails at whatever consumes it.
      child(n, "predicate", owner);
      ++loopDepth;
      child(n, "statements", owner);
      --loopDepth;
      return;
    }
    if (k == "IntegerNode") {
      if (mode == EligibilityMode::CheckedScalar) {
        // Decision 0007: the native CORE ABI retains the entire signed i64
        // domain, and native entry values have no nil sentinel. So the hosted
        // reservation of INTPTR_MIN does not apply on this route, and
        // `-9223372036854775808` is an ordinary literal.
        //
        // `bigval` is admitted as a FIELD here and refused on the ordinary
        // route, where `shape` still rejects it -- which is what keeps the
        // sentinel reserved there.
        shape(n, {"value", "bigval"});
        expressionType(n);
        if (!need(n, "value", AstField::Kind::Integer)) return;
        if (!literalValue(n))
          issue(&n, "integer-representation",
                "literal is outside " + signedBits() + ", or its exact and saturated "
                "spellings disagree");
        return;
      }
      shape(n, {"value"}); expressionType(n);
      if (!need(n, "value", AstField::Kind::Integer)) return;
      // Source eligibility for the producer's host integer representation;
      // this does not choose an exported width. INTPTR_MIN was excluded while
      // the hosted runtime used it as the nil of an Integer slot. Upstream
      // a07741ff1 moved that nil out of band, and the owner decided INT64_MIN
      // is an ordinary value (decision 0015), so the whole host range is in.
      auto v = number(n, "value", AstField::Kind::Integer);
      if (v < std::numeric_limits<intptr_t>::min() || v > std::numeric_limits<intptr_t>::max())
        issue(&n, "integer-representation", "literal is outside the non-null host integer domain");
      return;
    }
    if (k == "LocalVariableReadNode" || k == "LocalVariableWriteNode") {
      shape(n, k == "LocalVariableReadNode" ? std::initializer_list<StringRef>{"name"}
                                           : std::initializer_list<StringRef>{"name", "value"});
      const std::string name = str(n, "name");
      // Reading a declared buffer yields an ADDRESS, which is not a scalar and
      // must not be refused as one. Nothing else here admits it: every way of
      // consuming a buffer other than `[]` and `[]=` derives a conflict and is
      // refused where it is consumed -- bound to a local, added to, returned.
      // Decision 0041 stage 2: the write that makes an array binds an address
      // too, and is decided below.
      const bool bufferRead =
          (k == "LocalVariableReadNode" && borrowsName(owner.name, name)) ||
          (k == "LocalVariableWriteNode" && scratchName(owner.name, name));
      if (!bufferRead) expressionType(n);
      size_t matches = 0;
      std::set<std::string> slots = blockSlots(owner, name);
      slots.insert(name);
      for (const auto &l : module.locals())
        if (l.scope == owner.scope && slots.count(l.name)) ++matches;
      // DECISION 0041: a block's name may have a slot of its own and the
      // method one too; at least one slot is evidence for it.
      if (matches > 1 && slots.size() > 1) matches = 1;
      auto t = types.find(n.id);
      if (matches != 1 || t == types.end() || t->second->scope != owner.scope)
        issue(&n, "type-evidence", "local scope identity is not established");
      // A count parameter is an ORDINARY LOCAL and may be assigned like any
      // other. Decision 0007 admits local assignment, and refusing it here
      // narrowed that -- the fix for a body moving its own bound belongs in
      // the generator, which now takes the bound from the parameter as it
      // arrived and never from the environment. The Ruby local and the
      // descriptor count are two different things, and separating them is the
      // whole answer; forbidding the assignment was answering a different
      // question.
      //
      // Rebinding a BUFFER parameter is refused as an IMPLEMENTATION LIMIT of
      // version 1, and is stated as one.
      //
      // It is not an ownership rule. This ABI says nothing that would make
      // reassigning a local name drop a borrow, and claiming it did would be
      // deriving a fact the contract does not contain. What is true is
      // narrower and checkable: version 1 resolves an indexed receiver only as
      // a direct buffer PARAMETER by name, so a rebound name has nothing to
      // resolve to. Refusing the rebinding keeps that limit visible at the
      // assignment rather than surfacing it as a confusing failure at the
      // index, or -- worse -- as an index against a name that no longer means
      // the buffer.
      // DECISION 0041 STAGE 2: `a = Array.new(n, v)`, the one admitted way to
      // make an array, and the ways an array would outlive its maker.
      if (k == "LocalVariableWriteNode") {
        const Node *v = node(ref(n, "value"));
        auto made = v ? arrayWrites.find(v->id) : arrayWrites.end();
        if (made != arrayWrites.end() && made->second.second == n.id) {
          arrayNew(*v, owner);
          return;
        }
        if (arrayLocals.count(owner.name) && arrayLocals[owner.name].count(name)) {
          issue(&n, "array-rebound",
                name + " holds a Core::Buffer on the data stack; its local is "
                       "assigned once, by Core::Buffer, and never reassigned", "REFUSED");
          return;
        }
        if (scratchRead(v, owner.name)) {
          issue(&n, "array-alias",
                "the Core::Buffer " + str(*v, "name") + " is assigned to a second local, " +
                    name + "; a Core::Buffer on the data stack has one name in its method", "REFUSED");
          return;
        }
      }
      if (k == "LocalVariableWriteNode" && borrowsName(owner.name, name)) {
        issue(&n, "buffer-rebound",
              name + " holds a borrowed buffer; version 1 resolves an "
                     "indexed receiver only as a parameter by name, so it "
                     "cannot be reassigned",
              "REFUSED");
        return;
      }
      if (k == "LocalVariableWriteNode") child(n, "value", owner);
      return;
    }
    if (k == "CallNode") {
      // DECISION 0041 stage 1: a literal block on an iterator call.
      core::BlockLoopShape shape = blockLoopShape(n);
      if (shape.loop) { blockLoop(n, *shape.loop, owner); return; }
      if (shape.refusal) {
        issue(&n, "unsupported-block", *shape.refusal, "REFUSED");
        return;
      }
      call(n, owner); return;
    }
    issue(&n, "unsupported-node", k);
  }


  // ---- entry facts -------------------------------------------------------
  //
  // Decision 0007: "A declaration supplies entry facts; the checker must
  // validate every use and reachable callee against them."
  //
  // The facts are one per entry parameter -- it is a non-null integer -- and
  // everything else is DERIVED from them. A `poly` painted over with `int`
  // would admit exactly the programs this checker exists to refuse; here a use
  // whose operands are not derivable stays untyped, and the per-node checks
  // below are what refuse it.
  //
  // No caller is synthesised. The declaration is read as a declaration.
  //
  // The lattice has four states and they are NOT interchangeable. An earlier
  // version used the empty string for both "nothing known yet" and "two types
  // met here", so `int` joined with `bool` became empty and joining that with
  // `int` revived it. It also kept a node's earlier type when a later pass
  // could not derive one, so a retracted type stayed readable. Both are gone:
  //
  //   Unreached  bottom -- no path has reached this yet
  //   Int, Bool  the two value types in this subset
  //   NoReturn   a path that does not fall through at all -- a `return`, a
  //              `core_fail`. It never reaches a join, so it says nothing
  //              there and takes the other arm's type rather than destroying it
  //   NilValue   a path that DOES fall through and has no scalar value -- a
  //              `while`, which is nil in Ruby. Nil is not in this subset, so
  //              meeting it with a type is a conflict. Calling this
  //              "non-fallthrough" too was wrong: `if c then (while ...) else 7
  //              end` would have taken the 7
  //   Conflict   top -- absorbing, and never anything else again
  //
  // Everything ascends: ⊥ -> a type -> Conflict, and Conflict stays. That is
  // what makes the iterations below terminate, and it is why the bound is a
  // backstop rather than the argument.

  //   Buffer     an address the caller owns. Not an integer: `src + 1` is a
  //              conflict, not pointer arithmetic, and version 1 has no way to
  //              make or pass one
  enum class Ty { Unreached, Int, Bool, Buffer, NoReturn, NilValue, Conflict };

  static Ty joinTy(Ty a, Ty b) {
    if (a == Ty::Unreached) return b;
    if (b == Ty::Unreached) return a;
    if (a == b) return a;
    // Only the path that never arrives is transparent at a join. A `while`
    // arrives, carrying nil, and nil meeting a type is a conflict.
    if (a == Ty::NoReturn) return b;
    if (b == Ty::NoReturn) return a;
    return Ty::Conflict;
  }
  static std::string tyName(Ty t) {
    switch (t) {
    case Ty::Int: return "int";
    case Ty::Bool: return "bool";
    case Ty::Buffer: return "buffer";
    case Ty::NoReturn: return "void";
    case Ty::NilValue: return "nil";
    case Ty::Conflict: return "conflicting";
    case Ty::Unreached: break;
    }
    return "unknown";
  }

  /// The result of an operation whose operands must all be `want`.
  ///
  /// An operand that is merely NOT KNOWN YET makes the result not known yet.
  /// It must not be a conflict: in the first round a callee's result has not
  /// been derived, and treating that as "wrong type" would turn its caller
  /// into a conflict -- which is absorbing, so the join across rounds could
  /// never recover from it. An operand of a definitely wrong type, or one that
  /// is already conflicting, is a conflict and stays one.
  static Ty applyOp(std::initializer_list<Ty> operands, Ty want, Ty produce) {
    bool pending = false;
    for (Ty t : operands) {
      if (t == Ty::Unreached) pending = true;
      else if (t != want) return Ty::Conflict;
    }
    return pending ? Ty::Unreached : produce;
  }

  using Env = std::map<std::string, Ty>;

  /// The join of two environments at a control-flow merge.
  ///
  /// A name bound on one path and not the other is Conflict, not dropped and
  /// not inherited: in Ruby it is nil on the path that did not bind it, and
  /// nil is not in this subset. Making it Conflict is also what keeps the
  /// domain growing monotonically, which the loop fixpoint below needs.
  static Env joinEnv(const Env &a, const Env &b) {
    Env out = a;
    for (const auto &kv : b) {
      auto it = out.find(kv.first);
      if (it == out.end()) out[kv.first] = Ty::Conflict;
      else it->second = joinTy(it->second, kv.second);
    }
    for (auto &kv : out)
      if (!b.count(kv.first)) kv.second = Ty::Conflict;
    return out;
  }

  /// Decision 0007 task 2 admits literal scalar constants. A constant is a
  /// single unconditional top-level `NAME = <integer literal>` and nothing
  /// else: a second write, a write anywhere but the program's own statement
  /// list, and a value that is not a literal are each refused rather than
  /// resolved to whichever one ran.
  /// DECISION 0014 D5: a module of the packed root may also carry constants,
  /// keyed `Mod::NAME` in the same map -- one level, an integer literal in the
  /// module's own body. `moduleNames` is every module this source defines, so
  /// an unknown module and an unknown name in a known module are told apart.
  std::map<std::string, const Node *> constantWrites;
  std::map<std::string, int64_t> constantValues;
  std::set<std::string> moduleNames;

  /// `A::B::C` as source text, for the refusal that names it.
  std::string pathText(const Node &n) const {
    std::string name = str(n, "name");
    const Node *p = node(ref(n, "parent"));
    if (!p) return "::" + name;
    if (p->kind == "ConstantReadNode") return str(*p, "name") + "::" + name;
    if (p->kind == "ConstantPathNode") return pathText(*p) + "::" + name;
    return name;
  }

  const EntryFacts *entryBuffers = nullptr;
  /// Decision 0014: whether this is an application entry (a version 2
  /// contract): externs, literals and the context rule exist only there.
  bool application() const { return entryBuffers && entryBuffers->isApplication(); }
  /// The string literal nodes a call admitted as `in` u8 buffer arguments,
  /// recorded by the call before its arguments are walked.
  std::set<int64_t> admittedLiterals;
  /// Decision 0008 task 3: which parameter of which method borrows a buffer,
  /// derived from the entry's declaration through the calls that pass it. A
  /// helper has no contract, so this is the only thing that says its parameter
  /// is an address rather than an integer.
  BorrowFactsResult borrowFacts;
  bool factsSupplied = false;
  bool derivationUnsettled = false;
  bool signaturesChanged = false;
  /// Cleared at the start of every round and recomputed: a node's type is only
  /// ever read from the round that produced the signatures it was computed
  /// from.
  std::map<int64_t, Ty> derivedNode;
  std::map<std::string, std::vector<Ty>> derivedParams;
  std::map<std::string, Ty> derivedResult;
  std::map<std::string, Env> derivedLocals;
  std::map<std::string, Ty> derivedReturns;
  std::vector<std::string> pendingCallees;
  std::set<std::string> readParameters;
  /// Per method, the type each local had AT ITS READS.
  ///
  /// The final environment is the wrong thing to check. A local bound in one
  /// arm of an `if` and never read afterwards is conflicting there and harmless
  /// -- `fixed_div` binds `n` only on the branch that divides -- and refusing
  /// it rejected a faithful extraction of a helper that works. What matters is
  /// that every READ has a type, and the per-node checks already refuse a read
  /// that does not; this records the same thing for the locals face.
  std::map<std::string, std::map<std::string, Ty>> readLocals;

  /// DECISION 0041 STAGE 2. The arrays methods make on their context's data
  /// stack: method -> local -> the Array.new call. Filled before anything is
  /// derived, and only when the contract declares a region; an array local
  /// is then a writable borrow of the body's integer width, marked scratch.
  std::map<std::string, std::map<std::string, int64_t>> arrayLocals;
  std::map<int64_t, std::pair<std::string, int64_t>> arrayWrites; ///< call -> (method, write node)
  static bool isArrayNewShape(const Node &n, const std::map<int64_t, const Node *> &all) {
    if (n.kind != "CallNode" || str(n, "name") != "new") return false;
    auto r = all.find(ref(n, "receiver"));
    return r != all.end() && r->second->kind == "ConstantReadNode" &&
           str(*r->second, "name") == "Array";
  }
  bool isArrayNew(const Node &n) const { return isArrayNewShape(n, nodes); }
  std::string arrayElement() const { return integerBits == 32 ? "i32" : "i64"; }
  /// Whether `name` in `method` holds an array of the data stack, made
  /// there or lent by a caller.
  bool scratchName(const std::string &method, const std::string &name) const {
    const Borrow b = borrowOfName(method, name);
    return b.isBuffer() && b.scratch;
  }
  bool scratchRead(const Node *n, const std::string &method) const {
    return n && n->kind == "LocalVariableReadNode" && scratchName(method, str(*n, "name"));
  }
  void prescanArrays(const EntryFacts *facts) {
    if (mode != EligibilityMode::CheckedScalar || !facts || !facts->isApplication() ||
        !facts->scratchBytes)
      return;
    for (const auto &kv : definitions) {
      if (kv.second.size() != 1) continue;
      const Node *body = node(ref(*kv.second[0], "body"));
      if (!body || body->kind != "StatementsNode") continue;
      for (auto id : array(*body, "body")) {
        const Node *w = node(id);
        if (!w || w->kind != "LocalVariableWriteNode") continue;
        const Node *v = node(ref(*w, "value"));
        if (!v || !isArrayNew(*v)) continue;
        const std::string local = str(*w, "name");
        if (arrayLocals[kv.first].count(local)) continue;  // refused as a rebinding
        arrayLocals[kv.first][local] = v->id;
        arrayWrites[v->id] = {kv.first, w->id};
      }
    }
  }

  /// What `name` borrows inside `method`, from the contract for the entry and
  /// from the derivation for everything else. An ordinary scalar answers None.
  Borrow borrowOfName(const std::string &method, const std::string &name) const {
    const Method *m = methodNamed(method);
    if (!m) return {};
    for (size_t i = 0; i < m->parameters.size(); ++i) {
      if (m->parameters[i].name != name) continue;
      if (entryBuffers && method == entryBuffers->entry) {
        const EntryBufferFact *b = entryBuffers->buffer(name);
        if (!b) return {};
        Borrow r;
        r.kind = Borrow::Kind::Buffer;
        r.element = b->element;
        r.readOnly = b->readOnly;
        r.cross = b->cross;
        r.origin = name;
        return r;
      }
      auto it = borrowFacts.parameters.find(method);
      if (it == borrowFacts.parameters.end()) return {};
      auto s = it->second.find(i);
      return s == it->second.end() ? Borrow{} : s->second;
    }
    if (auto ml = arrayLocals.find(method); ml != arrayLocals.end())
      if (ml->second.count(name)) {
        Borrow r;
        r.kind = Borrow::Kind::Buffer;
        r.element = arrayElement();
        r.readOnly = false;
        r.origin = "<scratch>";
        r.scratch = true;
        return r;
      }
    return {};
  }
  /// Whether this method's parameter named `name` is an address at all --
  /// which is the question every place that used to ask "is this the entry".
  bool borrowsName(const std::string &method, const std::string &name) const {
    const Borrow b = borrowOfName(method, name);
    return b.kind != Borrow::Kind::None;
  }

  /// DECISION 0008 TASK 4. Which nodes are in STATEMENT position -- where
  /// nothing reads the value.
  ///
  /// Ruby gives a branch that did not run the value `nil`, and there is no nil
  /// in this subset. A missing `else` is therefore admissible exactly when
  /// nothing reads what it would have produced, and that is a question about
  /// the tree, not about a type: every element of a body but the last, every
  /// statement of a loop body, and the arms of a conditional that is itself in
  /// statement position.
  std::set<int64_t> statementPos;
  /// How many loops enclose the node being walked. `break` and `next` need
  /// one; 0008 admits no labelled loop, so the nearest is the only one there
  /// is to name.
  int loopDepth = 0;
  /// DECISION 0041: the admitted blocks around the node being inspected.
  int64_t blockDepth = 0;
  bool inStatementPos(int64_t id) const { return statementPos.count(id) != 0; }

  void markPositions(int64_t id, bool valueConsumed) {
    const Node *n = node(id);
    if (!n) return;
    if (!valueConsumed) statementPos.insert(id);
    const std::string &k = n->kind;
    if (k == "StatementsNode") {
      const auto body = array(*n, "body");
      for (size_t i = 0; i < body.size(); ++i)
        markPositions(body[i], valueConsumed && i + 1 == body.size());
      return;
    }
    if (k == "IfNode" || k == "UnlessNode") {
      const auto pred = ref(*n, "predicate");
      if (pred >= 0) markPositions(pred, true);
      for (const char *arm : {"statements", "subsequent", "else_clause"}) {
        const auto a = ref(*n, arm);
        if (a >= 0) markPositions(a, valueConsumed);
      }
      return;
    }
    if (k == "CallNode") {
      // DECISION 0041: a loop's receiver and limit are read; its block's body
      // is a sequence of statements, as a `while` body is.
      core::BlockLoopShape shape = blockLoopShape(*n);
      if (shape.loop) {
        markPositions(shape.loop->receiver, true);
        if (shape.loop->limit >= 0) markPositions(shape.loop->limit, true);
        if (shape.loop->body >= 0) markPositions(shape.loop->body, false);
        return;
      }
    }
    if (k == "WhileNode" || k == "UntilNode") {
      const auto pred = ref(*n, "predicate");
      if (pred >= 0) markPositions(pred, true);
      // A loop is a statement here: it produces nothing, so nothing in its
      // body is read for a value.
      const auto st = ref(*n, "statements");
      if (st >= 0) markPositions(st, false);
      return;
    }
    // Everything else consumes what its children produce.
    for (const AstField &f : n->fields) {
      if (f.kind == AstField::Kind::Reference) {
        const auto c = std::get<int64_t>(f.value);
        if (c >= 0) markPositions(c, true);
      } else if (f.kind == AstField::Kind::Array) {
        for (auto c : std::get<std::vector<int64_t>>(f.value))
          if (c >= 0) markPositions(c, true);
      }
    }
  }

  const Method *methodNamed(const std::string &name) const {
    auto d = definitions.find(name);
    if (d == definitions.end() || d->second.size() != 1) return nullptr;
    return binding(*d->second[0]);
  }
  const Node *definitionNamed(const std::string &name) const {
    auto d = definitions.find(name);
    if (d == definitions.end() || d->second.size() != 1) return nullptr;
    return d->second[0];
  }

  void recordNode(int64_t id, Ty t) {
    auto it = derivedNode.find(id);
    derivedNode[id] = it == derivedNode.end() ? t : joinTy(it->second, t);
  }

  static bool isComparisonName(const std::string &n) {
    return n == "<" || n == "<=" || n == ">" || n == ">=" || n == "==" || n == "!=";
  }
  static bool isBinaryArithName(const std::string &n) {
    return n == "+" || n == "-" || n == "*" || n == "/" || n == "%" ||
           n == "<<" || n == ">>" || n == "&" || n == "|" || n == "^" ||
           n == "**";
  }
  static bool isUnaryArithName(const std::string &n) {
    return n == "-@" || n == "+@" || n == "~" || n == "abs";
  }

  Ty derive(int64_t id, const std::string &m, Env &env) {
    const Node *n = node(id);
    if (!n) return Ty::Unreached;
    const Ty t = deriveKind(*n, m, env);
    recordNode(id, t);
    return t;
  }

  Ty deriveKind(const Node &n, const std::string &m, Env &env) {
    const std::string &k = n.kind;
    if (k == "IntegerNode") return Ty::Int;
    // Decision 0014 §7: a literal is an address of constant bytes -- a buffer,
    // and only where a call admits one. Whether it stands in an admitted
    // position is decided by the call, not here.
    if (k == "StringNode") return application() ? Ty::Buffer : Ty::Unreached;
    if (k == "ConstantReadNode")
      return constantValues.count(str(n, "name")) ? Ty::Int : Ty::Conflict;
    if (k == "ConstantPathNode") {
      const Node *p = node(ref(n, "parent"));
      if (!p || p->kind != "ConstantReadNode") return Ty::Conflict;
      return constantValues.count(str(*p, "name") + "::" + str(n, "name")) ? Ty::Int
                                                                           : Ty::Conflict;
    }
    if (k == "StatementsNode") {
      Ty last = Ty::Unreached;
      for (auto id : array(n, "body")) last = derive(id, m, env);
      return last;
    }
    if (k == "ParenthesesNode") {
      const auto body = ref(n, "body");
      return body < 0 ? Ty::Unreached : derive(body, m, env);
    }
    if (k == "ElseNode") {
      const auto st = ref(n, "statements");
      return st < 0 ? Ty::Unreached : derive(st, m, env);
    }
    if (k == "LocalVariableReadNode") {
      const std::string name = str(n, "name");
      if (entryBuffers && m == entryBuffers->entry) readParameters.insert(name);
      auto it = env.find(name);
      const Ty t = it == env.end() ? Ty::Unreached : it->second;
      auto &slot = readLocals[m][name];
      slot = joinTy(slot, t);
      return t;
    }
    if (k == "LocalVariableWriteNode") {
      const auto v = ref(n, "value");
      const Ty t = v < 0 ? Ty::Unreached : derive(v, m, env);
      const std::string name = str(n, "name");
      // An assignment REPLACES the binding rather than joining with it: the
      // old value is gone. Joining would keep a type the program no longer has.
      const bool valueless = t == Ty::NoReturn || t == Ty::NilValue;
      env[name] = valueless ? Ty::Conflict : t;
      return valueless ? Ty::Conflict : t;
    }
    if (k == "LocalVariableOperatorWriteNode") {
      const auto v = ref(n, "value");
      const Ty rhs = v < 0 ? Ty::Unreached : derive(v, m, env);
      const std::string name = str(n, "name");
      auto cur = env.find(name);
      const Ty had = cur == env.end() ? Ty::Unreached : cur->second;
      const Ty out = applyOp({rhs, had}, Ty::Int, Ty::Int);
      env[name] = out;
      return out;
    }
    if (k == "ReturnNode") {
      const auto argsId = ref(n, "arguments");
      const Node *a = argsId < 0 ? nullptr : node(argsId);
      std::vector<int64_t> items = a ? array(*a, "arguments") : std::vector<int64_t>{};
      if (items.size() == 1) {
        const Ty t = derive(items[0], m, env);
        auto &slot = derivedReturns[m];
        slot = joinTy(slot, t);
      }
      return Ty::NoReturn;
    }
    // `break` and `next` leave the statement that follows unreached, the same
    // shape a `return` has. Saying so here is what stops the rest of the body
    // from being derived as if the flow had continued into it.
    if (k == "BreakNode" || k == "NextNode") return Ty::NoReturn;
    if (k == "IfNode" || k == "UnlessNode") {
      const auto pred = ref(n, "predicate");
      const Ty p = pred < 0 ? Ty::Unreached : derive(pred, m, env);
      const auto st = ref(n, "statements");
      const auto sub = ref(n, k == "UnlessNode" ? "else_clause" : "subsequent");
      Env thenEnv = env, elseEnv = env;
      const Ty a = st < 0 ? Ty::Unreached : derive(st, m, thenEnv);
      const Ty b = sub < 0 ? Ty::Unreached : derive(sub, m, elseEnv);
      // A branch that does not fall through contributes no bindings to what
      // follows, so the other one's environment is what continues.
      // Only a NON-FALLTHROUGH arm contributes no bindings. An arm ending in a
      // `while` does fall through, and its bindings are as real as the other's.
      if (a == Ty::NoReturn && b != Ty::NoReturn) env = elseEnv;
      else if (b == Ty::NoReturn && a != Ty::NoReturn) env = thenEnv;
      else env = joinEnv(thenEnv, elseEnv);
      // A missing arm in statement position is not a conflict: nothing reads
      // the value, so there is nothing to join. A name the taken arm bound is
      // still joined against the environment that skipped it, which is what
      // makes reading such a name refused where it is READ.
      //
      // IT CARRIES NIL; IT DOES NOT FAIL TO ARRIVE. This returned NoReturn,
      // and NoReturn means something else -- that control never leaves the
      // arm. The join above reads it that way: an arm reported NoReturn has
      // its environment DISCARDED, because a `return` really does contribute
      // no bindings to what follows. A missing `else` contributes plenty.
      //
      // Mac review of 4a8ba23 reported the consequence and it reproduced:
      //
      //     def dc_entry(a)
      //       if a > 0
      //         if a > 1 then x = 7 end   # statement position, no else
      //       else
      //         x = 9
      //       end
      //       x
      //     end
      //
      // The inner `if` answered NoReturn, so the outer one threw away the
      // then-environment and typed `x` from the else arm alone -- where it is
      // bound. `x` read as a well-typed integer and `dc_entry(1)` returned
      // status OK with 0, where CRuby gives nil. With `x = 3` ahead of it both
      // give 3, which is why the shape looked sound.
      //
      // `NilValue` is the answer that says "no value" without also saying
      // "does not fall through", so the environments join and reading `x`
      // is refused where it is read.
      if (sub < 0 && inStatementPos(n.id) && st >= 0) return Ty::NilValue;
      if (st < 0 || sub < 0) return Ty::Conflict;
      const Ty value = joinTy(a, b);
      // The predicate has to be a boolean, but "not yet known" is not "not a
      // boolean": it means come back next round.
      if (p == Ty::Unreached || value == Ty::Unreached) return Ty::Unreached;
      if (p != Ty::Bool) return Ty::Conflict;
      return value;
    }
    if (k == "WhileNode" || k == "UntilNode") {
      const auto pred = ref(n, "predicate"), st = ref(n, "statements");
      // The environment at the loop HEAD is the least fixpoint of
      //   head = join(head_before, head after one body pass)
      // and it is iterated until it stops moving rather than a fixed number of
      // times. It terminates because `joinEnv` only ever adds names and only
      // ever moves a name up a lattice of height three, so the chain is
      // strictly ascending in a finite lattice. The bound below is a backstop
      // for a shape this reasoning does not cover, and exceeding it REFUSES
      // rather than proceeding with whatever the last pass happened to say.
      Env head = env;
      bool settled = false;
      for (int pass = 0; pass < loopPassBound; ++pass) {
        Env body = head;
        if (pred >= 0) derive(pred, m, body);
        if (st >= 0) derive(st, m, body);
        Env next = joinEnv(head, body);
        if (next == head) { settled = true; break; }
        head = next;
      }
      if (!settled) derivationUnsettled = true;
      env = head;
      if (pred >= 0) {
        const Ty p = derive(pred, m, env);
        if (p == Ty::Unreached) return Ty::Unreached;
        if (p != Ty::Bool) return Ty::Conflict;
      }
      return Ty::NilValue;
    }
    if (k == "TrueNode" || k == "FalseNode") return Ty::Bool;
    if (k == "IndexOperatorWriteNode") {
      const auto recv = ref(n, "receiver"), argsId = ref(n, "arguments"),
                 v = ref(n, "value");
      const Ty rt = recv < 0 ? Ty::Unreached : derive(recv, m, env);
      Ty it = Ty::Unreached;
      if (argsId >= 0) {
        const Node *a = node(argsId);
        if (a && a->kind == "ArgumentsNode") {
          const auto items = array(*a, "arguments");
          if (items.size() == 1) it = derive(items[0], m, env);
        }
      }
      const Ty vt = v < 0 ? Ty::Unreached : derive(v, m, env);
      if (rt != Ty::Buffer) return rt == Ty::Unreached ? Ty::Unreached : Ty::Conflict;
      return applyOp({it, vt}, Ty::Int, Ty::Int);
    }
    if (k == "AndNode" || k == "OrNode") {
      const auto l = ref(n, "left"), r = ref(n, "right");
      const Ty a = l < 0 ? Ty::Unreached : derive(l, m, env);
      // THE RIGHT SIDE MAY NOT RUN, so its bindings are CONDITIONAL -- exactly
      // like an arm of an `if` with no else, and joined the same way against
      // the environment that skipped it.
      //
      // Deriving it straight into `env` recorded a first binding made there as
      // if it always happened, and a later read of that local then looked
      // well-typed. Mac review of 270fa5a reported the consequence and it
      // reproduced: `(flag != 0) && (t = buf[0]) > 0` followed by `t` gives nil
      // in CRuby on the skipped path and gave status OK with result 0 here,
      // with no diagnostic. Every local is seeded with zero at function entry
      // to keep the environment total for the merge blocks, and with nothing
      // refusing the read that seed became the answer.
      //
      // `if`, `if`/`else` and `while` were already right, because each of them
      // forks the environment and joins. This is the one conditional context
      // that was not doing it.
      Env skipped = env;
      const Ty b = r < 0 ? Ty::Unreached : derive(r, m, env);
      env = joinEnv(env, skipped);
      return applyOp({a, b}, Ty::Bool, Ty::Bool);
    }
    if (k == "CallNode") {
      core::BlockLoopShape shape = blockLoopShape(n);
      if (shape.loop) return deriveBlockLoop(*shape.loop, m, env);
      return deriveCall(n, m, env);
    }
    return Ty::Unreached;
  }

  /// DECISION 0041 stage 1. As a `while`: the environment at the head is the
  /// least fixpoint of head = join(before, after one pass). Each pass binds
  /// the parameters (integers: a count, an index, or an element, which every
  /// load widens to an integer) and drops the block's own locals, which Ruby
  /// makes afresh on every iteration, so a read before their assignment is
  /// unbound.
  Ty deriveBlockLoop(const core::BlockLoop &loop, const std::string &m, Env &env) {
    using K = core::BlockLoop::Kind;
    const bool overBuffer = loop.kind == K::Each || loop.kind == K::EachWithIndex;
    const Ty recv = derive(loop.receiver, m, env);
    if (recv == Ty::Unreached) return Ty::Unreached;
    if (recv != (overBuffer ? Ty::Buffer : Ty::Int)) return Ty::Conflict;
    if (loop.limit >= 0) {
      const Ty lim = derive(loop.limit, m, env);
      if (lim == Ty::Unreached) return Ty::Unreached;
      if (lim != Ty::Int) return Ty::Conflict;
    }
    Env head = env;
    bool settled = false;
    for (int pass = 0; pass < loopPassBound; ++pass) {
      Env body = head;
      for (const std::string &l : loop.locals) body.erase(l);
      for (const std::string &p : loop.params) body[p] = Ty::Int;
      if (loop.body >= 0) derive(loop.body, m, body);
      Env next = joinEnv(head, body);
      if (next == head) { settled = true; break; }
      head = next;
    }
    if (!settled) derivationUnsettled = true;
    env = head;
    return Ty::NilValue;
  }

  Ty deriveCall(const Node &n, const std::string &m, Env &env) {
    const auto receiver = ref(n, "receiver"), argsId = ref(n, "arguments");
    const std::string name = str(n, "name");
    std::vector<int64_t> args;
    if (argsId >= 0) {
      const Node *a = node(argsId);
      if (a && a->kind == "ArgumentsNode") args = array(*a, "arguments");
    }
    // DECISION 0014: an extern call. The receiver is a constant naming a
    // declared module; it is a name, not a value, and is not derived. The
    // call's type is what the contract declares the extern returns, or nil
    // when it returns nothing -- nil meets a type as a conflict, so a value
    // read from a void extern is refused where it is read.
    // DECISION 0041 STAGE 2: an admitted `Array.new(n, v)` is an array: an
    // Integer size and an Integer literal fill.
    if (isArrayNew(n)) {
      std::vector<Ty> at;
      for (auto id : args) at.push_back(derive(id, m, env));
      if (!arrayWrites.count(n.id) || at.size() != 2) return Ty::Conflict;
      if (at[0] == Ty::Unreached) return Ty::Unreached;
      const Node *fill = node(args[1]);
      return at[0] == Ty::Int && fill && fill->kind == "IntegerNode" ? Ty::Buffer : Ty::Conflict;
    }
    if (const ExternFact *ext = externOf(n)) {
      for (auto id : args) derive(id, m, env);
      return ext->returns ? Ty::Int : Ty::NilValue;
    }
    if (receiver >= 0) {
      const Ty rt = derive(receiver, m, env);
      std::vector<Ty> at;
      for (auto id : args) at.push_back(derive(id, m, env));
      // A buffer access. The element type is the CONTRACT's, and every load
      // widens to i64, so the value is an integer whichever element type it
      // came from. A store's value is the integer it was given.
      if (name == "[]")
        return rt == Ty::Buffer && at.size() == 1
                   ? applyOp({at[0]}, Ty::Int, Ty::Int)
                   : (rt == Ty::Unreached ? Ty::Unreached : Ty::Conflict);
      if (name == "[]=")
        return rt == Ty::Buffer && at.size() == 2
                   ? applyOp({at[0], at[1]}, Ty::Int, Ty::Int)
                   : (rt == Ty::Unreached ? Ty::Unreached : Ty::Conflict);
      // Decision 0041 stage 2: an array's size is its count.
      if (name == "size")
        return rt == Ty::Buffer && args.empty() ? Ty::Int
                                                : (rt == Ty::Unreached ? Ty::Unreached : Ty::Conflict);
      if (name == "!")
        return args.empty() ? applyOp({rt}, Ty::Bool, Ty::Bool) : Ty::Conflict;
      if (isComparisonName(name))
        return at.size() == 1 ? applyOp({rt, at[0]}, Ty::Int, Ty::Bool)
                              : Ty::Conflict;
      if (isUnaryArithName(name))
        return args.empty() ? applyOp({rt}, Ty::Int, Ty::Int) : Ty::Conflict;
      if (isBinaryArithName(name))
        return at.size() == 1 ? applyOp({rt, at[0]}, Ty::Int, Ty::Int)
                              : Ty::Conflict;
      return Ty::Conflict;
    }
    std::vector<Ty> at;
    for (auto id : args) at.push_back(derive(id, m, env));
    // The intrinsic never returns, so it has no value and binds nothing.
    if (name == "core_fail" && !definitions.count("core_fail")) return Ty::NoReturn;
    // DECISION 0022: a word intrinsic takes Integers and answers an Integer or,
    // for the unsigned comparisons, a Boolean. A wrong arity has no type.
    if (const CoreIntrinsic *in = coreIntrinsic(name); in && !definitions.count(name)) {
      if (at.size() != in->arity) return Ty::Conflict;
      // core_u32(LIT) is a constant whatever its literal's own type, which at
      // 32 bits is wider than an Integer (decision 0042 stage 4).
      if (in->literal) return Ty::Int;
      bool pending = false;
      for (Ty t : at) {
        if (t == Ty::Unreached) pending = true;
        else if (t != Ty::Int) return Ty::Conflict;
      }
      return pending ? Ty::Unreached : (in->boolean ? Ty::Bool : Ty::Int);
    }
    const Method *callee = methodNamed(name);
    if (!callee || callee->parameters.size() != at.size()) return Ty::Unreached;
    // Bind the callee's parameters from THIS call site by JOINING, so a callee
    // reached at two types becomes Conflict and stays there. Assigning a
    // marker instead made the state oscillate, and the round loop then ran to
    // its bound every time without ever reporting that it had not settled.
    auto &slots = derivedParams[name];
    if (slots.size() != at.size()) {
      slots.assign(at.size(), Ty::Unreached);
      signaturesChanged = true;
    }
    for (size_t i = 0; i < at.size(); ++i) {
      const Ty next = joinTy(slots[i], at[i]);
      if (next != slots[i]) { slots[i] = next; signaturesChanged = true; }
    }
    // DECISION 0008 TASK 3: an address that arrives at a callee. The type
    // derivation above already says `buffer`; what it does not say is WHICH
    // buffer, and the callee needs the element type and the mode to be checked
    // against. Version 1 resolves a borrowed argument only as a direct
    // parameter name, the same limit the index already has -- an expression
    // that produced a buffer would have to be a buffer-valued expression, and
    // nothing in this subset produces one.
    // DECISION 0008 TASK 3. One mutable buffer passed twice gives the callee
    // two names for one storage, and nothing in the callee could tell that a
    // write through one is visible through the other. A read-only buffer
    // passed twice is fine and is a positive control -- reading the same
    // bytes twice is reading the same bytes twice.
    {
      std::map<std::string, size_t> byName;
      for (size_t i = 0; i < args.size(); ++i) {
        if (at[i] != Ty::Buffer) continue;
        const Node *a = node(args[i]);
        if (!a || a->kind != "LocalVariableReadNode") continue;
        const std::string an = str(*a, "name");
        const Borrow held = borrowOfName(m, an);
        if (!held.isBuffer() || held.readOnly) continue;
        auto prior = byName.find(an);
        if (prior != byName.end()) {
          issue(&n, "duplicate-mutable-argument",
                an + " is passed to " + name + " at argument " +
                    std::to_string(prior->second) + " and argument " +
                    std::to_string(i) +
                    "; one writable buffer under two names is an alias the "
                    "callee cannot see", "REFUSED");
          break;
        }
        byName[an] = i;
      }
    }
    for (size_t i = 0; i < args.size(); ++i) {
      if (at[i] != Ty::Buffer) continue;
      const Node *a = node(args[i]);
      Borrow incoming;
      if (a && a->kind == "LocalVariableReadNode")
        incoming = borrowOfName(m, str(*a, "name"));
      // Decision 0014 §7: a literal handed to a helper is a read-only u8
      // buffer for that parameter, from no entry parameter at all.
      if (a && a->kind == "StringNode" && application()) {
        incoming.kind = Borrow::Kind::Buffer;
        incoming.element = "u8";
        incoming.readOnly = true;
        incoming.origin = "<literal>";
      }
      if (incoming.kind == Borrow::Kind::None) {
        // A buffer arrived that this pass cannot attribute to a parameter.
        // Refusing here rather than lowering it keeps the limit at the call.
        Borrow unattributed;
        unattributed.kind = Borrow::Kind::Conflict;
        unattributed.element = "an expression that is not a buffer parameter";
        incoming = unattributed;
      }
      if (recordBorrow(borrowFacts, name, i, incoming)) signaturesChanged = true;
    }
    pendingCallees.push_back(name);
    auto r = derivedResult.find(name);
    return r == derivedResult.end() ? Ty::Unreached : r->second;
  }

  void deriveMethod(const std::string &name) {
    const Node *def = definitionNamed(name);
    const Method *m = methodNamed(name);
    if (!def || !m) return;
    Env env;
    auto slots = derivedParams.find(name);
    if (slots != derivedParams.end() && slots->second.size() == m->parameters.size())
      for (size_t i = 0; i < m->parameters.size(); ++i)
        env[m->parameters[i].name] = slots->second[i];
    derivedReturns[name] = Ty::Unreached;
    readLocals[name].clear();
    const auto body = ref(*def, "body");
    const Ty last = body < 0 ? Ty::Unreached : derive(body, name, env);
    const Ty result = joinTy(derivedReturns[name], last);
    auto &slot = derivedResult[name];
    const Ty next = joinTy(slot, result);
    if (next != slot) { slot = next; signaturesChanged = true; }
    derivedLocals[name] = env;
  }

  /// The iteration bounds, computed rather than picked.
  ///
  /// A round that does not terminate has moved at least one signature cell
  /// strictly UP a four-element lattice (Unreached -> a type -> Conflict), and
  /// cells never move down. So the number of rounds that can fail to settle is
  /// at most three per cell, and `3 * cells + 1` cannot be exceeded by any
  /// input. The same argument bounds a loop: a pass that does not terminate
  /// has moved one environment cell up, or added a name, and neither is undone.
  ///
  /// The refusal below is therefore defence in depth rather than a case any
  /// program reaches -- and it is declared as such rather than presented as a
  /// tested path. What IS tested is that a long helper chain, which needs one
  /// round per link, converges: `refuse/` holds a seventy-deep one, accepted.
  int deriveRoundBound = 1;
  int loopPassBound = 1;

  void computeBounds() {
    int cells = 0;
    for (const auto &kv : definitions) {
      if (kv.second.size() != 1) continue;
      const Method *m = methodNamed(kv.first);
      if (!m) continue;
      cells += static_cast<int>(m->parameters.size()) + 1;
    }
    deriveRoundBound = 3 * cells + 1;
    int names = 0;
    for (const auto &l : module.locals()) { (void)l; ++names; }
    loopPassBound = 4 * (names + 1);
  }

  void deriveFacts(const EntryFacts &facts) {
    const Method *entry = methodNamed(facts.entry);
    if (!entry) return;  // reported by the ordinary checks
    if (entry->parameters.size() != facts.parameters.size()) return;
    for (size_t i = 0; i < facts.parameters.size(); ++i)
      if (entry->parameters[i].name != facts.parameters[i]) return;
    factsSupplied = true;
    computeBounds();
    entryBuffers = &facts;
    derivedParams[facts.entry].assign(facts.parameters.size(), Ty::Int);
    for (size_t i = 0; i < facts.parameters.size(); ++i)
      if (facts.buffer(facts.parameters[i]))
        derivedParams[facts.entry][i] = Ty::Buffer;

    bool settled = false;
    for (int round = 0; round < deriveRoundBound; ++round) {
      signaturesChanged = false;
      // Node types are recomputed from scratch against the CURRENT signatures.
      // Keeping them across rounds is what let a retracted type stay readable.
      derivedNode.clear();
      derivedLocals.clear();
      std::set<std::string> seen;
      std::vector<std::string> work{facts.entry};
      while (!work.empty()) {
        const std::string name = work.back();
        work.pop_back();
        if (!seen.insert(name).second) continue;
        pendingCallees.clear();
        deriveMethod(name);
        for (const auto &c : pendingCallees)
          if (!seen.count(c)) work.push_back(c);
      }
      if (!signaturesChanged) { settled = true; break; }
    }
    if (!settled) derivationUnsettled = true;
    // An integer literal is an integer wherever it appears, including at the
    // top level, where the environment check wants to see that an inference
    // call's arguments are literals. Nothing is proved by deriving it and
    // nothing is assumed by stating it.
    for (const auto &n : module.nodes())
      if (n.kind == "IntegerNode") derivedNode[n.id] = Ty::Int;
  }

  std::string derivedParamType(const Method &m, size_t i,
                               const std::string &fallback) const {
    if (!factsSupplied) return fallback;
    auto it = derivedParams.find(m.name);
    if (it == derivedParams.end() || i >= it->second.size()) return "unknown";
    return tyName(it->second[i]);
  }
  std::string derivedMethodResult(const Method &m,
                                  const std::string &fallback) const {
    if (!factsSupplied) return fallback;
    auto it = derivedResult.find(m.name);
    return it == derivedResult.end() ? "unknown" : tyName(it->second);
  }
  /// The type this local had where it was READ, or "unread" if it never was.
  /// A local nothing reads cannot affect the program, and its type at the end
  /// of the method says nothing about one.
  std::string derivedLocalType(const Method &m, const std::string &name,
                               const std::string &fallback) const {
    if (!factsSupplied) return fallback;
    auto scope = readLocals.find(m.name);
    if (scope == readLocals.end()) return "unknown";
    auto it = scope->second.find(name);
    if (it == scope->second.end()) return "unread";
    return tyName(it->second);
  }

  /// The derived answer where there is one, and the producer's otherwise. Not
  /// a fallback that softens anything: with facts supplied the derivation is
  /// what the checks below read, and a node it could not type reads as
  /// `unknown`, which they refuse.
  std::string factType(int64_t id, const std::string &fallback) const {
    if (!factsSupplied) return fallback;
    auto it = derivedNode.find(id);
    return it == derivedNode.end() ? "unknown" : tyName(it->second);
  }


  /// The extern a call node names, or null: a CallNode whose receiver is a
  /// ConstantReadNode naming a declared module, with a declared `fn`.
  const ExternFact *externOf(const Node &n) const {
    if (!application() || n.kind != "CallNode") return nullptr;
    const auto receiver = ref(n, "receiver");
    const Node *recv = receiver >= 0 ? node(receiver) : nullptr;
    if (!recv || recv->kind != "ConstantReadNode") return nullptr;
    return entryBuffers->externNamed(str(*recv, "name"), str(n, "name"));
  }

  /// A condition operand at one call site: an integer literal is itself; a
  /// name is the argument passed for that parameter, when it is a literal or
  /// a resolved constant; `len(name)` is the constant count of the buffer
  /// passed, or a literal's byte length. Anything else is not decidable.
  std::optional<int64_t> staticOperand(StringRef operand, const ExternFact &ext,
                                       const std::vector<int64_t> &args,
                                       const std::string &owner) const {
    int64_t v = 0;
    if (!operand.getAsInteger(10, v)) return v;
    const bool len = operand.consume_front("len(");
    if (len) operand.consume_back(")");
    for (size_t i = 0; i < ext.args.size() && i < args.size(); ++i) {
      if (ext.args[i].name != operand) continue;
      const Node *a = node(args[i]);
      if (!a) return std::nullopt;
      if (len) {
        if (a->kind == "StringNode") return static_cast<int64_t>(str(*a, "content").size());
        if (a->kind == "LocalVariableReadNode" && entryBuffers) {
          const Borrow b = borrowOfName(owner, str(*a, "name"));
          if (const EntryBufferFact *f = b.isBuffer() ? entryBuffers->buffer(b.origin) : nullptr)
            if (f->constCount) return static_cast<int64_t>(*f->constCount);
        }
        return std::nullopt;
      }
      if (a->kind == "IntegerNode") return literalValue(*a);
      if (a->kind == "ConstantReadNode") {
        auto c = constantValues.find(str(*a, "name"));
        if (c != constantValues.end()) return c->second;
      }
      // DECISION 0014 D5: `Led::LED0` as an extern argument, so const_args
      // carries its value the way a top-level constant's is carried
      if (a->kind == "ConstantPathNode") {
        const Node *p = node(ref(*a, "parent"));
        if (p && p->kind == "ConstantReadNode") {
          auto c = constantValues.find(str(*p, "name") + "::" + str(*a, "name"));
          if (c != constantValues.end()) return c->second;
        }
      }
      return std::nullopt;
    }
    return std::nullopt;
  }

  /// DECISION 0014 §6: an extern call is checked against its declaration --
  /// context, arity, each argument's kind, domain and mode, no cross buffer,
  /// and every `static` requirement decided from constant operands here.
  void externCall(const Node &n, const Method &owner, const std::string &module,
                  const std::string &fn, const std::vector<int64_t> &args) {
    // A refused call is refused once, by its own reason: its literal arguments
    // are not reported a second time for their position.
    for (auto id : args)
      if (const Node *a = node(id); a && a->kind == "StringNode") admittedLiterals.insert(id);
    const ExternFact *ext = entryBuffers->externNamed(module, fn);
    if (!ext) {
      issue(&n, "unresolved-call",
            module + "." + fn + " is not an extern the contract declares", "REFUSED");
      return;
    }
    if (entryBuffers->context == "interrupt" && !ext->isrOk) {
      issue(&n, "extern-context",
            module + "." + fn + " is not isr_ok, and this entry runs in interrupt context",
            "REFUSED");
      return;
    }
    if (args.size() != ext->args.size()) {
      issue(&n, "extern-arity",
            module + "." + fn + " takes " + std::to_string(ext->args.size()) +
                " argument(s), " + std::to_string(args.size()) + " given", "REFUSED");
      return;
    }
    for (size_t i = 0; i < args.size(); ++i) {
      const ExternArgFact &d = ext->args[i];
      const Node *a = node(args[i]);
      const std::string where = module + "." + fn + " argument " + d.name;
      // DECISION 0041 STAGE 2: before the argument's type: an array on the
      // data stack reaches no extern, whatever the extern takes.
      if (scratchRead(a, owner.name)) {
        issue(&n, "array-escape",
              str(*a, "name") + " is a Core::Buffer on the data stack, and it is not "
              "passed to an extern: the extern could keep it past the return that frees it",
              "REFUSED");
        return;
      }
      if (!d.isBuffer) {
        if (type(args[i]) == "buffer") {
          issue(&n, "extern-mode", where + " is a scalar, and a buffer was passed", "REFUSED");
          return;
        }
        if (type(args[i]) != "int") {
          issue(&n, "extern-domain", where + " must be a proven integer, not " + type(args[i]), "REFUSED");
          return;
        }
        continue;
      }
      if (a && a->kind == "StringNode") {
        if (d.domain != "u8") {
          issue(&n, "extern-domain", where + " is a " + d.domain + " buffer; a literal is u8 bytes", "REFUSED");
          return;
        }
        if (!d.readOnly) {
          issue(&n, "writes-on-in",
                where + " is inout, and a literal is constant bytes nothing may write", "REFUSED");
          return;
        }
        admittedLiterals.insert(args[i]);
        continue;
      }
      Borrow held;
      if (a && a->kind == "LocalVariableReadNode") held = borrowOfName(owner.name, str(*a, "name"));
      if (!held.isBuffer()) {
        issue(&n, "extern-mode", where + " is a buffer, and no buffer parameter was passed", "REFUSED");
        return;
      }
      if (held.element != d.domain) {
        issue(&n, "extern-domain",
              where + " is a " + d.domain + " buffer; " + str(*a, "name") + " holds " + held.element, "REFUSED");
        return;
      }
      if (!d.readOnly && held.readOnly) {
        issue(&n, "writes-on-in",
              where + " is inout, and " + str(*a, "name") + " is borrowed read-only here", "REFUSED");
        return;
      }
      if (held.cross) {
        issue(&n, "cross-to-extern",
              str(*a, "name") + " is a cross buffer, and a cross buffer never reaches an extern (0014 §5)",
              "REFUSED");
        return;
      }
    }
    for (const ExternStaticFact &s : ext->statics) {
      const auto l = staticOperand(s.lhs, *ext, args, owner.name);
      const auto r = staticOperand(s.rhs, *ext, args, owner.name);
      const std::string cond = s.lhs + " " + s.op + " " + s.rhs;
      if (!l || !r) {
        issue(&n, s.diagnostic,
              module + "." + fn + " requires " + cond +
                  ", which is not decidable from constant operands at this call", "REFUSED");
        return;
      }
      const bool holds = s.op == "<" ? *l < *r : s.op == "<=" ? *l <= *r
                       : s.op == ">" ? *l > *r : s.op == ">=" ? *l >= *r
                       : s.op == "==" ? *l == *r : *l != *r;
      if (!holds) {
        issue(&n, s.diagnostic,
              module + "." + fn + " requires " + cond + "; here " + std::to_string(*l) +
                  " " + s.op + " " + std::to_string(*r) + " is false", "REFUSED");
        return;
      }
    }
    ExternCall c;
    c.method = owner.name;
    c.nodeId = n.id;
    c.externIndex = static_cast<size_t>(ext - entryBuffers->externs.data());
    for (size_t i = 0; i < ext->args.size(); ++i)
      c.constArgs.push_back(ext->args[i].isBuffer
                                ? std::nullopt
                                : staticOperand(ext->args[i].name, *ext, args, owner.name));
    report.externCalls.push_back(c);
    // A void extern has no value; where one is read, the derivation has made
    // it nil and the reader refuses it. In statement position there is
    // nothing to check.
    if (ext->returns || !inStatementPos(n.id)) expressionType(n);
  }

  /// DECISION 0045: the buffer call the CORE reader recorded at this node's
  /// place in the source (Core/BufferSpelling.h), or null.
  const contract::BufferSpelling *spellingAt(const Node &n) const {
    const int64_t line = number(n, "node_line", AstField::Kind::Integer, 0);
    const int64_t col = number(n, "node_col", AstField::Kind::Integer, 0);
    const auto fileId = number(n, "node_file", AstField::Kind::Integer);
    for (const auto &src : module.sources())
      if (src.id == fileId && src.path != module.sourceFile()) return nullptr;
    for (const auto &sp : module.bufferSpellings())
      if (sp.line == line && sp.column == col) return &sp;
    return nullptr;
  }
  /// DECISION 0045: an `Array.new` the reader did not write (the Array
  /// spelling, refused by name with its rewrite) and a `Core::Table` (not on
  /// this route in stage 1). `local` is the name the call is assigned to, or
  /// empty. False when refused.
  bool spelledBuffer(const Node &n, const std::string &local) {
    const contract::BufferSpelling *sp = spellingAt(n);
    const std::string to = local.empty() ? "" : local + " = ";
    if (!sp || sp->kind == contract::BufferSpelling::Kind::ArrayNew) {
      const std::string args = sp ? sp->arguments : "n, 0";
      issue(&n, "array-spelling",
            "`" + to + "Array.new(" + args + ")`: a scratch array is `" + to +
                "Core::Buffer." + arrayElement() + "(" + args + ")` (decision 0045)",
            "REFUSED");
      return false;
    }
    if (sp->kind == contract::BufferSpelling::Kind::Table) {
      issue(&n, "array-table",
            "Core::Table." + sp->element + " is an instrument's read-only table "
            "(decision 0043, the MPC route); a method's scratch array is a "
            "Core::Buffer." + arrayElement(), "REFUSED");
      return false;
    }
    return true;
  }

  /// DECISION 0041 STAGE 2: the admitted `a = Core::Buffer.i32(n, v)`, which
  /// the reader gave the analysis as `a = Array.new(n, v)` (decision 0045).
  void arrayNew(const Node &n, const Method &owner) {
    callShape(n);
    std::string local;
    for (const auto &kv : arrayLocals[owner.name])
      if (kv.second == n.id) local = kv.first;
    if (!spelledBuffer(n, local)) return;
    const std::string cls = "Core::Buffer." + spellingAt(n)->element;
    if (spellingAt(n)->element != arrayElement()) {
      const std::string e = spellingAt(n)->element;
      issue(&n, "array-element",
            (isBufferElement(e) ? cls + " in a body of " + std::to_string(integerBits) +
                                      "-bit Integers"
                                : "`" + e + "` is not an element name") +
                "; a scratch array's elements have the body's integer width, "
                "Core::Buffer." + arrayElement(), "REFUSED");
      return;
    }
    if (ref(n, "block") >= 0) {
      issue(&n, "unsupported-block", cls + " takes no block here", "REFUSED");
      return;
    }
    std::vector<int64_t> args;
    if (const Node *a = node(ref(n, "arguments")); a && a->kind == "ArgumentsNode")
      args = array(*a, "arguments");
    if (args.size() != 2) {
      issue(&n, "arity-mismatch",
            cls + " takes a count and optionally a fill, as " + cls + "(n) or " + cls + "(n, 0)");
      return;
    }
    const Node *fill = node(args[1]);
    if (!fill || fill->kind != "IntegerNode") {
      issue(&n, "array-fill",
            "the fill of " + cls + " is an Integer literal; the elements are "
            "Integers of the body's width", "REFUSED");
      return;
    }
    walk(args[1], owner);
    if (type(args[0]) != "int")
      issue(&n, "type-evidence", "the count of " + cls + " must be a proven integer");
    walk(args[0], owner);
    {
      EligibilityReport::ArrayMake a;
      a.method = owner.name;
      for (const auto &kv : arrayLocals[owner.name])
        if (kv.second == n.id) a.local = kv.first;
      a.nodeId = n.id;
      a.line = number(n, "node_line", AstField::Kind::Integer, 0);
      if (const Node *c = node(args[0])) {
        if (c->kind == "IntegerNode") a.count = literalValue(*c);
        else if (c->kind == "ConstantReadNode" && constantValues.count(str(*c, "name")))
          a.count = constantValues.at(str(*c, "name"));
      }
      bool seen = false;
      for (const auto &m : report.arrayMakes) if (m.nodeId == n.id) seen = true;
      if (!seen) report.arrayMakes.push_back(a);
    }
  }

  void call(const Node &n, const Method &owner) {
    callShape(n);
    if (!need(n, "receiver", AstField::Kind::Reference) ||
        !need(n, "arguments", AstField::Kind::Reference) ||
        !need(n, "block", AstField::Kind::Reference)) return;
    if (ref(n, "block") >= 0) issue(&n, "unsupported-node", "calls with blocks are not supported");
    if (!ordinaryCall(n)) issue(&n, "unsupported-call", "nonordinary call operator");
    const std::string name = str(n, "name");
    const auto receiver = ref(n, "receiver"), argsId = ref(n, "arguments");
    std::vector<int64_t> args;
    if (argsId >= 0) {
      const auto *a = node(argsId);
      if (!a || a->kind != "ArgumentsNode") issue(&n, "unsupported-node", "nonordinary arguments");
      else args = array(*a, "arguments");
    }
    // Decision 0007: the contract-only intrinsic is `core_fail(:capacity)`.
    // It is recognised only in this closure, and a conflicting user definition
    // or any other argument is rejected.
    //
    // ONE spelling, not a family. The internal failure categories that
    // compiler-generated failures use are a different set from what an
    // application may request: they overlap, and a request for one of the
    // others would be an application naming a failure only the compiler can
    // establish. So `:capacity` is admitted and everything else -- including
    // the other three statuses and `:ok` -- is refused by name.
    if (receiver < 0 && name == "core_fail" &&
        mode == EligibilityMode::CheckedScalar) {
      // A user definition does not shadow the intrinsic into an ordinary call:
      // the decision says reject, and falling through would compile a call to
      // whichever of the two the closure happened to find.
      if (definitions.count("core_fail")) {
        issue(&n, "conflicting-intrinsic",
              "`core_fail` is defined in this source and is also the "
              "contract-only intrinsic; the two cannot both be meant", "REFUSED");
        return;
      }
      if (args.size() != 1) {
        issue(&n, "arity-mismatch",
              "core_fail takes exactly one argument, the symbol :capacity");
        return;
      }
      const Node *sym = node(args[0]);
      if (!sym || sym->kind != "SymbolNode") {
        issue(&n, "unsupported-node",
              "core_fail takes the symbol literal :capacity; a computed or "
              "interpolated argument names nothing at compile time");
        return;
      }
      shape(*sym, {"value"});
      if (!need(*sym, "value", AstField::Kind::String)) return;
      const std::string category = str(*sym, "value");
      if (category != "capacity")
        issue(&n, "unsupported-status",
              "core_fail(:" + category + ") is not in this version; the only "
              "application-requested failure is core_fail(:capacity)", "REFUSED");
      return;
    }

    // DECISION 0022: a word intrinsic, `core_w32_add(a, b)` and the rest
    // (spinel-mlir/Core/Intrinsics.h), in this closure only. It is a call with
    // no receiver and exactly its arity; the block, keyword and splat forms
    // are refused for every call above and below. A receiver -- `self.` or a
    // constant -- is refused by name rather than resolved as a method, and a
    // top-level definition of the same name is a conflict, never a shadow.
    // Decision 0042 stage 4: on --core (the unchecked mode) too, whose operand
    // types are the reader's, read with the prelude's definitions inserted.
    if (const CoreIntrinsic *in = coreIntrinsic(name); in) {
      if (receiver >= 0) {
        issue(&n, "unsupported-intrinsic-call",
              "`" + name + "` is a CORE intrinsic and is called with no receiver",
              "REFUSED");
        return;
      }
      if (definitions.count(name)) {
        issue(&n, "conflicting-intrinsic",
              "`" + name + "` is defined in this source and is also the CORE "
              "intrinsic; the two cannot both be meant", "REFUSED");
        return;
      }
      if (args.size() != in->arity) {
        issue(&n, "arity-mismatch",
              name + " takes " + std::to_string(in->arity) + " argument(s), " +
                  std::to_string(args.size()) + " given");
        return;
      }
      if (in->wide && integerBits == 32) {
        issue(&n, "unsupported-intrinsic-call",
              "`" + name + "` computes on 64-bit words and this body is 32 bits; "
              "a 64-bit form is refused on a 32-bit body, as int64 is "
              "(decision 0019's revision)", "REFUSED");
        return;
      }
      if (in->literal) {
        // Read, never walked: the literal is the constant's spelling, and at
        // 32 bits it is wider than an Integer.
        if (!u32Literal(args[0]))
          issue(&n, "unsupported-intrinsic-call",
                "core_u32 takes an Integer literal in 0..4294967295", "REFUSED");
        return;
      }
      for (size_t i = 0; i < args.size(); ++i)
        if (type(args[i]) != "int")
          issue(&n, "type-evidence",
                "operand " + std::to_string(i + 1) + " of " + name +
                    " must be a proven integer");
      if (argsId >= 0) walk(argsId, owner);
      return;
    }

    // DECISION 0041 STAGE 2: Array.new anywhere but `a = Array.new(n, v)` as
    // a statement of its method's own body. (The admitted form never gets
    // here: its local write inspects it.)
    if (isArrayNew(n) && mode == EligibilityMode::CheckedScalar && application()) {
      if (!spelledBuffer(n, "")) return;
      if (!entryBuffers->scratchBytes)
        issue(&n, "scratch-missing",
              "Core::Buffer needs this context's data stack, and the application "
              "declares no `scratch <bytes>, context: :" + entryBuffers->context + "`",
              "REFUSED");
      else
        issue(&n, "array-position",
              "Core::Buffer is admitted only as `local = Core::Buffer." + arrayElement() +
                  "(n, v)`, a statement of its method's own body, outside every loop, "
                  "block and branch: the data stack frees a buffer when its method "
                  "returns, and nothing else",
              "REFUSED");
      return;
    }
    // DECISION 0045: a Core::Buffer or Core::Table the reader did not rewrite,
    // because it is not spelled as a call with its parentheses straight after
    // the element name.
    if (const Node *recv = receiver >= 0 ? node(receiver) : nullptr;
        recv && recv->kind == "ConstantPathNode" && mode == EligibilityMode::CheckedScalar &&
        application()) {
      std::string p = pathText(*recv);
      if (p.rfind("::", 0) == 0) p = p.substr(2);
      if (p == "Core::Buffer" || p == "Core::Table") {
        issue(&n, "array-spelling",
              p + "." + name + " is written " + p + "." + arrayElement() + "(count" +
                  (p == "Core::Buffer" ? ", fill" : "") +
                  "), with its parentheses straight after the element name (decision 0045)",
              "REFUSED");
        return;
      }
    }
    if (const Node *recv = receiver >= 0 ? node(receiver) : nullptr;
        mode == EligibilityMode::CheckedScalar && scratchRead(recv, owner.name)) {
      const std::string an = str(*recv, "name");
      if (name == "size") {
        if (!args.empty()) issue(&n, "arity-mismatch", "size takes no arguments");
        expressionType(n);
        return;
      }
      if (name != "[]" && name != "[]=") {
        issue(&n, "array-method",
              "Core::Buffer has no " + name + " (the buffer " + an + "); a Core::Buffer "
              "keeps the size it was made with, and admits only [], []=, size, "
              "each and each_with_index", "REFUSED");
        return;
      }
    }
    if (name == "[]=" && mode == EligibilityMode::CheckedScalar && args.size() == 2)
      if (const Node *v = node(args[1]); scratchRead(v, owner.name)) {
        issue(&n, "array-escape",
              "the Core::Buffer " + str(*v, "name") + " is stored into an element; "
              "a Core::Buffer on the data stack is freed when its maker returns, so it is "
              "never stored", "REFUSED");
        return;
      }
    // DECISION 0014: a call on a declared extern module, `Adc.latest(0)`.
    // Decided here, before the receiver could be read as a constant: the
    // module is a name the contract declared, not a value.
    if (const Node *recv = receiver >= 0 ? node(receiver) : nullptr;
        recv && recv->kind == "ConstantReadNode" && application() &&
        entryBuffers->isExternModule(str(*recv, "name"))) {
      externCall(n, owner, str(*recv, "name"), name, args);
      if (argsId >= 0) walk(argsId, owner);
      return;
    }
    // A literal reaching a HELPER is admitted only where the helper's
    // parameter is a read-only u8 buffer, which the derivation decided from
    // this very call; anywhere else it is refused by position when walked.
    if (receiver < 0 && application())
      for (size_t i = 0; i < args.size(); ++i) {
        const Node *a = node(args[i]);
        if (!a || a->kind != "StringNode") continue;
        auto d = definitions.find(name);
        if (d == definitions.end() || d->second.size() != 1) continue;
        const Method *m = binding(*d->second[0]);
        if (!m || i >= m->parameters.size()) continue;
        const Borrow held = borrowOfName(name, m->parameters[i].name);
        if (held.isBuffer() && held.element == "u8" && held.readOnly)
          admittedLiterals.insert(args[i]);
      }

    if (receiver < 0) {
      // Bind source definitions only. An extern or reflective spelling is not
      // assigned an effect contract based on its name.
      auto d = definitions.find(name);
      if (d != definitions.end() && d->second.size() == 1) {
        if (const auto *m = binding(*d->second[0])) {
          if (args.size() != m->parameters.size()) issue(&n, "arity-mismatch", name);
          for (size_t i = 0; i < args.size() && i < m->parameters.size(); ++i)
            // The callee's parameter type, derived from the entry facts when
            // the contract supplied them: with no caller the producer has
            // nothing to compare against, and comparing an argument to `poly`
            // refuses every call in a caller-free closure.
            if (type(args[i]) != derivedParamType(*m, i, m->parameters[i].type))
              issue(&n, "type-evidence", "argument does not match inferred callee parameter");
        }
      }
      // Decision 0026 step 4: the one place a call into the closure is
      // resolved; consumers read the edge.
      if (visitMethod(name, &n) && edgeNodes.insert(n.id).second)
        report.callEdges.push_back({owner.name, name, n.id});
    } else if (name == "[]" || name == "[]=") {
      // Decision 0007 task 3: indexing IS in the subset, on a declared buffer
      // parameter and nowhere else. Every other receiver keeps the refusal --
      // an indexable Ruby object is a heap object, and there is no heap here.
      // DECISION 0008 TASK 3: the receiver may be the entry's declared buffer
      // or a helper's borrowed one, and the two are answered the same way --
      // by what this parameter of THIS method borrows. A helper has no
      // contract to consult, which is the whole reason the borrow is derived.
      const Node *recv = node(receiver);
      std::string bufName;
      Borrow held;
      if (mode == EligibilityMode::CheckedScalar && entryBuffers && recv &&
          recv->kind == "LocalVariableReadNode" &&
          (bufName = str(*recv, "name"), true))
        held = borrowOfName(owner.name, bufName);
      if (held.kind == Borrow::Kind::Conflict) {
        issue(&n, "borrow-conflict",
              bufName + " is reached as " + held.element +
                  "; one helper parameter cannot be two different buffers",
              "REFUSED");
      } else if (!held.isBuffer()) {
        issue(&n, "heap-operation",
              "Ruby indexing has no ownership-free scalar contract", "REFUSED");
      } else if (name == "[]=" && held.readOnly) {
        // The mode is the whole promise: a caller that passed read-only
        // storage has been told nothing will be written to it. A helper
        // inherits that promise from every call that reaches it, so one
        // read-only caller makes the helper read-only.
        issue(&n, "readonly-write",
              bufName + " is borrowed read-only here, and this writes to it",
              "REFUSED");
      } else {
        const size_t want = name == "[]" ? 1u : 2u;
        if (args.size() != want)
          issue(&n, "arity-mismatch",
                name + " on a buffer takes " + std::to_string(want) + " argument(s)");
        else if (type(args[0]) != "int")
          issue(&n, "type-evidence", "a buffer index must be a proven integer");
        else if (want == 2 && type(args[1]) != "int")
          issue(&n, "type-evidence", "a buffer element must be a proven integer");
      }
    } else if (name == "+" || name == "-" || name == "*" || name == "/" ||
               name == "%" || name == "**" || name == "<<" || name == ">>" ||
               name == "-@" || name == "&" || name == "|" || name == "^" ||
               name == "~" || name == "abs" ||
               (mode == EligibilityMode::CheckedScalar && name == "+@")) {
      // DECISION 0008 TASK 3. Address arithmetic. A buffer is an address the
      // caller owns, and this subset has no pointer arithmetic: an offset
      // buffer would be a second region whose bound nothing declared.
      {
        bool addressOperand = type(receiver) == "buffer";
        for (auto a : args)
          if (type(a) == "buffer") addressOperand = true;
        if (addressOperand) {
          issue(&n, "buffer-arithmetic",
                "`" + name + "` has a buffer operand; a buffer is an address "
                "the caller owns and there is no pointer arithmetic here",
                "REFUSED");
          return;
        }
      }
      // The unchecked slice's side of this is unchanged, down to the wording:
      // it lowers with no overflow policy and no failure channel, so admitting
      // any of these there would define wrapping silently. The names the
      // checked boundary adds are listed inside the mode test rather than
      // outside it, so an unchecked run reaches them exactly as it did before
      // -- for `+@` that is `unresolved-call`, and this must not become a
      // different diagnostic because another mode learned the operator.
      // Decision 0015: the scalar slice admits `+ - * / %` and unary `-`, and
      // lowers them with the abort form's checks.
      //
      // Decision 0042 stage 1 adds `&`, `|`, `^` and `~`: exact at every
      // width, so they need no failure channel and no overflow policy.
      // Stage 2 adds `<<` and `>>` under S1, whose one failure, a left shift
      // that loses bits, goes to the abort hook as `integer overflow in <<`.
      // Stage 3 adds `abs` and `**` to both modes: the exact result, or a
      // failure where it is past the width (`MIN.abs`, a power past the
      // width) or where the exponent of `**` is negative. Every mode has a
      // channel for both, so the Bignum Ruby would give is never needed.
      const bool scalarAdmits = name == "+" || name == "-" || name == "*" ||
                                name == "/" || name == "%" || name == "-@" ||
                                name == "&" || name == "|" || name == "^" ||
                                name == "~" || name == "<<" || name == ">>" ||
                                name == "abs" || name == "**";
      if (mode != EligibilityMode::CheckedScalar && !scalarAdmits) {
        issue(&n, "unproved-arithmetic",
              "overflow, nil and failure effects are not proved for " + name);
      } else {
        // What has to be established here is the TYPE evidence -- proven
        // non-null integer operands and an integer result -- and not the
        // absence of overflow, which the lowering checks at run time. The same
        // rule the comparisons below use, on the same kinds of operand.
        const bool unary = name == "-@" || name == "+@" || name == "~" ||
                           name == "abs";
        const size_t want = unary ? 0 : 1;
        if (args.size() != want)
          issue(&n, "arity-mismatch",
                name + " takes " + std::to_string(want) + " argument(s) here");
        else if (type(receiver) != "int" || type(n.id) != "int" ||
                 (!unary && type(args[0]) != "int"))
          issue(&n, "type-evidence",
                "checked arithmetic requires proven non-null integer operands "
                "and an integer result");
      }
    } else if (name == "<" || name == "<=" || name == ">" || name == ">=" ||
               name == "==" || name == "!=") {
      if (args.size() != 1 || type(receiver) != "int" || type(args[0]) != "int" || type(n.id) != "bool")
        issue(&n, "type-evidence", "comparison requires two proven non-null integer operands");
    } else if (mode == EligibilityMode::CheckedScalar && name == "!") {
      // DECISION 0008 TASK 4. `!` on a BOOLEAN. Ruby's `!` is defined on every
      // object and answers false for everything but nil and false; this
      // subset has neither, and an integer operand would need the truthiness
      // rule that makes 0 true. So the operand is a boolean and nothing else.
      if (!args.empty())
        issue(&n, "arity-mismatch", "`!` takes no arguments");
      else if (type(receiver) != "bool")
        issue(&n, "non-boolean-operand",
              "`!` has a " + type(receiver) +
                  " operand; Ruby's truthiness makes every integer true, 0 "
                  "included, and this subset does not have it", "REFUSED");
    } else {
      issue(&n, "unresolved-call", "no scalar effect contract for " + name);
    }
    if (receiver >= 0) walk(receiver, owner);
    if (argsId >= 0) walk(argsId, owner);
    expressionType(n);
  }

  // A direct call into the checked closure: no receiver, no block, an ordinary
  // `.` call operator, and a name the closure reports. Extracted from the
  // inline test it replaces so the admitted output form below applies exactly
  // the same rule to its operand, rather than a copy that could drift.
  bool isInferenceCall(const Node *n) {
    if (!n || n->kind != "CallNode" || ref(*n, "receiver") != -1 ||
        ref(*n, "block") != -1 || !ordinaryCall(*n))
      return false;
    const auto name = str(*n, "name");
    return std::find(report.methods.begin(), report.methods.end(), name) != report.methods.end();
  }

  // `puts <inference call>` and nothing else. Every clause narrows: the
  // receiverless `.` form, the exact name, exactly one argument, that argument
  // itself an inference call, its result a proven non-null integer, and no
  // top-level `def puts` shadowing the operation. A top-level definition IS
  // admitted by the loop below, so without that last clause a program could
  // define its own `puts` and have this rule admit a call to it.
  //
  // This admits ONE shape by construction. It does not detect rebinding, and
  // does not need to: the blanket refusal it sits in front of is unchanged, so
  // everything else at the top level still fails exactly as it does today.
  // Returns the inner call to check, or nullptr to fall through to that refusal.
  const Node *admittedOutputCall(const Node *n) {
    if (!n || n->kind != "CallNode" || ref(*n, "receiver") != -1 ||
        ref(*n, "block") != -1 || !ordinaryCall(*n) ||
        str(*n, "name") != "puts")
      return nullptr;
    if (definitions.count("puts")) return nullptr;
    const Node *args = node(ref(*n, "arguments"));
    if (!args || args->kind != "ArgumentsNode") return nullptr;
    shape(*args, {"arguments"});
    need(*args, "arguments", AstField::Kind::Array);
    const auto values = array(*args, "arguments");
    if (values.size() != 1) return nullptr;
    const Node *inner = node(values[0]);
    if (!isInferenceCall(inner)) return nullptr;
    // The hosted printer reserves the minimum host integer for nil, so the
    // operand must be a proven non-null integer rather than merely an
    // integer-shaped expression. docs/native-core/task2-binding-report.md.
    if (type(values[0]) != "int") return nullptr;
    callShape(*n);
    return inner;
  }

  // The inference-call checks, moved verbatim out of the loop below.
  void inferenceCall(const Node &n) {
    callShape(n);
    const auto name = str(n, "name");
    const Node *args = node(ref(n, "arguments"));
    std::vector<int64_t> values;
    if (ref(n, "arguments") >= 0) {
      if (!args || args->kind != "ArgumentsNode") {
        issue(&n, "binding-environment", "unsupported inference-call arguments");
        return;
      }
      shape(*args, {"arguments"});
      need(*args, "arguments", AstField::Kind::Array);
      values = array(*args, "arguments");
    }
    const auto &defs = definitions.at(name);
    const Method *m = defs.size() == 1 ? binding(*defs[0]) : nullptr;
    if (!m || values.size() != m->parameters.size())
      issue(&n, "binding-environment", "inference-call arity is not established");
    for (auto value : values) {
      const Node *v = node(value);
      if (!v || v->kind != "IntegerNode" || type(value) != "int") {
        issue(v, "binding-environment", "inference-call arguments must be integer literals");
        continue;
      }
      shape(*v, {"value"});
      need(*v, "value", AstField::Kind::Integer);
      const auto i = number(*v, "value", AstField::Kind::Integer);
      // The whole host range, INTPTR_MIN included (see the IntegerNode rule).
      if (i < std::numeric_limits<intptr_t>::min() || i > std::numeric_limits<intptr_t>::max())
        issue(v, "integer-representation", "inference literal is outside the host integer domain");
    }
  }

  /* Every call to a closure member, from anywhere in the program.
     The closure is computed root-downwards, so it records who the root CALLS
     and says nothing about who calls IT. A method outside the closure that
     calls a member is an ingress the closure's own walk never sees: its
     arguments have no established domain.

     Refusing here is not a claim that such a program is unsafe today -- the top
     level admits no call to a non-member, so one cannot currently be reached.
     It is a refusal to DEPEND on that, because the property holds only because
     the envelope is narrow, not because anything checks it. */
  void enumerateIngress() {
    if (report.methods.empty()) return;
    // DECISION 0014: an application is one file with many entries, and its
    // helpers are shared. Each entry is its own closure, admitted under its
    // own contract with its own derivation of every helper it reaches, and
    // its object holds only that closure. Another entry calling the same
    // helper is not an ingress into THIS closure's object: it is a separate
    // closure, checked by its separate contract, in a separate object.
    if (application()) return;
    const std::set<std::string> closure(report.methods.begin(), report.methods.end());
    for (auto defId : topDefinitions) {
      const Node *def = node(defId);
      if (!def) continue;
      const std::string owner = str(*def, "name");
      if (closure.count(owner)) continue;   // an intra-closure call is not ingress
      std::vector<int64_t> stack{defId};
      std::set<int64_t> seen;
      while (!stack.empty()) {
        const int64_t id = stack.back(); stack.pop_back();
        if (!seen.insert(id).second) continue;
        const Node *n = node(id);
        if (!n) continue;
        if (n->kind == "CallNode" && ref(*n, "receiver") == -1 &&
            closure.count(str(*n, "name")))
          issue(n, "unaccounted-ingress",
                owner + " calls " + str(*n, "name") + ", which is inside the "
                "selected closure, from outside it");
        /* Reference and Integer are BOTH int64_t in the variant, so the kind
           has to be consulted: reading the variant alone turns the literals in
           `[1, 2]` into node ids 1 and 2 and walks into unrelated definitions.
           An existing test caught exactly that. */
        for (const auto &f : n->fields) {
          if (f.kind == AstField::Kind::Reference) {
            if (const auto *r = std::get_if<int64_t>(&f.value))
              if (*r >= 0) stack.push_back(*r);
          } else if (f.kind == AstField::Kind::Array) {
            if (const auto *a = std::get_if<std::vector<int64_t>>(&f.value))
              for (auto e : *a) stack.push_back(e);
          }
        }
      }
    }
  }

  void environment(const Node *program, const Node *statements, StringRef root) {
    path = {root.str()};
    if (!program || program->kind != "ProgramNode" || !statements ||
        statements->kind != "StatementsNode") {
      issue(program, "binding-environment", "missing top-level program structure");
      path.clear();
      return;
    }
    shape(*program, {"statements"});
    shape(*statements, {"body"});
    need(*statements, "body", AstField::Kind::Array);
    for (auto id : array(*statements, "body")) {
      const Node *n = node(id);
      if (n && n->kind == "DefNode" && topDefinitions.count(id)) {
        definitionShape(*n);
        continue;
      }
      // A literal scalar constant. Admitted only here -- the program's own
      // statement list -- and only in the checked mode.
      if (n && n->kind == "ConstantWriteNode" &&
          mode == EligibilityMode::CheckedScalar) {
        shape(*n, {"name", "value"});
        if (!need(*n, "name", AstField::Kind::String) ||
            !need(*n, "value", AstField::Kind::Reference))
          continue;
        const std::string name = str(*n, "name");
        if (constantWrites.count(name) && constantWrites[name] != n) {
          issue(n, "constant-redefinition",
                name + " is assigned more than once; a constant here names one "
                       "value", "REFUSED");
          continue;
        }
        const Node *v = node(ref(*n, "value"));
        if (!v || v->kind != "IntegerNode") {
          issue(n, "dynamic-constant",
                name + " is not an integer literal; this boundary resolves a "
                       "constant at compile time and cannot run its "
                       "initialiser", "REFUSED");
          continue;
        }
        if (!constantValues.count(name))
          issue(n, "integer-representation",
                name + " is outside " + signedBits() + ", or its exact and saturated "
                       "spellings disagree");
        continue;
      }
      // The admitted output form, checked before the blanket refusal and
      // narrower than it: `puts <inference call>`. The refusal itself is
      // unchanged, so reopening, prepend, setup calls, assignments and unknown
      // ingress keep failing for the reason they fail for today.
      if (const Node *inner = admittedOutputCall(n)) {
        inferenceCall(*inner);
        continue;
      }
      // DECISION 0014: an application's declarations. They are read by the
      // application tool, not by this checker, and they bind nothing the
      // closure reads: a `module` naming a declared extern module whose body
      // is empty or holds only `core_extern` calls, and the top-level
      // declaration calls of 0014 §2. Nothing else is added: a module with
      // any other statement, or any other top-level call, stays refused.
      if (application() && n && n->kind == "ModuleNode") {
        const Node *path = node(ref(*n, "constant_path"));
        const Node *body = node(ref(*n, "body"));
        // Any module, not only the ones THIS entry's contract declares: the
        // packaged source holds every module of the application, and an
        // entry's contract lists the externs that entry may call.
        bool clean = path && path->kind == "ConstantReadNode";
        const std::string mod = clean ? str(*path, "name") : std::string();
        if (clean && body) {
          if (body->kind != "StatementsNode") clean = false;
          else
            for (auto sid : array(*body, "body")) {
              const Node *s = node(sid);
              if (s && s->kind == "CallNode" && str(*s, "name") == "core_extern" &&
                  ref(*s, "receiver") == -1)
                continue;
              // DECISION 0014 D5: a constant of the board package, `NAME =
              // <integer literal>`. Each failure is named where it sits, not
              // folded into the module's generic refusal.
              if (s && s->kind == "ConstantWriteNode") {
                shape(*s, {"name", "value"});
                if (!need(*s, "name", AstField::Kind::String) ||
                    !need(*s, "value", AstField::Kind::Reference))
                  continue;
                const std::string key = mod + "::" + str(*s, "name");
                if (constantWrites.count(key) && constantWrites[key] != s) {
                  issue(s, "constant-redefinition",
                        key + " is assigned more than once; a constant here names "
                              "one value", "REFUSED");
                  continue;
                }
                const Node *v = node(ref(*s, "value"));
                if (v && v->kind == "IntegerNode" && !literalValue(*v))
                  // the same refusal a top-level constant of this shape gets:
                  // it IS an integer literal, and it is not representable
                  issue(s, "integer-representation",
                        key + " is outside " + signedBits() + ", or its exact and "
                              "saturated spellings disagree", "REFUSED");
                else if (!v || v->kind != "IntegerNode")
                  issue(s, "unresolved-constant",
                        key + " is not an integer literal; a constant in a module "
                              "body is one integer written there", "REFUSED");
                continue;
              }
              clean = false;
            }
        }
        if (clean) continue;
        issue(n, "binding-environment",
              "a module at top level may hold nothing but core_extern declarations "
              "and integer constants, or be empty; its declarations are read by the "
              "application tool");
        continue;
      }
      if (application() && n && n->kind == "CallNode" && ref(*n, "receiver") == -1 &&
          ref(*n, "block") == -1) {
        const std::string name = str(*n, "name");
        if (name == "require" || name == "require_relative" || name == "state" ||
            name == "every_us" || name == "every_ms" || name == "channel" ||
            name == "scratch")  // decision 0041 stage 2
          continue;
      }
      // Only inference calls into the checked closure are known not to mutate
      // primitive bindings. Arbitrary setup, including indirect metaprogramming,
      // must not disappear merely because it is outside the selected body.
      if (!isInferenceCall(n)) {
        issue(n, "binding-environment", "top level supports only definitions and calls into the selected closure");
        continue;
      }
      inferenceCall(*n);
    }
    path.clear();
  }

public:
  explicit Checker(const ContractModule &m, EligibilityMode mo, unsigned bits = 64)
      : module(m), mode(mo), integerBits(bits) {
    for (const auto &n : m.nodes()) nodes[n.id] = &n;
    for (const auto &t : m.nodeTypes()) types[t.id] = &t;
    for (const auto &method : m.methods()) methods[method.scope] = &method;
    // Peeled parentheses (AnalysisRewrite::ParenPeel): the analysis put the one
    // expression they held in their place, so the ParenthesesNode and its
    // StatementsNode are NilNodes in the nodes face. They read the analysed
    // facts of that expression (through nested peeled pairs), which is what
    // stands in their place.
    std::set<int64_t> peeled;
    for (const auto &rw : m.analysisRewrites())
      if (rw.rewrite == contract::AnalysisRewrite::Kind::ParenPeel) peeled.insert(rw.id);
    for (int64_t p : peeled) {
      int64_t e = p;
      std::vector<int64_t> pair;
      while (peeled.count(e)) {
        const Node *pn = node(e);
        const Node *sn = pn ? node(ref(*pn, "body")) : nullptr;
        if (!sn) break;
        const auto body = array(*sn, "body");
        if (body.size() != 1) break;
        pair.push_back(e);
        pair.push_back(sn->id);
        e = body.front();
      }
      auto it = types.find(e);
      if (e == p || it == types.end()) continue;
      for (int64_t id : pair) types[id] = it->second;
    }
  }
  EligibilityReport run(StringRef root, const EntryFacts *facts) {
    const auto *program = node(module.root());
    const auto *statements = program ? node(ref(*program, "statements")) : nullptr;
    if (statements)
      for (auto id : array(*statements, "body")) {
        const auto *n = node(id);
        if (n && n->kind == "DefNode" && ref(*n, "receiver") == -1) topDefinitions.insert(id);
      }
    for (const auto &n : module.nodes())
      if (n.kind == "DefNode") definitions[str(n, "name")].push_back(&n);
    // Decision 0045: in a source the reader rewrote, Core::Buffer and
    // Core::Table are the buffer spelling, so the source does not define
    // them (a module, a class, a constant or a method), whether or not the
    // definition is reached.
    {
      bool rewrote = false;
      for (const auto &sp : module.bufferSpellings())
        if (sp.kind == contract::BufferSpelling::Kind::Buffer ||
            sp.kind == contract::BufferSpelling::Kind::Table)
          rewrote = true;
      if (rewrote)
        for (const auto &sp : module.bufferSpellings())
          if (sp.kind == contract::BufferSpelling::Kind::Reserved)
            report.diagnostics.push_back(
                {"REFUSED", "-",
                 module.sourceFile().str() + ":" + std::to_string(sp.line) + ":" +
                     std::to_string(sp.column),
                 "array-reserved", "",
                 "this defines " + sp.element + " (" + sp.arguments + "); Core::Buffer "
                 "and Core::Table are reserved for the buffer spelling, and so is Core "
                 "as their module (decision 0045)"});
    }
    // Decision 0042 stage 4, a change to 0022's rule on --core: a top-level
    // definition of an intrinsic's name is refused wherever it is, called or
    // not. The prelude the hosted copy and the reader's copy get defines the
    // name too, and would replace it. The status lane refuses one only where
    // the closure calls it (below), as 0022 decided.
    if (mode != EligibilityMode::CheckedScalar)
      for (int64_t id : topDefinitions)
        if (const Node *d = node(id); d && coreIntrinsic(str(*d, "name")))
          issue(d, "conflicting-intrinsic",
                "`" + str(*d, "name") + "` is defined in this source and is also "
                "the CORE intrinsic; on this route the intrinsics' prelude defines "
                "it for the hosted half and the analysis, so the two cannot both "
                "be meant", "REFUSED");
    // The constants, collected before anything reads one. Only the program's
    // OWN statement list: a write inside an `if` or a method is not a
    // definition this boundary can resolve, and it is refused where it sits.
    if (mode == EligibilityMode::CheckedScalar && statements)
      for (auto id : array(*statements, "body")) {
        const Node *n = node(id);
        if (!n || n->kind != "ConstantWriteNode") continue;
        const std::string name = str(*n, "name");
        if (constantWrites.count(name)) continue;  // reported in environment()
        constantWrites[name] = n;
        const Node *v = node(ref(*n, "value"));
        if (v && v->kind == "IntegerNode")
          if (const std::optional<int64_t> value = literalValue(*v))
            constantValues[name] = *value;
      }
    // DECISION 0014 D5: the modules of this source, and the constants they
    // carry, keyed `Mod::NAME`. Only a top-level module's own statement list,
    // and only an integer literal -- the same rule as a top-level constant,
    // one level down. A module that repeats a name is refused in
    // environment(), where the statement sits.
    // (`application()` reads facts that `deriveFacts` sets below, so this asks
    // the contract directly. A `Mod::NAME` read is refused outside an
    // application in any case, by the admission gate.)
    if (mode == EligibilityMode::CheckedScalar && facts && facts->isApplication() && statements)
      for (auto id : array(*statements, "body")) {
        const Node *m = node(id);
        if (!m || m->kind != "ModuleNode") continue;
        const Node *path = node(ref(*m, "constant_path"));
        if (!path || path->kind != "ConstantReadNode") continue;
        const std::string mod = str(*path, "name");
        moduleNames.insert(mod);
        const Node *body = node(ref(*m, "body"));
        if (!body || body->kind != "StatementsNode") continue;
        for (auto sid : array(*body, "body")) {
          const Node *s = node(sid);
          if (!s || s->kind != "ConstantWriteNode") continue;
          const std::string key = mod + "::" + str(*s, "name");
          if (constantWrites.count(key)) continue;  // reported in environment()
          constantWrites[key] = s;
          const Node *v = node(ref(*s, "value"));
          if (v && v->kind == "IntegerNode")
            if (const std::optional<int64_t> value = literalValue(*v))
              constantValues[key] = *value;
        }
      }
    // Positions first: the derivation and every check below ask whether a node
    // is in statement position, and the answer is a property of the tree that
    // does not depend on either. Marked once per definition, from its body,
    // whose last statement is the method's value.
    for (const auto &kv : definitions)
      if (kv.second.size() == 1)
        markPositions(ref(*kv.second[0], "body"), true);
    prescanArrays(facts);
    // The facts next: every check below reads the types, so the derivation
    // has to have happened before any of them looks.
    if (facts && mode == EligibilityMode::CheckedScalar && !facts->entry.empty())
      deriveFacts(*facts);
    report.constants = constantValues;
    // DECISION 0014: `guards:` and `statics:` are keywords of the GENERATED
    // packages' declarations only. In application source they would be a
    // precondition surface the owner has not opened, so a `core_extern` in a
    // top-level module body carrying either is refused by name. Read from the
    // tree, not the closure: the declaration is not reachable from any entry.
    if (application() && statements)
      for (auto id : array(*statements, "body")) {
        const Node *mod = node(id);
        if (!mod || mod->kind != "ModuleNode") continue;
        const Node *body = node(ref(*mod, "body"));
        if (!body || body->kind != "StatementsNode") continue;
        for (auto sid : array(*body, "body")) {
          const Node *call = node(sid);
          if (!call || call->kind != "CallNode" || str(*call, "name") != "core_extern") continue;
          const Node *args = node(ref(*call, "arguments"));
          if (!args) continue;
          for (auto aid : array(*args, "arguments")) {
            const Node *kw = node(aid);
            if (!kw || kw->kind != "KeywordHashNode") continue;
            for (auto eid : array(*kw, "elements")) {
              const Node *assoc = node(eid);
              if (!assoc || assoc->kind != "AssocNode") continue;
              const Node *key = node(ref(*assoc, "key"));
              if (!key || key->kind != "SymbolNode") continue;
              const std::string k = str(*key, "value");
              if (k == "guards" || k == "statics")
                issue(call, "guards-in-source",
                      "`" + k + ":` is a keyword of generated declarations only; an "
                      "application's core_extern has no precondition surface", "REFUSED");
            }
          }
        }
      }
    // An in-place rewrite by the analysis (contract::AnalysisRewrite): the
    // analysed program differs from the parsed one at that node, so nothing
    // here can be checked against the source there. Refused at the node.
    for (const auto &rw : module.analysisRewrites()) {
      if (rw.rewrite == contract::AnalysisRewrite::Kind::AnonymousModule)
        issue(node(rw.id), "binding-environment",
              "the analysis rewrote this " + rw.astKind + " (`Module.new { ... }`) "
              "into the " + rw.nodesKind + " " + rw.detail +
              ", an anonymous module it defined; the analysed program is not the "
              "parsed one here");
      else if (rw.rewrite == contract::AnalysisRewrite::Kind::DynamicSend)
        issue(node(rw.id), "binding-environment",
              "the analysis lowered this `" + rw.detail + "`, whose name is not a "
              "literal, into a dispatch over the program's symbol literals, "
              "adding " + std::to_string(rw.synthesized.size()) +
              " node(s); the analysed program is not the parsed one here");
      else if (rw.rewrite == contract::AnalysisRewrite::Kind::PrunedMethod) {
        // A method nothing names is outside every closure, so leaving it out
        // of the analysis changes nothing checked here. The root is named
        // from outside the program; if it was blanked, there is no analysis
        // of it to check.
        if (rw.detail == root.str())
          issue(node(rw.id), "binding-environment",
                "the analysis left this method out as one nothing in the program "
                "names, so it has no analysed body to check; the compiler must "
                "keep a root named from outside the program");
      } else if (rw.rewrite == contract::AnalysisRewrite::Kind::ParenPeel) {
        // The parentheses are gone and the one expression they held stands in
        // their place, with its own kind and type: nothing checked changes.
      } else
        issue(node(rw.id), "binding-environment",
              "the analysis removed the branch of this " + rw.astKind +
              " that cannot run (its predicate is a " + rw.detail +
              ") together with the definition in it, replacing " +
              std::to_string(rw.replaced.size()) +
              " node(s) with nil; the analysed program is not the parsed one here");
    }
    visitMethod(root.str());
    environment(program, statements, root);
    // DECISION 0041 STAGE 2: the makers, and every caller of one up to the
    // entry, take the data stack's address.
    for (const auto &a : report.arrayMakes) report.scratchMethods.insert(a.method);
    for (bool grew = true; grew;) {
      grew = false;
      for (const CallEdge &e : report.callEdges)
        if (report.scratchMethods.count(e.callee) && report.scratchMethods.insert(e.caller).second)
          grew = true;
    }
    if (entryBuffers && entryBuffers->scratchBytes && !report.arrayMakes.empty()) {
      // The worst path's bytes, composed over the call edges as frames
      // are: a method's own arrays all live together, and its callees run
      // one at a time beneath them. Recursion is refused, so this ends.
      const int64_t elementBytes = integerBits / 8;
      // Saturating at the int64 maximum: a total past it is past every
      // region, and is refused as one (the review: a size of 2^60
      // wrapped the product to a negative total that passed).
      const int64_t kMax = std::numeric_limits<int64_t>::max();
      auto satAdd = [&](int64_t x, int64_t y) { int64_t r; return __builtin_add_overflow(x, y, &r) ? kMax : r; };
      auto satMul = [&](int64_t x, int64_t y) { int64_t r; return __builtin_mul_overflow(x, y, &r) ? kMax : r; };
      std::map<std::string, std::optional<int64_t>> worst;
      std::function<std::optional<int64_t>(const std::string &)> of =
          [&](const std::string &m) -> std::optional<int64_t> {
        if (auto w = worst.find(m); w != worst.end()) return w->second;
        worst[m] = std::nullopt;
        std::optional<int64_t> own = 0;
        for (const auto &a : report.arrayMakes)
          if (a.method == m) {
            if (!a.count || *a.count < 0) own = std::nullopt;
            else if (own) own = satAdd(*own, satMul(*a.count, elementBytes));
          }
        std::optional<int64_t> deepest = 0;
        for (const CallEdge &e : report.callEdges)
          if (e.caller == m && report.scratchMethods.count(e.callee)) {
            const std::optional<int64_t> c = of(e.callee);
            if (!c) deepest = std::nullopt;
            else if (deepest) deepest = std::max(*deepest, *c);
          }
        return worst[m] = own && deepest ? std::optional<int64_t>(satAdd(*own, *deepest)) : std::nullopt;
      };
      report.scratchWorstBytes = of(root.str());
      const int64_t room = static_cast<int64_t>(*entryBuffers->scratchBytes) - elementBytes;
      if (report.scratchWorstBytes && *report.scratchWorstBytes > room)
        issue(definitionNamed(root.str()), "scratch-capacity",
              "its worst call path holds " +
                  (*report.scratchWorstBytes == kMax ? std::string("more than 2^63 - 1")
                                                     : "up to " + std::to_string(*report.scratchWorstBytes)) +
                  " bytes of buffers at once, and its context's scratch region has " +
                  std::to_string(room) + " (" + std::to_string(*entryBuffers->scratchBytes) +
                  " declared, less the " + std::to_string(elementBytes) + "-byte offset word)",
              "REFUSED");
    }
    if (entryBuffers && entryBuffers->scratchBytes) {
      const uint64_t word = integerBits / 8;
      report.scratchElements = static_cast<int64_t>((*entryBuffers->scratchBytes - word) / word);
    }
    enumerateIngress();
    if (derivationUnsettled) {
      // Not a warning and not a best effort: an iteration that did not settle
      // has no answer, and publishing the last one it happened to hold would
      // be exactly the thing the bounds exist to prevent.
      issue(definitionNamed(root.str()), "type-derivation-unsettled",
            "the types of this closure did not settle within the iteration "
            "bound, so there is no derivation to check against", "REFUSED");
    }
    if (factsSupplied && !derivationUnsettled) {
      for (const auto &kv : derivedNode)
        report.derivedTypes[kv.first] = tyName(kv.second);
      report.readParameters.assign(readParameters.begin(), readParameters.end());
      for (const auto &kv : derivedResult) {
        auto params = derivedParams.find(kv.first);
        std::vector<std::string> ps;
        if (params != derivedParams.end())
          for (const Ty t : params->second) ps.push_back(tyName(t));
        report.derivedSignatures[kv.first] = {std::move(ps), tyName(kv.second)};
      }
      // The entry's own borrows come from the contract and are put here too,
      // so one table answers the question for every method in the closure and
      // the generator has no second place to look.
      if (entryBuffers) {
        const Method *e = methodNamed(entryBuffers->entry);
        if (e)
          for (size_t i = 0; i < e->parameters.size(); ++i)
            if (const EntryBufferFact *b = entryBuffers->buffer(e->parameters[i].name)) {
              Borrow r;
              r.kind = Borrow::Kind::Buffer;
              r.element = b->element;
              r.readOnly = b->readOnly;
              r.cross = b->cross;
              r.origin = b->name;
              borrowFacts.parameters[entryBuffers->entry][i] = r;
            }
      }
      borrowFacts.settled = true;
      report.borrows = borrowFacts;
    }
    return std::move(report);
  }
};
} // namespace
EligibilityReport checkEligibility(const ContractModule &module, StringRef method,
                                   EligibilityMode mode, const EntryFacts *facts,
                                   unsigned integerBits) {
  return Checker(module, mode, integerBits).run(method, facts);
}
} // namespace spinel_mlir::core
