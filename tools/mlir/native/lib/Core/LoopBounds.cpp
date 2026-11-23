//===- LoopBounds.cpp - loop and work bounds of an admitted CORE entry ----===//
//
// Decision 0010, step 1. See LoopBounds.h for what this is, and
// docs/core/core-report.md for the rules, the reason codes and the grammar of
// the expressions it writes.
//
// The shape of the analysis:
//
//   1. Each closure method is walked ONCE, in source order, with an
//      environment from local names to symbolic values. A value is an
//      expression over the method's parameters and constants, or opaque with a
//      reason (a buffer element, a call result, two definitions that met).
//      Inside a loop, every local the loop assigns is a VARYING atom tied to
//      that loop, so a value computed from it is never mistaken for one fixed
//      at the loop's entry.
//   2. Each `while` is classified when the walk reaches it, against the
//      environment before it (for the induction variable's start) and at its
//      head (for the bound). The result is in the method's own terms.
//   3. The work bound expands the acyclic call graph from the entry,
//      substituting arguments into callee bounds and multiplying by the loops
//      around each loop and each call.
//
// It refuses nothing. A loop the rules cannot bound is `unknown` with the
// FIRST rule it fails, in the order the rules are listed in the document.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/LoopBounds.h"
#include "spinel-mlir/Core/BlockLoops.h"

#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/SHA256.h"

#include <algorithm>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <tuple>

using namespace spinel_mlir::contract;
using llvm::StringRef;

namespace spinel_mlir::core {
namespace {

// ---- AST access ---------------------------------------------------------

const AstField *field(const Node &n, StringRef key) {
  for (const auto &f : n.fields)
    if (f.key == key) return &f;
  return nullptr;
}
int64_t integer(const Node &n, StringRef key, int64_t fallback = 0) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Integer ? std::get<int64_t>(f->value)
                                                 : fallback;
}
int64_t ref(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Reference ? std::get<int64_t>(f->value)
                                                   : -1;
}
std::string str(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::String ? std::get<std::string>(f->value)
                                                : "";
}
std::vector<int64_t> array(const Node &n, StringRef key) {
  const auto *f = field(n, key);
  return f && f->kind == AstField::Kind::Array
             ? std::get<std::vector<int64_t>>(f->value)
             : std::vector<int64_t>{};
}
bool isPosition(StringRef key) {
  return key == "node_line" || key == "node_col" || key == "node_file";
}

// ---- expressions --------------------------------------------------------
//
// Immutable and shared. The constructors simplify only by rules that hold
// over the integers -- folding, identities, and collecting a constant offset
// -- so a rendering is canonical for the shapes this analysis builds and never
// changes what an expression means.

struct Expr;
using ExprRef = std::shared_ptr<const Expr>;

struct Expr {
  enum class Op { Const, Param, Var, Add, Sub, Mul, Neg, Max, CeilDiv, FloorDiv, FloorMod };
  Op op = Op::Const;
  int64_t value = 0;   ///< Const
  std::string name;    ///< Param, Var
  int64_t loop = -1;   ///< Var: the loop whose body assigns it
  ExprRef a, b;
  /// Nodes this expression has WHEN WRITTEN OUT, saturating at the limit
  /// below. Subexpressions are shared, so the graph can be far smaller than
  /// its text: `m = m + m` repeated k times is 2k nodes and 2^k terms. This
  /// counts the text, because that is what is rendered, compared and stored.
  uint64_t size = 1;
};

/// An expression larger than this is not reported. Measured: without a limit,
/// a doubling chain rendered gigabytes and a fan-out of calls recursed until
/// the stack ran out, both AFTER the object had been written. A bound nobody
/// can read is not worth a build failure, so the property says `unknown` and
/// names the limit instead.
constexpr uint64_t kMaxExprSize = 4096;
/// The same for the number of loop occurrences the work bound expands to.
constexpr size_t kMaxTerms = 4096;

ExprRef make(Expr e) {
  const uint64_t size = 1 + (e.a ? e.a->size : 0) + (e.b ? e.b->size : 0);
  // Saturated: every producer of a value checks the limit, so a size only
  // ever grows a bounded amount past it before it is refused, and this keeps
  // the count itself from wrapping.
  e.size = std::min<uint64_t>(size, 4 * kMaxExprSize);
  return std::make_shared<const Expr>(std::move(e));
}

/// Whether `e` is missing or too large to report.
bool oversize(const ExprRef &e) { return !e || e->size > kMaxExprSize; }
ExprRef mkConst(int64_t v) {
  Expr e;
  e.op = Expr::Op::Const;
  e.value = v;
  return make(std::move(e));
}
ExprRef mkParam(const std::string &n) {
  Expr e;
  e.op = Expr::Op::Param;
  e.name = n;
  return make(std::move(e));
}
ExprRef mkVar(const std::string &n, int64_t loop) {
  Expr e;
  e.op = Expr::Op::Var;
  e.name = n;
  e.loop = loop;
  return make(std::move(e));
}
ExprRef mkBinary(Expr::Op op, ExprRef a, ExprRef b) {
  Expr e;
  e.op = op;
  e.a = std::move(a);
  e.b = std::move(b);
  return make(std::move(e));
}

std::optional<int64_t> constOf(const ExprRef &e) {
  if (e && e->op == Expr::Op::Const) return e->value;
  return std::nullopt;
}

bool same(const ExprRef &x, const ExprRef &y) {
  if (x == y) return true;
  if (!x || !y || x->op != y->op) return false;
  switch (x->op) {
  case Expr::Op::Const: return x->value == y->value;
  case Expr::Op::Param: return x->name == y->name;
  case Expr::Op::Var: return x->name == y->name && x->loop == y->loop;
  case Expr::Op::Neg: return same(x->a, y->a);
  default: return same(x->a, y->a) && same(x->b, y->b);
  }
}

/// `e` as base + offset, where base is null for a constant.
std::pair<ExprRef, int64_t> splitOffset(const ExprRef &e) {
  if (auto c = constOf(e)) return {nullptr, *c};
  if (e->op == Expr::Op::Add)
    if (auto c = constOf(e->b)) return {e->a, *c};
  if (e->op == Expr::Op::Sub)
    if (auto c = constOf(e->b))
      if (*c != std::numeric_limits<int64_t>::min()) return {e->a, -*c};
  return {e, 0};
}

ExprRef withOffset(const ExprRef &base, int64_t off) {
  if (!base) return mkConst(off);
  if (off == 0) return base;
  if (off > 0) return mkBinary(Expr::Op::Add, base, mkConst(off));
  if (off == std::numeric_limits<int64_t>::min())
    return mkBinary(Expr::Op::Add, base, mkConst(off));
  return mkBinary(Expr::Op::Sub, base, mkConst(-off));
}

ExprRef mkAdd(const ExprRef &a, const ExprRef &b) {
  if (auto cb = constOf(b)) {
    auto [base, off] = splitOffset(a);
    int64_t sum;
    if (!__builtin_add_overflow(off, *cb, &sum)) return withOffset(base, sum);
    return mkBinary(Expr::Op::Add, a, b);
  }
  if (auto ca = constOf(a)) return mkAdd(b, a);
  return mkBinary(Expr::Op::Add, a, b);
}

ExprRef mkSub(const ExprRef &a, const ExprRef &b) {
  if (auto cb = constOf(b))
    if (*cb != std::numeric_limits<int64_t>::min()) return mkAdd(a, mkConst(-*cb));
  if (same(a, b)) return mkConst(0);
  return mkBinary(Expr::Op::Sub, a, b);
}

ExprRef mkMul(const ExprRef &a, const ExprRef &b) {
  auto ca = constOf(a), cb = constOf(b);
  if (ca && cb) {
    int64_t p;
    if (!__builtin_mul_overflow(*ca, *cb, &p)) return mkConst(p);
  }
  if (ca && *ca == 1) return b;
  if (cb && *cb == 1) return a;
  if ((ca && *ca == 0) || (cb && *cb == 0)) return mkConst(0);
  return mkBinary(Expr::Op::Mul, a, b);
}

ExprRef mkNeg(const ExprRef &a) {
  if (auto c = constOf(a))
    if (*c != std::numeric_limits<int64_t>::min()) return mkConst(-*c);
  if (a->op == Expr::Op::Neg) return a->a;
  Expr e;
  e.op = Expr::Op::Neg;
  e.a = a;
  return make(std::move(e));
}

ExprRef mkMax(const ExprRef &a, const ExprRef &b) {
  auto ca = constOf(a), cb = constOf(b);
  if (ca && cb) return mkConst(std::max(*ca, *cb));
  if (same(a, b)) return a;
  return mkBinary(Expr::Op::Max, a, b);
}

/// ceil(a / c) for a >= 0 and a constant c > 0.
ExprRef mkCeilDiv(const ExprRef &a, int64_t c) {
  if (c == 1) return a;
  if (auto ca = constOf(a))
    if (*ca >= 0) return mkConst(*ca / c + (*ca % c != 0));
  return mkBinary(Expr::Op::CeilDiv, a, mkConst(c));
}

/// Ruby's Integer `/` and `%`: the quotient rounds toward negative infinity
/// and the remainder takes the divisor's sign.
ExprRef mkFloorDiv(const ExprRef &a, const ExprRef &b) {
  auto ca = constOf(a), cb = constOf(b);
  if (ca && cb && *cb != 0 &&
      !(*ca == std::numeric_limits<int64_t>::min() && *cb == -1)) {
    int64_t q = *ca / *cb;
    if ((*ca % *cb != 0) && ((*ca < 0) != (*cb < 0))) --q;
    return mkConst(q);
  }
  if (cb && *cb == 1) return a;
  return mkBinary(Expr::Op::FloorDiv, a, b);
}

ExprRef mkFloorMod(const ExprRef &a, const ExprRef &b) {
  auto ca = constOf(a), cb = constOf(b);
  if (ca && cb && *cb != 0 &&
      !(*ca == std::numeric_limits<int64_t>::min() && *cb == -1)) {
    int64_t r = *ca % *cb;
    if (r != 0 && ((r < 0) != (*cb < 0))) r += *cb;
    return mkConst(r);
  }
  return mkBinary(Expr::Op::FloorMod, a, b);
}

int precedence(const Expr &e) {
  switch (e.op) {
  case Expr::Op::Add:
  case Expr::Op::Sub: return 1;
  case Expr::Op::Mul: return 2;
  case Expr::Op::Const: return e.value < 0 ? 2 : 3;
  default: return 3;
  }
}

std::string render(const ExprRef &e);
std::string renderChild(const ExprRef &e, int minimum) {
  std::string s = render(e);
  return precedence(*e) < minimum ? "(" + s + ")" : s;
}
std::string render(const ExprRef &e) {
  switch (e->op) {
  case Expr::Op::Const: return std::to_string(e->value);
  case Expr::Op::Param: return e->name;
  case Expr::Op::Var: return e->name + "@" + std::to_string(e->loop);
  case Expr::Op::Add: return renderChild(e->a, 1) + " + " + renderChild(e->b, 2);
  case Expr::Op::Sub: return renderChild(e->a, 1) + " - " + renderChild(e->b, 2);
  case Expr::Op::Mul: return renderChild(e->a, 2) + " * " + renderChild(e->b, 3);
  case Expr::Op::Neg: return "-" + renderChild(e->a, 3);
  case Expr::Op::Max: return "max(" + render(e->a) + ", " + render(e->b) + ")";
  case Expr::Op::CeilDiv: return "ceil_div(" + render(e->a) + ", " + render(e->b) + ")";
  case Expr::Op::FloorDiv: return "floor_div(" + render(e->a) + ", " + render(e->b) + ")";
  case Expr::Op::FloorMod: return "floor_mod(" + render(e->a) + ", " + render(e->b) + ")";
  }
  return "";
}

void collectVars(const ExprRef &e, std::vector<std::pair<std::string, int64_t>> &out) {
  if (!e) return;
  if (e->op == Expr::Op::Var) {
    auto key = std::make_pair(e->name, e->loop);
    if (std::find(out.begin(), out.end(), key) == out.end()) out.push_back(key);
    return;
  }
  collectVars(e->a, out);
  collectVars(e->b, out);
}

// ---- symbolic values ------------------------------------------------------

/// What a local holds: an expression, or opaque with the reason it is not
/// one. The reason tokens are the `detail` prefixes the document lists.
/// DECISION 0041 STAGE 2. The size of an array whose size is not a constant:
/// `size(@<method>:<local>)`, a value in [0, the region's elements].
const std::string kArraySizePrefix = "size(@";
bool isArraySize(const ExprRef &e) {
  return e && e->op == Expr::Op::Param && e->name.rfind(kArraySizePrefix, 0) == 0;
}

/// How an expression moves as one array-size symbol grows: not at all, never
/// down, never up, or either way (or unknown).
enum class Trend { None, Up, Down, Any };
Trend flip(Trend t) { return t == Trend::Up ? Trend::Down : t == Trend::Down ? Trend::Up : t; }
Trend join(Trend x, Trend y) {
  if (x == Trend::None) return y;
  if (y == Trend::None || x == y) return x;
  return Trend::Any;
}
/// Never negative, whatever the symbols: what the bounds are built of.
bool nonNegative(const ExprRef &e) {
  switch (e->op) {
  case Expr::Op::Const: return e->value >= 0;
  case Expr::Op::Param: return isArraySize(e);
  case Expr::Op::Max: return nonNegative(e->a) || nonNegative(e->b);
  case Expr::Op::Add:
  case Expr::Op::Mul: return nonNegative(e->a) && nonNegative(e->b);
  case Expr::Op::CeilDiv:
  case Expr::Op::FloorDiv:
    return nonNegative(e->a) && e->b->op == Expr::Op::Const && e->b->value > 0;
  default: return false;
  }
}
Trend trend(const ExprRef &e, const std::string &sym) {
  switch (e->op) {
  case Expr::Op::Const:
  case Expr::Op::Var: return Trend::None;
  case Expr::Op::Param: return e->name == sym ? Trend::Up : Trend::None;
  case Expr::Op::Neg: return flip(trend(e->a, sym));
  case Expr::Op::Add:
  case Expr::Op::Max: return join(trend(e->a, sym), trend(e->b, sym));
  case Expr::Op::Sub: return join(trend(e->a, sym), flip(trend(e->b, sym)));
  case Expr::Op::Mul: {
    const Trend ta = trend(e->a, sym), tb = trend(e->b, sym);
    if (ta == Trend::None && tb == Trend::None) return Trend::None;
    if (e->a->op == Expr::Op::Const) return e->a->value >= 0 ? tb : flip(tb);
    if (e->b->op == Expr::Op::Const) return e->b->value >= 0 ? ta : flip(ta);
    // a product of two never-negative factors moves with each of them
    if (!nonNegative(e->a) || !nonNegative(e->b)) return Trend::Any;
    return join(ta, tb);
  }
  case Expr::Op::CeilDiv:
  case Expr::Op::FloorDiv:
    if (e->b->op == Expr::Op::Const && e->b->value > 0) return trend(e->a, sym);
    return join(trend(e->a, sym), trend(e->b, sym)) == Trend::None ? Trend::None : Trend::Any;
  case Expr::Op::FloorMod:
    return join(trend(e->a, sym), trend(e->b, sym)) == Trend::None ? Trend::None : Trend::Any;
  }
  return Trend::Any;
}
void collectArraySizes(const ExprRef &e, std::set<std::string> &out) {
  if (!e) return;
  if (isArraySize(e)) out.insert(e->name);
  collectArraySizes(e->a, out);
  collectArraySizes(e->b, out);
}
ExprRef replaceParam(const ExprRef &e, const std::string &sym, const ExprRef &with);

struct Val {
  ExprRef e;
  std::string why;
  std::string detail;
  static Val of(ExprRef e) { Val v; v.e = std::move(e); return v; }
  static Val opaque(std::string why, std::string detail = "") {
    Val v;
    v.why = std::move(why);
    v.detail = std::move(detail);
    return v;
  }
};
bool sameVal(const Val &x, const Val &y) {
  if (x.e && y.e) return same(x.e, y.e);
  return !x.e && !y.e && x.why == y.why;
}
std::string describe(const Val &v) {
  return v.detail.empty() ? v.why : v.why + " (" + v.detail + ")";
}

/// A value that has grown past what a report can hold. It is opaque like any
/// other value the analysis cannot use, so a loop bounded by it is `unknown`
/// with the detail saying which limit it met.
Val tooLarge() {
  return Val::opaque("expression-too-large",
                     "over " + std::to_string(kMaxExprSize) + " terms written out");
}

Val checked(ExprRef e) { return oversize(e) ? tooLarge() : Val::of(std::move(e)); }

Val arith(const std::string &op, const Val &l, const Val &r) {
  if (!l.e) return l;
  if (!r.e) return r;
  if (op == "+") return checked(mkAdd(l.e, r.e));
  if (op == "-") return checked(mkSub(l.e, r.e));
  if (op == "*") return checked(mkMul(l.e, r.e));
  if (op == "/") return checked(mkFloorDiv(l.e, r.e));
  if (op == "%") return checked(mkFloorMod(l.e, r.e));
  return Val::opaque("unsupported-operator", "`" + op + "`");
}

using Env = std::map<std::string, Val>;
using Subst = std::map<std::string, Val>;

Env joinEnv(const Env &a, const Env &b) {
  Env out;
  for (const auto &kv : a) {
    auto it = b.find(kv.first);
    if (it != b.end() && sameVal(kv.second, it->second)) out[kv.first] = kv.second;
    else out[kv.first] = Val::opaque("multiple-definitions", kv.first);
  }
  for (const auto &kv : b)
    if (!a.count(kv.first))
      out[kv.first] = Val::opaque("multiple-definitions", kv.first);
  return out;
}

std::string hexDigest(StringRef text) {
  llvm::SHA256 h;
  h.update(text);
  return llvm::toHex(h.final(), /*LowerCase=*/true);
}

// ---- the analysis ---------------------------------------------------------

class Analysis {
public:
  Analysis(const ContractModule &m, const EligibilityReport &r, const EntryFacts &f)
      : module(m), admitted(r), facts(f) {
    for (const auto &a : r.arrayMakes) arrayNews.insert(a.nodeId);
    for (const auto &n : m.nodes()) nodes[n.id] = &n;
    for (const auto &e : r.callEdges) callees[e.nodeId] = e.callee;
  }

  LoopBoundResult run();
  ExprRef resolveArraySizes(ExprRef e, std::string &why) const;

private:
  const ContractModule &module;
  const EligibilityReport &admitted;
  const EntryFacts &facts;
  std::map<int64_t, const Node *> nodes;
  std::set<std::string> closure;
  std::map<std::string, const Node *> definitions;
  /// Decision 0026 step 4: each call node eligibility resolved into the
  /// closure, to the method it calls.
  std::map<int64_t, std::string> callees;

  /// DECISION 0041 STAGE 2. The admitted Array.new calls, each a loop of its
  /// own (the fill), and per method the bound of each array local's size.
  /// `walking` is the method whose walk is running, for the pure walks that
  /// read a loop head.
  std::set<int64_t> arrayNews;
  std::set<int64_t> arrayConstSize;  ///< those whose size is an exact constant
  std::map<std::string, std::map<std::string, ExprRef>> arraySizes;
  std::string walking;
  struct LoopRec {
    int64_t node = -1;
    std::vector<int64_t> enclosing;  ///< outermost first, same method
    LoopFinding finding;
    ExprRef bound;
    std::string iv;  ///< the induction variable, when one was identified
  };
  struct CallRec {
    std::string callee;
    std::vector<Val> args;
    std::vector<int64_t> enclosing;
    bool inPredicate = false;
    int64_t line = 0, column = 0;
    /// DECISION 0041: per argument, the element count of the buffer it
    /// names in the caller (`size(buf)`), or an opaque value.
    std::vector<Val> sizes;
    /// Decision 0014: an extern call site, indexed into the entry facts'
    /// externs; -1 for a call into the closure.
    int64_t externIndex = -1;
  };
  struct MethodRec {
    std::vector<std::string> params;
    /// Loops and calls in source order: a loop node id, or `-1 - call index`.
    std::vector<int64_t> events;
    std::vector<int64_t> loops;
    std::vector<CallRec> calls;
  };
  std::map<int64_t, LoopRec> loops;
  std::map<std::string, MethodRec> methods;

  LoopBoundResult result;
  std::vector<ExprRef> termExprs;
  std::vector<ExprRef> externTermExprs;  ///< parallel to result.externTerms
  /// Set when the expansion stopped at `kMaxTerms`, so it unwinds instead of
  /// continuing in the callers it has already entered.
  bool truncated = false;

  const Node *node(int64_t id) const {
    auto it = nodes.find(id);
    return id < 0 || it == nodes.end() ? nullptr : it->second;
  }
  /// The node inside any parentheses that hold exactly one expression.
  const Node *unwrap(int64_t id) const {
    const Node *n = node(id);
    while (n && n->kind == "ParenthesesNode") {
      const Node *body = node(ref(*n, "body"));
      if (body && body->kind == "StatementsNode") {
        const auto items = array(*body, "body");
        if (items.size() != 1) return n;
        body = node(items[0]);
      }
      n = body;
    }
    return n;
  }
  std::string lvarName(int64_t id) const {
    const Node *n = unwrap(id);
    return n && n->kind == "LocalVariableReadNode" ? str(*n, "name") : "";
  }
  std::string position(const Node &n) const {
    return std::to_string(integer(n, "node_line")) + ":" +
           std::to_string(integer(n, "node_col"));
  }

  /// Every node below `id`, `id` included, in field order.
  template <typename Fn> void forEach(int64_t id, Fn &&fn) const {
    std::vector<int64_t> stack{id};
    std::set<int64_t> seen;
    while (!stack.empty()) {
      const int64_t cur = stack.back();
      stack.pop_back();
      const Node *n = node(cur);
      if (!n || !seen.insert(cur).second) continue;
      fn(*n);
      std::vector<int64_t> children;
      for (const auto &f : n->fields) {
        if (f.kind == AstField::Kind::Reference) {
          if (std::get<int64_t>(f.value) >= 0) children.push_back(std::get<int64_t>(f.value));
        } else if (f.kind == AstField::Kind::Array) {
          for (auto c : std::get<std::vector<int64_t>>(f.value))
            if (c >= 0) children.push_back(c);
        }
      }
      for (auto it = children.rbegin(); it != children.rend(); ++it) stack.push_back(*it);
    }
  }
  std::set<std::string> assignedIn(int64_t id) const {
    std::set<std::string> out;
    forEach(id, [&](const Node &n) {
      if (n.kind == "LocalVariableWriteNode" || n.kind == "LocalVariableOperatorWriteNode")
        out.insert(str(n, "name"));
    });
    return out;
  }
  bool assigns(int64_t id, const std::string &name) const {
    bool hit = false;
    forEach(id, [&](const Node &n) {
      if ((n.kind == "LocalVariableWriteNode" || n.kind == "LocalVariableOperatorWriteNode") &&
          str(n, "name") == name)
        hit = true;
    });
    return hit;
  }
  std::string readsAny(int64_t id, const std::set<std::string> &names) const {
    std::string hit;
    forEach(id, [&](const Node &n) {
      if (hit.empty() && (n.kind == "LocalVariableReadNode" ||
                          n.kind == "LocalVariableOperatorWriteNode") &&
          names.count(str(n, "name")))
        hit = str(n, "name");
    });
    return hit;
  }
  bool readsIndex(int64_t id) const {
    bool hit = false;
    forEach(id, [&](const Node &n) {
      if (n.kind == "CallNode" && ref(n, "receiver") >= 0 && str(n, "name") == "[]") hit = true;
    });
    return hit;
  }
  /// The method the first call into the closure under `id` calls, or empty.
  std::string closureCallee(int64_t id) const {
    std::string hit;
    forEach(id, [&](const Node &n) {
      if (auto e = callees.find(n.id); hit.empty() && e != callees.end()) hit = e->second;
    });
    return hit;
  }
  std::optional<int64_t> constantOf(int64_t id) const {
    const Node *n = unwrap(id);
    if (!n) return std::nullopt;
    if (n->kind == "IntegerNode") {
      const AstField *v = field(*n, "value");
      if (!v || v->kind != AstField::Kind::Integer || field(*n, "bigval")) return std::nullopt;
      return std::get<int64_t>(v->value);
    }
    if (n->kind == "ConstantReadNode") {
      auto it = admitted.constants.find(str(*n, "name"));
      if (it != admitted.constants.end()) return it->second;
      return std::nullopt;
    }
    // DECISION 0014 D5: `Mod::NAME`, keyed that way in the admitted map, so a
    // board constant bounds a loop the way a top-level one does
    if (n->kind == "ConstantPathNode") {
      const Node *parent = unwrap(ref(*n, "parent"));
      if (!parent || parent->kind != "ConstantReadNode") return std::nullopt;
      auto it = admitted.constants.find(str(*parent, "name") + "::" + str(*n, "name"));
      if (it != admitted.constants.end()) return it->second;
      return std::nullopt;
    }
    if (n->kind == "CallNode" && str(*n, "name") == "-@" && ref(*n, "arguments") < 0)
      if (auto c = constantOf(ref(*n, "receiver")))
        if (*c != std::numeric_limits<int64_t>::min()) return -*c;
    return std::nullopt;
  }

  // ---- canonical rendering, for the digest ----------------------------

  std::string renderAst(int64_t id) const {
    const Node *n = node(id);
    if (!n) return "(none)";
    const std::string &k = n->kind;
    if (k == "IntegerNode") {
      const AstField *big = field(*n, "bigval");
      if (big && big->kind == AstField::Kind::String) return std::get<std::string>(big->value);
      return std::to_string(integer(*n, "value"));
    }
    if (k == "TrueNode") return "true";
    if (k == "FalseNode") return "false";
    if (k == "LocalVariableReadNode") return "(lvar " + str(*n, "name") + ")";
    if (k == "ConstantReadNode") return "(const " + str(*n, "name") + ")";
    if (k == "ConstantPathNode") {
      const Node *parent = node(ref(*n, "parent"));
      const std::string mod = parent && parent->kind == "ConstantReadNode"
                                  ? str(*parent, "name")
                                  : std::string("?");
      return "(const " + mod + "::" + str(*n, "name") + ")";
    }
    if (k == "SymbolNode") return ":" + str(*n, "value");
    if (k == "ParenthesesNode") return renderAst(ref(*n, "body"));
    if (k == "StatementsNode") {
      const auto body = array(*n, "body");
      if (body.size() == 1) return renderAst(body[0]);
      std::string s = "(seq";
      for (auto c : body) s += " " + renderAst(c);
      return s + ")";
    }
    if (k == "AndNode" || k == "OrNode")
      return std::string(k == "AndNode" ? "(and " : "(or ") + renderAst(ref(*n, "left")) +
             " " + renderAst(ref(*n, "right")) + ")";
    if (k == "CallNode") {
      const auto recv = ref(*n, "receiver");
      std::string s = recv >= 0 ? "(call " + str(*n, "name") + " " + renderAst(recv)
                                : "(fcall " + str(*n, "name");
      if (const Node *a = node(ref(*n, "arguments")))
        for (auto c : array(*a, "arguments")) s += " " + renderAst(c);
      if (ref(*n, "block") >= 0) s += " (block " + renderAst(ref(*n, "block")) + ")";
      return s + ")";
    }
    // Any other kind: every semantic field, in the model's key order.
    std::string s = "(" + k;
    for (const auto &f : n->fields) {
      if (isPosition(f.key)) continue;
      s += " " + f.key + "=";
      switch (f.kind) {
      case AstField::Kind::String:
      case AstField::Kind::FloatSpelling:
        s += "\"" + std::get<std::string>(f.value) + "\"";
        break;
      case AstField::Kind::Integer: s += std::to_string(std::get<int64_t>(f.value)); break;
      case AstField::Kind::Reference: s += renderAst(std::get<int64_t>(f.value)); break;
      case AstField::Kind::Array: {
        s += "[";
        bool first = true;
        for (auto c : std::get<std::vector<int64_t>>(f.value)) {
          s += (first ? "" : " ") + renderAst(c);
          first = false;
        }
        s += "]";
        break;
      }
      }
    }
    return s + ")";
  }

  // ---- the walk ----------------------------------------------------------

  struct Walker {
    Walker(Analysis &a, std::string m, Env e, bool p)
        : A(a), method(std::move(m)), env(std::move(e)), pure(p) {}
    Analysis &A;
    std::string method;
    Env env;
    bool live = true;
    /// A PURE walk evaluates an expression and records nothing: it is how a
    /// bound is read at a loop head without the walk also counting its calls.
    bool pure = false;
    std::vector<int64_t> stack;
    int64_t predicateOf = -1;

    Val eval(int64_t id);
    Val call(const Node &n);
    Val loop(const Node &n);
    /// DECISION 0041 stage 1: a loop whose body is a literal block.
    Val blockLoop(const Node &n, const core::BlockLoop &loop);
    /// The element count of the buffer `buf` in this method: the entry's
    /// declared count, or `size(buf)` in a helper.
    Val sizeOf(const std::string &buf) const;
  };

  struct Attempt {
    bool pass = false;
    std::string reason, detail, iv;
    ExprRef bound;
  };
  Attempt attempt(int64_t cmp, const Node &loop, const Env &before, const Env &head,
                  const std::set<std::string> &assigned,
                  const std::vector<int64_t> &stack) const;
  void classify(LoopRec &rec, const Node &loop, const Env &before, const Env &head,
                const std::set<std::string> &assigned,
                const std::vector<int64_t> &stack) const;
  std::string varDetail(const std::vector<std::pair<std::string, int64_t>> &vars,
                        const std::vector<int64_t> &stack) const;
  void classifyBlock(LoopRec &rec, const core::BlockLoop &loop, const Env &atReceiver,
                     const Env &atLimit, const std::vector<int64_t> &stack,
                     const Val &size) const;
  core::BlockLoopShape blockLoopShape(const Node &n) const {
    return core::classifyBlockLoop(n, [&](int64_t id) { return node(id); });
  }

  // ---- composition -------------------------------------------------------

  struct Occ {
    ExprRef e;  ///< null when unknown
    std::string reason, detail;
  };
  Val substitute(const ExprRef &e, const Subst &subst, const std::string &method) const;
  Val substituteVal(const Val &v, const Subst &subst, const std::string &method) const;
  Occ occurrence(const LoopRec &rec, const Subst &subst, const std::string &method) const;
  void expand(const std::string &method, const Subst &subst, const Occ &multiplier,
              const std::vector<std::string> &context, size_t depth);
};

Val Analysis::Walker::eval(int64_t id) {
  const Node *n = A.node(id);
  if (!n) return Val::opaque("unbound");
  const std::string &k = n->kind;
  if (k == "IntegerNode") {
    if (auto c = A.constantOf(id)) return Val::of(mkConst(*c));
    return Val::opaque("unsupported-operator", "an integer outside signed 64 bits");
  }
  if (k == "ConstantReadNode") {
    if (auto c = A.constantOf(id)) return Val::of(mkConst(*c));
    return Val::opaque("unbound", str(*n, "name"));
  }
  if (k == "ConstantPathNode") {
    if (auto c = A.constantOf(id)) return Val::of(mkConst(*c));
    return Val::opaque("unbound", A.renderAst(id));
  }
  if (k == "TrueNode" || k == "FalseNode") return Val::opaque("boolean");
  if (k == "LocalVariableReadNode") {
    auto it = env.find(str(*n, "name"));
    return it == env.end() ? Val::opaque("unbound", str(*n, "name")) : it->second;
  }
  if (k == "LocalVariableWriteNode") {
    const Val v = eval(ref(*n, "value"));
    env[str(*n, "name")] = v;
    // DECISION 0041 STAGE 2: the array's size, exactly: the constant when it
    // is one within the region, else a symbol of its own. The symbol is only
    // known to lie in [0, the region's elements]; it is resolved there once,
    // on the entry's totals (resolveArraySizes), never stood in for by the
    // capacity as a value (the review: `i = a.size; while i < 32`).
    if (auto lr = A.loops.find(ref(*n, "value"));
        !pure && lr != A.loops.end() && A.arrayNews.count(lr->first)) {
      const std::string local = str(*n, "name");
      const ExprRef &fill = lr->second.bound;
      A.arraySizes[method][local] =
          fill && fill->op == Expr::Op::Const && A.arrayConstSize.count(lr->first)
              ? fill
              : mkParam(kArraySizePrefix + method + ":" + local + ")");
    }
    return v;
  }
  if (k == "LocalVariableOperatorWriteNode") {
    // `x op= e` is `x = x op e`, and Ruby READS x BEFORE evaluating e. Taking
    // the current value afterwards would use whatever `e` assigned to x
    // instead: measured, `m -= (m = 0)` derived `0 - 0` rather than `m - 0`,
    // and a loop bounded by `m` was then reported as running no times at all
    // while the object it describes ran `n`.
    const std::string name = str(*n, "name");
    auto it = env.find(name);
    const Val cur = it == env.end() ? Val::opaque("unbound", name) : it->second;
    const Val rhs = eval(ref(*n, "value"));
    const Val v = arith(str(*n, "binary_operator"), cur, rhs);
    env[name] = v;
    return v;
  }
  if (k == "ParenthesesNode") return eval(ref(*n, "body"));
  if (k == "StatementsNode") {
    Val last = Val::opaque("unbound");
    for (auto c : array(*n, "body")) last = eval(c);
    return last;
  }
  if (k == "ElseNode") return eval(ref(*n, "statements"));
  if (k == "IfNode" || k == "UnlessNode") {
    eval(ref(*n, "predicate"));
    const Env before = env;
    const bool liveBefore = live;
    const auto st = ref(*n, "statements");
    const auto sub = ref(*n, k == "UnlessNode" ? "else_clause" : "subsequent");
    const Val a = st >= 0 ? eval(st) : Val::opaque("unbound");
    const Env envA = env;
    const bool liveA = live;
    env = before;
    live = liveBefore;
    const Val b = sub >= 0 ? eval(sub) : Val::opaque("unbound");
    const Env envB = env;
    const bool liveB = live;
    // A branch that does not fall through contributes no bindings.
    if (liveA && !liveB) env = envA;
    else if (liveB && !liveA) env = envB;
    else env = joinEnv(envA, envB);
    live = liveA || liveB;
    return sameVal(a, b) ? a : Val::opaque("multiple-definitions");
  }
  if (k == "AndNode" || k == "OrNode") {
    eval(ref(*n, "left"));
    const Env skipped = env;
    const bool liveBefore = live;
    eval(ref(*n, "right"));
    env = joinEnv(env, skipped);
    live = liveBefore;
    return Val::opaque("boolean");
  }
  if (k == "ReturnNode") {
    eval(ref(*n, "arguments"));
    live = false;
    return Val::opaque("unbound");
  }
  if (k == "ArgumentsNode") {
    for (auto c : array(*n, "arguments")) eval(c);
    return Val::opaque("unbound");
  }
  if (k == "BreakNode" || k == "NextNode") {
    live = false;
    return Val::opaque("unbound");
  }
  if (k == "WhileNode") return pure ? Val::opaque("unbound") : loop(*n);
  if (k == "CallNode") {
    core::BlockLoopShape shape = A.blockLoopShape(*n);
    if (shape.loop) return pure ? Val::opaque("unbound") : blockLoop(*n, *shape.loop);
    return call(*n);
  }
  if (k == "IndexOperatorWriteNode") {
    eval(ref(*n, "receiver"));
    eval(ref(*n, "arguments"));
    eval(ref(*n, "value"));
    return Val::opaque("buffer-element");
  }
  for (const auto &f : n->fields) {
    if (f.kind == AstField::Kind::Reference) eval(std::get<int64_t>(f.value));
    else if (f.kind == AstField::Kind::Array)
      for (auto c : std::get<std::vector<int64_t>>(f.value)) eval(c);
  }
  return Val::opaque("unsupported-operator", k);
}

Val Analysis::Walker::call(const Node &n) {
  const std::string name = str(n, "name");
  const auto receiver = ref(n, "receiver");
  std::vector<int64_t> argIds;
  if (const Node *a = A.node(ref(n, "arguments"))) argIds = array(*a, "arguments");
  // DECISION 0014: an extern call. The receiver is a module name, not a value.
  // The site is recorded like a call into the closure, with its enclosing
  // loops, so the expansion counts it under the same multiplicities; its
  // result is opaque, as any call's is.
  if (const Node *recv = A.node(receiver);
      !pure && recv && recv->kind == "ConstantReadNode" && A.facts.isApplication()) {
    const std::string module = str(*recv, "name");
    for (size_t i = 0; i < A.facts.externs.size(); ++i) {
      const ExternFact &e = A.facts.externs[i];
      if (e.module != module || e.fn != name) continue;
      for (auto id : argIds) eval(id);
      CallRec rec;
      rec.externIndex = static_cast<int64_t>(i);
      rec.enclosing = stack;
      rec.inPredicate = predicateOf >= 0 && !stack.empty() && stack.back() == predicateOf;
      rec.line = integer(n, "node_line");
      rec.column = integer(n, "node_col");
      auto &m = A.methods[method];
      m.events.push_back(-1 - static_cast<int64_t>(m.calls.size()));
      m.calls.push_back(std::move(rec));
      return Val::opaque("call-result", module + "." + name);
    }
  }
  // DECISION 0041 STAGE 2: Array.new fills its elements, one loop of its
  // own. Its bound is the size when that is a constant within the region,
  // and the region's whole element count otherwise: a larger size fails
  // with CAPACITY before the fill.
  if (A.arrayNews.count(n.id)) {
    const Val size = argIds.empty() ? Val::opaque("unbound") : eval(argIds[0]);
    for (size_t i = 1; i < argIds.size(); ++i) eval(argIds[i]);
    auto lr = A.loops.find(n.id);
    if (!pure && lr != A.loops.end()) {
      LoopRec &rec = lr->second;
      rec.enclosing = stack;
      if (!stack.empty()) rec.finding.parent = A.loops[stack.back()].finding.id;
      A.methods[method].events.push_back(n.id);
      LoopFinding &f = rec.finding;
      f.header = "Array.new " + (argIds.empty() ? std::string("?") : A.renderAst(argIds[0]));
      f.digest = hexDigest("v" + std::to_string(kLoopDigestVersion) + ":" + f.header);
      const int64_t cap = A.admitted.scratchElements;
      const bool exact = size.e && size.e->op == Expr::Op::Const && size.e->value >= 0 &&
                         size.e->value <= cap;
      if (exact) A.arrayConstSize.insert(n.id);
      // The fill's count: a bound, used only as a count of iterations.
      rec.bound = exact ? size.e : mkConst(cap);
      f.pass = true;
      f.bound = render(rec.bound);
    }
    return Val::opaque("array");
  }
  // DECISION 0041 STAGE 2: an array's size.
  if (name == "size" && argIds.empty())
    if (const Node *r = A.node(receiver); r && r->kind == "LocalVariableReadNode")
      return sizeOf(str(*r, "name"));
  Val recv;
  if (receiver >= 0) recv = eval(receiver);
  std::vector<Val> args;
  for (auto id : argIds) args.push_back(eval(id));

  if (receiver >= 0) {
    if (name == "[]") return Val::opaque("buffer-element");
    if (name == "[]=") return args.size() == 2 ? args[1] : Val::opaque("unbound");
    if (name == "<" || name == "<=" || name == ">" || name == ">=" || name == "==" ||
        name == "!=" || name == "!")
      return Val::opaque("boolean");
    if (args.empty() && name == "-@")
      return recv.e ? Val::of(mkNeg(recv.e)) : recv;
    if (args.empty() && name == "+@") return recv;
    if (args.size() == 1 &&
        (name == "+" || name == "-" || name == "*" || name == "/" || name == "%"))
      return arith(name, recv, args[0]);
    return Val::opaque("unsupported-operator", "`" + name + "`");
  }
  if (name == "core_fail") {
    live = false;
    return Val::opaque("unbound");
  }
  if (auto e = A.callees.find(n.id); !pure && e != A.callees.end()) {
    CallRec rec;
    rec.callee = e->second;
    rec.args = args;
    for (auto id : argIds) {
      const Node *a = A.node(id);
      rec.sizes.push_back(a && a->kind == "LocalVariableReadNode" ? sizeOf(str(*a, "name"))
                                                                : Val::opaque("unbound"));
    }
    rec.enclosing = stack;
    rec.inPredicate = predicateOf >= 0 && !stack.empty() && stack.back() == predicateOf;
    rec.line = integer(n, "node_line");
    rec.column = integer(n, "node_col");
    auto &m = A.methods[method];
    m.events.push_back(-1 - static_cast<int64_t>(m.calls.size()));
    m.calls.push_back(std::move(rec));
  }
  return Val::opaque("call-result", name);
}

Val Analysis::Walker::loop(const Node &n) {
  LoopRec &rec = A.loops[n.id];
  rec.enclosing = stack;
  if (!stack.empty()) rec.finding.parent = A.loops[stack.back()].finding.id;
  A.methods[method].events.push_back(n.id);

  const auto pred = ref(n, "predicate"), st = ref(n, "statements");
  std::set<std::string> assigned = A.assignedIn(pred);
  for (const auto &name : A.assignedIn(st)) assigned.insert(name);
  const Env before = env;
  Env head = env;
  for (const auto &name : assigned) head[name] = Val::of(mkVar(name, n.id));
  A.classify(rec, n, before, head, assigned, stack);

  const bool liveBefore = live;
  env = head;
  stack.push_back(n.id);
  predicateOf = n.id;
  eval(pred);
  predicateOf = -1;
  live = true;
  eval(st);
  stack.pop_back();
  // After the loop, whatever it assigned holds the value of SOME iteration.
  env = head;
  live = liveBefore;
  return Val::opaque("unbound");
}

Val Analysis::Walker::sizeOf(const std::string &buf) const {
  // DECISION 0041 STAGE 2: an array this method made.
  if (auto m = A.arraySizes.find(method.empty() ? A.walking : method); m != A.arraySizes.end())
    if (auto b = m->second.find(buf); b != m->second.end()) return Val::of(b->second);
  if (method == A.facts.entry)
    if (const EntryBufferFact *b = A.facts.buffer(buf)) {
      if (b->constCount) {
        if (*b->constCount > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
          return Val::opaque("unsupported-operator", "a count outside signed 64 bits");
        return Val::of(mkConst(static_cast<int64_t>(*b->constCount)));
      }
      if (!b->countName.empty()) return Val::of(mkParam(b->countName));
    }
  return Val::of(mkParam("size(" + buf + ")"));
}

/// DECISION 0041 stage 1. The receiver and the limit are evaluated once,
/// before the loop, so the loop's bound is their value there. The block's
/// parameters and its own locals are assigned in every iteration.
///
/// Each expression's bound is read in the environment it was evaluated in:
/// the receiver in the one at the call, the limit in the one the receiver
/// left. Reading either after both ran would apply an assignment in it
/// twice, or read the receiver after the limit changed it.
Val Analysis::Walker::blockLoop(const Node &n, const core::BlockLoop &loop) {
  using K = core::BlockLoop::Kind;
  const bool overBuffer = loop.kind == K::Each || loop.kind == K::EachWithIndex;
  Val size = Val::opaque("unbound");
  const Env atReceiver = env;
  Env atLimit = env;
  if (overBuffer) {
    const Node *r = A.node(loop.receiver);
    if (r && r->kind == "LocalVariableReadNode") size = sizeOf(str(*r, "name"));
  } else {
    eval(loop.receiver);
    atLimit = env;
    if (loop.limit >= 0) eval(loop.limit);
  }
  LoopRec &rec = A.loops[n.id];
  rec.enclosing = stack;
  if (!stack.empty()) rec.finding.parent = A.loops[stack.back()].finding.id;
  A.methods[method].events.push_back(n.id);

  std::set<std::string> assigned = A.assignedIn(loop.body);
  for (const auto &p : loop.params) assigned.insert(p);
  for (const auto &l : loop.locals) assigned.insert(l);
  const Env before = env;
  Env head = env;
  for (const auto &name : assigned) head[name] = Val::of(mkVar(name, n.id));
  A.classifyBlock(rec, loop, atReceiver, atLimit, stack, size);

  const bool liveBefore = live;
  env = head;
  stack.push_back(n.id);
  live = true;
  if (loop.body >= 0) eval(loop.body);
  stack.pop_back();
  env = head;
  live = liveBefore;
  return Val::opaque("unbound");
}

void Analysis::classifyBlock(LoopRec &rec, const core::BlockLoop &loop, const Env &atReceiver,
                             const Env &atLimit, const std::vector<int64_t> &stack,
                             const Val &size) const {
  using K = core::BlockLoop::Kind;
  LoopFinding &f = rec.finding;
  const std::string name = core::blockLoopName(loop.kind).str();
  f.header = name + " " + renderAst(loop.receiver);
  if (loop.limit >= 0) f.header += " " + renderAst(loop.limit);
  f.digest = hexDigest("v" + std::to_string(kLoopDigestVersion) + ":" + f.header);
  // The counter the block sees: the induction variable of a block loop.
  const size_t counter = loop.kind == K::EachWithIndex ? 1 : 0;
  rec.iv = loop.kind == K::Each || counter >= loop.params.size() ? "" : loop.params[counter];
  auto fail = [&](std::string reason, std::string detail) {
    f.pass = false;
    f.reason = std::move(reason);
    f.detail = std::move(detail);
  };
  auto pass = [&](ExprRef bound) {
    if (oversize(bound)) return fail("bound-not-expressible", tooLarge().detail);
    f.pass = true;
    rec.bound = bound;
    f.bound = render(bound);
  };
  if (loop.kind == K::Each || loop.kind == K::EachWithIndex) {
    if (!size.e) return fail("bound-not-expressible", describe(size));
    return pass(size.e);
  }
  // The receiver, and the limit of `upto` and `downto`: each must be an
  // expression over the method's parameters and constants at the loop's
  // entry, by the rules a `while` bound follows.
  auto value = [&](int64_t id, const char *what, const Env &at, ExprRef &out) -> bool {
    if (readsIndex(id)) {
      fail("bound-from-buffer-element", std::string("the ") + what + " reads a buffer element");
      return false;
    }
    if (const std::string callee = closureCallee(id); !callee.empty()) {
      fail("bound-from-call", std::string("the ") + what + " calls " + callee);
      return false;
    }
    Walker pureWalk(const_cast<Analysis &>(*this), "", at, /*pure=*/true);
    const Val v = pureWalk.eval(id);
    if (!v.e) {
      if (v.why == "buffer-element")
        fail("bound-from-buffer-element",
             std::string("the ") + what + " holds a buffer element read before the loop");
      else if (v.why == "call-result")
        fail("bound-from-call",
             std::string("the ") + what + " holds the result of a call to " + v.detail);
      else
        fail("bound-not-expressible", describe(v));
      return false;
    }
    std::vector<std::pair<std::string, int64_t>> vars;
    collectVars(v.e, vars);
    if (!vars.empty()) {
      fail("bound-not-expressible", varDetail(vars, stack));
      return false;
    }
    out = v.e;
    return true;
  };
  ExprRef recv, limit;
  if (!value(loop.receiver, "receiver", atReceiver, recv)) return;
  if (loop.kind == K::Times) return pass(mkMax(mkConst(0), recv));
  if (!value(loop.limit, "argument", atLimit, limit)) return;
  if (loop.kind == K::Upto)
    return pass(mkMax(mkConst(0), mkAdd(mkSub(limit, recv), mkConst(1))));
  return pass(mkMax(mkConst(0), mkAdd(mkSub(recv, limit), mkConst(1))));
}

std::string Analysis::varDetail(const std::vector<std::pair<std::string, int64_t>> &vars,
                                const std::vector<int64_t> &stack) const {
  bool allInduction = true;
  std::string names;
  for (const auto &v : vars) {
    const bool enclosing = std::find(stack.begin(), stack.end(), v.second) != stack.end();
    const auto it = loops.find(v.second);
    const bool induction = enclosing && it != loops.end() && it->second.iv == v.first;
    if (!induction) allInduction = false;
    if (!names.empty()) names += ", ";
    names += v.first + " of " + (it != loops.end() ? it->second.finding.id : "?");
  }
  if (allInduction)
    return "enclosing-induction: expressible over the induction variable of an "
           "enclosing loop (" + names + ")";
  for (const auto &v : vars) {
    const bool enclosing = std::find(stack.begin(), stack.end(), v.second) != stack.end();
    const auto it = loops.find(v.second);
    const std::string id = it != loops.end() ? it->second.finding.id : "?";
    if (enclosing && it != loops.end() && it->second.iv == v.first) continue;
    if (enclosing)
      return "enclosing-varying: " + v.first + " is assigned in enclosing loop " + id;
    return "after-loop: " + v.first + " holds a value left by loop " + id;
  }
  return "varying: " + names;
}

Analysis::Attempt Analysis::attempt(int64_t cmpId, const Node &loop, const Env &before,
                                    const Env &head, const std::set<std::string> &assigned,
                                    const std::vector<int64_t> &stack) const {
  Attempt out;
  auto fail = [&](std::string reason, std::string detail) {
    out.pass = false;
    out.reason = std::move(reason);
    out.detail = std::move(detail);
    return out;
  };
  const Node *cmp = unwrap(cmpId);
  const std::string op = cmp && cmp->kind == "CallNode" ? str(*cmp, "name") : "";
  std::vector<int64_t> argIds;
  if (cmp && cmp->kind == "CallNode")
    if (const Node *a = node(ref(*cmp, "arguments"))) argIds = array(*a, "arguments");
  if (!cmp || cmp->kind != "CallNode" || ref(*cmp, "receiver") < 0 || argIds.size() != 1 ||
      !(op == "<" || op == "<=" || op == ">" || op == ">=")) {
    if (cmp && cmp->kind == "OrNode")
      return fail("condition-not-induction", "the condition is a disjunction (`||`)");
    if (cmp && cmp->kind == "CallNode" && (op == "!=" || op == "=="))
      return fail("condition-not-induction", "`" + op + "` is not an ordered comparison");
    if (cmp && cmp->kind == "CallNode" && ref(*cmp, "receiver") < 0)
      return fail("condition-not-induction", "the condition is a call to " + op);
    return fail("condition-not-induction",
                "the condition is not a comparison of an integer local against a bound");
  }

  const int64_t left = ref(*cmp, "receiver"), right = argIds[0];
  const std::string lname = lvarName(left), rname = lvarName(right);
  const bool lv = !lname.empty() && assigned.count(lname);
  const bool rv = !rname.empty() && assigned.count(rname);
  std::string rel = op;
  int64_t boundId;
  if (lv && rv) {
    out.iv = lname;
    return fail("bound-varies",
                "both " + lname + " and " + rname + " are assigned in the loop");
  }
  if (lv) {
    out.iv = lname;
    boundId = right;
  } else if (rv) {
    out.iv = rname;
    boundId = left;
    rel = op == "<" ? ">" : op == "<=" ? ">=" : op == ">" ? "<" : "<=";
  } else {
    if (!readsAny(left, assigned).empty() || !readsAny(right, assigned).empty())
      return fail("condition-not-induction",
                  "the side that changes in the loop is not a plain local");
    return fail("condition-not-induction",
                "neither side of the comparison is assigned in the loop");
  }
  const std::string &iv = out.iv;

  // Every assignment to the induction variable.
  if (assigns(ref(loop, "predicate"), iv))
    return fail("induction-reassigned", iv + " is assigned in the condition");
  std::vector<const Node *> writes;
  forEach(ref(loop, "statements"), [&](const Node &n) {
    if ((n.kind == "LocalVariableWriteNode" || n.kind == "LocalVariableOperatorWriteNode") &&
        str(n, "name") == iv)
      writes.push_back(&n);
  });
  std::optional<std::string> reassigned, nonConstant, away;
  int64_t step = 0;
  for (const Node *w : writes) {
    std::optional<int64_t> delta;
    bool readsSelf = false;
    if (w->kind == "LocalVariableOperatorWriteNode") {
      const std::string bop = str(*w, "binary_operator");
      readsSelf = true;
      if (bop == "+" || bop == "-")
        if (auto c = constantOf(ref(*w, "value")))
          if (!(bop == "-" && *c == std::numeric_limits<int64_t>::min()))
            delta = bop == "+" ? *c : -*c;
    } else {
      const int64_t v = ref(*w, "value");
      readsSelf = !readsAny(v, {iv}).empty();
      const Node *call = unwrap(v);
      if (call && call->kind == "CallNode" && ref(*call, "receiver") >= 0) {
        std::vector<int64_t> cargs;
        if (const Node *a = node(ref(*call, "arguments"))) cargs = array(*a, "arguments");
        const std::string cop = str(*call, "name");
        if (cargs.size() == 1 && (cop == "+" || cop == "-")) {
          if (lvarName(ref(*call, "receiver")) == iv) {
            if (auto c = constantOf(cargs[0]))
              if (!(cop == "-" && *c == std::numeric_limits<int64_t>::min()))
                delta = cop == "+" ? *c : -*c;
          } else if (cop == "+" && lvarName(cargs[0]) == iv) {
            delta = constantOf(ref(*call, "receiver"));
          }
        }
      }
    }
    const std::string at = " at " + position(*w);
    if (delta) {
      const bool toward = (rel == "<" || rel == "<=") ? *delta > 0 : *delta < 0;
      if (!toward && !away)
        away = "a step of " + std::to_string(*delta) + at + " does not move " + iv +
               " toward the bound (`" + rel + "`)";
      // INT64_MIN has no positive magnitude. Its magnitude is one MORE than
      // INT64_MAX, and a larger step can only mean fewer iterations, so
      // INT64_MAX stands for it and the bound stays an upper bound. Negating
      // it would have been undefined, and left `step` negative, which
      // `ceil_div` is not defined for.
      const int64_t mag = *delta == std::numeric_limits<int64_t>::min()
                              ? std::numeric_limits<int64_t>::max()
                              : (*delta < 0 ? -*delta : *delta);
      if (toward && (step == 0 || mag < step)) step = mag;
    } else if (readsSelf) {
      if (!nonConstant) nonConstant = iv + " changes by a non-constant amount" + at;
    } else if (!reassigned) {
      reassigned = iv + " is assigned a value that is not a step of itself" + at;
    }
  }
  if (reassigned) return fail("induction-reassigned", *reassigned);
  if (nonConstant) return fail("step-not-constant", *nonConstant);
  if (away) return fail("step-away-from-bound", *away);

  // Exactly one step on every path to the next iteration.
  struct Paths {
    const Analysis &A;
    const std::string &iv;
    unsigned backEdge = 0;
    bool nextZero = false, conditional = false;
    // Bit 0: no step so far. Bit 1: exactly one. Bit 2: more than one.
    static unsigned shift(unsigned s) { return (s & 1 ? 2u : 0u) | (s & 6 ? 4u : 0u); }
    unsigned walk(int64_t id, unsigned in) {
      if (in == 0 || id < 0) return in;
      const Node *n = A.node(id);
      if (!n) return in;
      const std::string &k = n->kind;
      if (k == "StatementsNode") {
        for (auto c : array(*n, "body")) in = walk(c, in);
        return in;
      }
      if (k == "ArgumentsNode") {
        for (auto c : array(*n, "arguments")) in = walk(c, in);
        return in;
      }
      if (k == "ParenthesesNode") return walk(ref(*n, "body"), in);
      if (k == "ElseNode") return walk(ref(*n, "statements"), in);
      if (k == "IfNode" || k == "UnlessNode") {
        const unsigned s = walk(ref(*n, "predicate"), in);
        const auto st = ref(*n, "statements");
        const auto sub = ref(*n, k == "UnlessNode" ? "else_clause" : "subsequent");
        return (st >= 0 ? walk(st, s) : s) | (sub >= 0 ? walk(sub, s) : s);
      }
      if (k == "AndNode" || k == "OrNode") {
        const unsigned s = walk(ref(*n, "left"), in);
        if (A.assigns(ref(*n, "right"), iv)) conditional = true;
        return s | walk(ref(*n, "right"), s);
      }
      if (k == "WhileNode") {
        if (A.assigns(id, iv)) conditional = true;
        return in;
      }
      if (k == "CallNode") {
        core::BlockLoopShape shape = A.blockLoopShape(*n);
        if (shape.loop) {
          const unsigned s = walk(shape.loop->limit, walk(shape.loop->receiver, in));
          if (A.assigns(shape.loop->body, iv)) conditional = true;
          return s;
        }
      }
      if (k == "BreakNode") return 0;
      if (k == "NextNode") {
        backEdge |= in;
        if (in & 1) nextZero = true;
        return 0;
      }
      if (k == "ReturnNode") {
        walk(ref(*n, "arguments"), in);
        return 0;
      }
      if (k == "LocalVariableWriteNode" || k == "LocalVariableOperatorWriteNode") {
        const unsigned s = walk(ref(*n, "value"), in);
        return str(*n, "name") == iv ? shift(s) : s;
      }
      if (k == "CallNode") {
        unsigned s = walk(ref(*n, "receiver"), in);
        s = walk(ref(*n, "arguments"), s);
        if (ref(*n, "receiver") < 0 && str(*n, "name") == "core_fail") return 0;
        return s;
      }
      for (const auto &f : n->fields) {
        if (f.kind == AstField::Kind::Reference) in = walk(std::get<int64_t>(f.value), in);
        else if (f.kind == AstField::Kind::Array)
          for (auto c : std::get<std::vector<int64_t>>(f.value)) in = walk(c, in);
      }
      return in;
    }
  } paths{*this, iv};
  paths.backEdge |= paths.walk(ref(loop, "statements"), 1);
  if (paths.nextZero)
    return fail("step-skipped-by-next",
                "a `next` reaches the next iteration before " + iv + " is changed");
  if (paths.conditional)
    return fail("step-conditional",
                iv + " is changed inside a nested loop or the right operand of `&&` or `||`");
  if (paths.backEdge & 1)
    return fail("step-conditional",
                "a path reaches the next iteration without changing " + iv);
  if (paths.backEdge & 4)
    return fail("step-conditional",
                "a path changes " + iv + " more than once in one iteration");

  // The bound.
  if (readsIndex(boundId))
    return fail("bound-from-buffer-element", "the bound reads a buffer element");
  if (const std::string callee = closureCallee(boundId); !callee.empty())
    return fail("bound-from-call", "the bound calls " + callee);
  if (const std::string name = readsAny(boundId, assigned); !name.empty())
    return fail("bound-varies", name + " is assigned in the loop");
  Walker pureWalk(const_cast<Analysis &>(*this), "", head, /*pure=*/true);
  const Val bound = pureWalk.eval(boundId);
  if (!bound.e) {
    if (bound.why == "buffer-element")
      return fail("bound-from-buffer-element",
                  "the bound holds a buffer element read before the loop");
    if (bound.why == "call-result")
      return fail("bound-from-call",
                  "the bound holds the result of a call to " + bound.detail);
    return fail("bound-not-expressible", describe(bound));
  }
  {
    std::vector<std::pair<std::string, int64_t>> vars;
    collectVars(bound.e, vars);
    if (!vars.empty()) return fail("bound-not-expressible", varDetail(vars, stack));
  }

  // The start.
  auto it = before.find(iv);
  if (it == before.end())
    return fail("start-not-expressible", "unbound: " + iv + " has no value before the loop");
  if (!it->second.e) return fail("start-not-expressible", describe(it->second));
  {
    std::vector<std::pair<std::string, int64_t>> vars;
    collectVars(it->second.e, vars);
    if (!vars.empty()) return fail("start-not-expressible", varDetail(vars, stack));
  }

  const ExprRef &s = it->second.e, &b = bound.e;
  // Every path above either found a step toward the bound or failed, so this
  // cannot fire; it is here because `ceil_div` is defined for a positive
  // divisor only, and a zero divisor would be a division by zero downstream.
  if (step <= 0)
    return fail("step-away-from-bound", "no step moves " + iv + " toward the bound");
  ExprRef span;
  if (rel == "<") span = mkSub(b, s);
  else if (rel == "<=") span = mkAdd(mkSub(b, s), mkConst(1));
  else if (rel == ">") span = mkSub(s, b);
  else span = mkAdd(mkSub(s, b), mkConst(1));
  ExprRef bounded = mkCeilDiv(mkMax(mkConst(0), span), step);
  if (oversize(bounded)) return fail("bound-not-expressible", tooLarge().detail);
  out.pass = true;
  out.bound = bounded;
  return out;
}

void Analysis::classify(LoopRec &rec, const Node &loop, const Env &before, const Env &head,
                        const std::set<std::string> &assigned,
                        const std::vector<int64_t> &stack) const {
  LoopFinding &f = rec.finding;
  const auto pred = ref(loop, "predicate");
  f.header = "while " + renderAst(pred);
  f.digest = hexDigest("v" + std::to_string(kLoopDigestVersion) + ":" + f.header);

  auto apply = [&](const Attempt &a) {
    f.pass = a.pass;
    f.reason = a.pass ? "" : a.reason;
    f.detail = a.pass ? "" : a.detail;
    rec.iv = a.iv;
    rec.bound = a.bound;
    f.bound = a.pass ? render(a.bound) : "";
  };

  const Node *p = unwrap(pred);
  if (p && p->kind == "TrueNode") {
    f.pass = false;
    f.reason = "no-exit-condition";
    f.detail = "the condition is `true`; only `break`, `return` or a failure leaves the loop";
    return;
  }
  std::vector<int64_t> conjuncts;
  {
    std::vector<int64_t> work{pred};
    while (!work.empty()) {
      const int64_t id = work.back();
      work.pop_back();
      const Node *c = unwrap(id);
      if (c && c->kind == "AndNode") {
        work.push_back(ref(*c, "right"));
        work.push_back(ref(*c, "left"));
      } else {
        conjuncts.push_back(c ? c->id : id);
      }
    }
  }
  if (conjuncts.size() == 1) {
    apply(attempt(conjuncts[0], loop, before, head, assigned, stack));
    return;
  }
  // `A && B`: the loop continues only while EVERY conjunct holds, so any one
  // conjunct that the rules bound bounds the loop.
  std::vector<Attempt> attempts;
  for (size_t i = 0; i < conjuncts.size(); ++i) {
    Attempt a = attempt(conjuncts[i], loop, before, head, assigned, stack);
    if (a.pass) {
      apply(a);
      f.conjunct = LoopConjunct{static_cast<unsigned>(i), renderAst(conjuncts[i])};
      return;
    }
    attempts.push_back(std::move(a));
  }
  Attempt first = attempts[0];
  std::string detail;
  for (size_t i = 0; i < attempts.size(); ++i) {
    if (!detail.empty()) detail += "; ";
    detail += "conjunct " + std::to_string(i) + ": " + attempts[i].reason + " (" +
              attempts[i].detail + ")";
  }
  first.detail = detail;
  apply(first);
}

// ---- composition ------------------------------------------------------------

Val Analysis::substitute(const ExprRef &e, const Subst &subst,
                         const std::string &method) const {
  switch (e->op) {
  case Expr::Op::Const:
  case Expr::Op::Var: return Val::of(e);
  case Expr::Op::Param: {
    // DECISION 0041 STAGE 2: an array's size symbol belongs to no method's
    // parameters; it travels up unchanged to the entry's totals.
    if (isArraySize(e)) return Val::of(e);
    auto it = subst.find(e->name);
    if (it == subst.end())
      return Val::opaque("unbound", "parameter " + e->name + " of " + method);
    if (!it->second.e)
      return Val::opaque(it->second.why, "parameter " + e->name + " of " + method +
                                             " receives " + describe(it->second));
    return it->second;
  }
  case Expr::Op::Neg: {
    Val a = substitute(e->a, subst, method);
    return a.e ? checked(mkNeg(a.e)) : a;
  }
  default: break;
  }
  Val a = substitute(e->a, subst, method);
  if (!a.e) return a;
  Val b = substitute(e->b, subst, method);
  if (!b.e) return b;
  switch (e->op) {
  case Expr::Op::Add: return checked(mkAdd(a.e, b.e));
  case Expr::Op::Sub: return checked(mkSub(a.e, b.e));
  case Expr::Op::Mul: return checked(mkMul(a.e, b.e));
  case Expr::Op::Max: return checked(mkMax(a.e, b.e));
  case Expr::Op::CeilDiv: {
    auto c = constOf(b.e);
    return checked(c ? mkCeilDiv(a.e, *c) : mkBinary(Expr::Op::CeilDiv, a.e, b.e));
  }
  case Expr::Op::FloorDiv: return checked(mkFloorDiv(a.e, b.e));
  case Expr::Op::FloorMod: return checked(mkFloorMod(a.e, b.e));
  default: return Val::opaque("unsupported-operator");
  }
}

Val Analysis::substituteVal(const Val &v, const Subst &subst,
                            const std::string &method) const {
  return v.e ? substitute(v.e, subst, method) : v;
}

Analysis::Occ Analysis::occurrence(const LoopRec &rec, const Subst &subst,
                                   const std::string &method) const {
  if (!rec.finding.pass)
    return {nullptr, rec.finding.reason, rec.finding.detail};
  const Val v = substitute(rec.bound, subst, method);
  if (!v.e && v.why == "expression-too-large")
    return {nullptr, "expression-too-large", v.detail};
  if (!v.e) return {nullptr, "argument-not-expressible", v.detail.empty() ? v.why : v.detail};
  std::vector<std::pair<std::string, int64_t>> vars;
  collectVars(v.e, vars);
  if (!vars.empty()) {
    const auto it = loops.find(vars[0].second);
    return {nullptr, "argument-not-expressible",
            "an argument depends on " + vars[0].first + ", which varies in loop " +
                (it != loops.end() ? it->second.finding.id : "?")};
  }
  return {v.e, "", ""};
}

void Analysis::expand(const std::string &method, const Subst &subst, const Occ &multiplier,
                      const std::vector<std::string> &context, size_t depth) {
  // The checker refused recursion before this runs; the depth guard only keeps
  // a defect elsewhere from becoming a hang here.
  if (depth > methods.size() + 1 || truncated) return;
  const MethodRec &m = methods[method];
  std::map<int64_t, Occ> own;
  for (auto id : m.loops) own[id] = occurrence(loops.at(id), subst, method);

  auto multiplierFor = [&](const std::vector<int64_t> &enclosing, int64_t predicateOf) {
    Occ acc = multiplier;
    for (auto e : enclosing) {
      if (!acc.e) break;
      Occ b = own[e];
      if (!b.e)
        return Occ{nullptr, "enclosing-unknown",
                   "enclosing loop " + loops.at(e).finding.id + " is " + b.reason};
      acc.e = mkMul(acc.e, e == predicateOf ? mkAdd(b.e, mkConst(1)) : b.e);
      if (oversize(acc.e))
        return Occ{nullptr, "expression-too-large", tooLarge().detail};
    }
    return acc;
  };
  auto contextFor = [&](const std::vector<int64_t> &enclosing) {
    std::vector<std::string> ctx = context;
    for (auto e : enclosing) ctx.push_back("loop:" + loops.at(e).finding.id);
    return ctx;
  };

  for (auto event : m.events) {
    // A program whose call graph fans out doubles its occurrences per level.
    // The expansion stops here and the work bound says so, rather than
    // writing a report nothing can hold.
    if (result.terms.size() >= kMaxTerms) {
      truncated = true;
      result.limit = "too-many-terms";
      return;
    }
    if (event >= 0) {
      const LoopRec &rec = loops.at(event);
      const Occ &mine = own[event];
      const Occ mul = multiplierFor(rec.enclosing, -1);
      WorkTerm t;
      t.loop = rec.finding.id;
      t.context = contextFor(rec.enclosing);
      ExprRef expr;
      if (!mine.e) {
        t.reason = mine.reason;
        t.detail = mine.detail;
      } else if (!mul.e) {
        t.reason = mul.reason;
        t.detail = mul.detail;
      } else {
        expr = mkMul(mul.e, mine.e);
        if (oversize(expr)) {
          expr = nullptr;
          t.reason = "expression-too-large";
          t.detail = tooLarge().detail;
        } else {
          t.iterations = render(expr);
        }
      }
      result.terms.push_back(std::move(t));
      termExprs.push_back(expr);
      continue;
    }
    const CallRec &call = m.calls[static_cast<size_t>(-1 - event)];
    const Occ mul = multiplierFor(call.enclosing,
                                  call.inPredicate ? call.enclosing.back() : -1);
    if (call.externIndex >= 0) {
      // DECISION 0014: the site's occurrence IS its call count -- the product
      // of the enclosing derived bounds, composed through the helpers on the
      // way here. Both arms of a conditional are on the way, and both count.
      ExternTerm t;
      t.externIndex = static_cast<size_t>(call.externIndex);
      t.context = contextFor(call.enclosing);
      t.context.push_back("extern:" + facts.externs[t.externIndex].module + "." +
                          facts.externs[t.externIndex].fn + "@" + std::to_string(call.line) +
                          ":" + std::to_string(call.column));
      if (mul.e) t.calls = render(mul.e);
      else { t.reason = mul.reason; t.detail = mul.detail; }
      result.externTerms.push_back(std::move(t));
      externTermExprs.push_back(mul.e);
      continue;
    }
    Subst inner;
    const MethodRec &callee = methods[call.callee];
    for (size_t i = 0; i < callee.params.size(); ++i)
    {
      inner[callee.params[i]] = i < call.args.size()
                                    ? substituteVal(call.args[i], subst, method)
                                    : Val::opaque("unbound");
      if (i < call.sizes.size())
        inner["size(" + callee.params[i] + ")"] = substituteVal(call.sizes[i], subst, method);
    }
    std::vector<std::string> ctx = contextFor(call.enclosing);
    ctx.push_back("call:" + call.callee + "@" + std::to_string(call.line) + ":" +
                  std::to_string(call.column));
    expand(call.callee, inner, mul, ctx, depth + 1);
  }
}

/// DECISION 0041 STAGE 2. The symbol of an array whose size is not a
/// constant lies in [0, the region's elements]: an array that would be longer
/// fails with CAPACITY before anything that reads its size. A term that never
/// falls as the symbol grows takes it at the region's count, one that never
/// rises at 0, and one that does both (or cannot be told) is unknown.
ExprRef Analysis::resolveArraySizes(ExprRef e, std::string &why) const {
  std::set<std::string> syms;
  collectArraySizes(e, syms);
  for (const auto &sym : syms) {
    const Trend t = trend(e, sym);
    if (t == Trend::Any) {
      why = sym + " is in [0, " + std::to_string(admitted.scratchElements) +
            "], and this count does not move one way with it";
      return nullptr;
    }
    e = replaceParam(e, sym, mkConst(t == Trend::Down ? 0 : admitted.scratchElements));
    if (oversize(e)) {
      why = tooLarge().detail;
      return nullptr;
    }
  }
  return e;
}

ExprRef replaceParam(const ExprRef &e, const std::string &sym, const ExprRef &with) {
  switch (e->op) {
  case Expr::Op::Const:
  case Expr::Op::Var: return e;
  case Expr::Op::Param: return e->name == sym ? with : e;
  case Expr::Op::Neg: return mkNeg(replaceParam(e->a, sym, with));
  default: break;
  }
  const ExprRef a = replaceParam(e->a, sym, with), b = replaceParam(e->b, sym, with);
  switch (e->op) {
  case Expr::Op::Add: return mkAdd(a, b);
  case Expr::Op::Sub: return mkSub(a, b);
  case Expr::Op::Mul: return mkMul(a, b);
  case Expr::Op::Max: return mkMax(a, b);
  case Expr::Op::CeilDiv: {
    auto c = constOf(b);
    return c ? mkCeilDiv(a, *c) : mkBinary(Expr::Op::CeilDiv, a, b);
  }
  case Expr::Op::FloorDiv: return mkFloorDiv(a, b);
  default: return mkBinary(e->op, a, b);
  }
}

LoopBoundResult Analysis::run() {
  closure.insert(admitted.methods.begin(), admitted.methods.end());
  if (const Node *program = node(module.root()))
    if (const Node *statements = node(ref(*program, "statements")))
      for (auto id : array(*statements, "body"))
        if (const Node *n = node(id))
          if (n->kind == "DefNode" && ref(*n, "receiver") < 0 &&
              closure.count(str(*n, "name")))
            definitions[str(*n, "name")] = n;

  // Loop identities first: the ordinal is source order within the method.
  for (const auto &name : admitted.methods) {
    const Node *def = definitions[name];
    if (!def) continue;
    MethodRec &m = methods[name];
    if (const Node *ps = node(ref(*def, "parameters")))
      for (auto p : array(*ps, "requireds"))
        if (const Node *pn = node(p)) m.params.push_back(str(*pn, "name"));
    std::vector<const Node *> found;
    forEach(ref(*def, "body"), [&](const Node &n) {
      if (n.kind == "WhileNode" || (n.kind == "CallNode" && blockLoopShape(n).loop) ||
          arrayNews.count(n.id))
        found.push_back(&n);
    });
    std::sort(found.begin(), found.end(), [](const Node *a, const Node *b) {
      return std::make_tuple(integer(*a, "node_line"), integer(*a, "node_col"), a->id) <
             std::make_tuple(integer(*b, "node_line"), integer(*b, "node_col"), b->id);
    });
    for (size_t i = 0; i < found.size(); ++i) {
      LoopRec &rec = loops[found[i]->id];
      rec.node = found[i]->id;
      rec.finding.method = name;
      rec.finding.ordinal = static_cast<unsigned>(i);
      rec.finding.id = name + "#" + std::to_string(i);
      rec.finding.line = integer(*found[i], "node_line");
      rec.finding.column = integer(*found[i], "node_col");
      m.loops.push_back(found[i]->id);
    }
  }

  for (const auto &name : admitted.methods) {
    const Node *def = definitions[name];
    if (!def) continue;
    walking = name;
    Walker w(*this, name, {}, /*pure=*/false);
    for (const auto &p : methods[name].params) w.env[p] = Val::of(mkParam(p));
    w.eval(ref(*def, "body"));
  }

  for (const auto &name : admitted.methods)
    for (auto id : methods[name].loops) result.loops.push_back(loops.at(id).finding);

  Subst entry;
  for (const auto &p : methods[facts.entry].params) entry[p] = Val::of(mkParam(p));
  expand(facts.entry, entry, Occ{mkConst(1), "", ""}, {}, 0);

  // DECISION 0041 STAGE 2: each array-size symbol left in a term or an
  // extern count takes its worst value in [0, the region's elements].
  for (size_t i = 0; i < termExprs.size(); ++i) {
    if (!termExprs[i]) continue;
    std::string why;
    termExprs[i] = resolveArraySizes(termExprs[i], why);
    if (termExprs[i]) result.terms[i].iterations = render(termExprs[i]);
    else {
      result.terms[i].iterations.clear();
      result.terms[i].reason = "array-size";
      result.terms[i].detail = why;
    }
  }
  for (size_t k = 0; k < externTermExprs.size(); ++k) {
    if (!externTermExprs[k]) continue;
    std::string why;
    externTermExprs[k] = resolveArraySizes(externTermExprs[k], why);
    if (externTermExprs[k]) result.externTerms[k].calls = render(externTermExprs[k]);
    else {
      result.externTerms[k].calls.clear();
      result.externTerms[k].reason = "array-size";
      result.externTerms[k].detail = why;
    }
  }

  ExprRef sum = mkConst(0);
  if (truncated) result.workKnown = false;
  for (const auto &e : termExprs) {
    if (!result.workKnown) break;
    if (!e) {
      result.workKnown = false;
      break;
    }
    sum = mkAdd(sum, e);
    if (oversize(sum)) {
      result.workKnown = false;
      result.limit = "expression-too-large";
    }
  }
  result.work = result.workKnown ? render(sum) : "";

  // DECISION 0014: per extern, the sum of its sites' counts. One site whose
  // multiplicity is unknown, or an expansion that stopped, makes the count
  // not derived; nothing is estimated in its place.
  for (size_t i = 0; i < facts.externs.size(); ++i) {
    ExternCount c;
    c.externIndex = i;
    ExprRef total = mkConst(0);
    bool derived = !truncated;
    if (truncated) c.reason = "too-many-terms";
    for (size_t k = 0; k < result.externTerms.size() && derived; ++k) {
      const ExternTerm &t = result.externTerms[k];
      if (t.externIndex != i) continue;
      c.sites += 1;
      if (!externTermExprs[k]) {
        derived = false;
        c.reason = t.reason;
        break;
      }
      total = mkAdd(total, externTermExprs[k]);
      if (oversize(total)) {
        derived = false;
        c.reason = "expression-too-large";
      }
    }
    c.derived = derived;
    c.calls = derived ? render(total) : "";
    result.externCounts.push_back(std::move(c));
  }
  return result;
}

} // namespace

LoopBoundResult deriveLoopBounds(const ContractModule &module,
                                 const EligibilityReport &admitted,
                                 const EntryFacts &facts) {
  return Analysis(module, admitted, facts).run();
}

} // namespace spinel_mlir::core
