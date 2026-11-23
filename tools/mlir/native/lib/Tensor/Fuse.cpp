// Limited assign! fusion closed set; report first classified failure without guessing. Kernel
// identity is generated-text FNV-1a, matching frozen behavior, so construct canonical MLIR text
// directly rather than delegating spelling to the printer. Parse it afterward to check
// well-formedness.
#include "Fuse.h"

#include "Body.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Linalg/IR/Linalg.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/Parser/Parser.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdint>
#include <map>

using namespace mlir;

namespace spinel_mlir::tensor {
namespace {

// File-local AST accessors; do not include private Scalar/Freestanding/Declaration/Extern helpers.
const contract::AstField *findField(const contract::Node &n,
                                    llvm::StringRef key) {
  for (const contract::AstField &f : n.fields)
    if (f.key == key)
      return &f;
  return nullptr;
}
bool getReference(const contract::Node &n, llvm::StringRef k, int64_t &out) {
  const contract::AstField *f = findField(n, k);
  if (!f || f->kind != contract::AstField::Kind::Reference) return false;
  out = std::get<int64_t>(f->value);
  return true;
}
bool getString(const contract::Node &n, llvm::StringRef k, std::string &out) {
  const contract::AstField *f = findField(n, k);
  if (!f || f->kind != contract::AstField::Kind::String) return false;
  out = std::get<std::string>(f->value);
  return true;
}
bool getInteger(const contract::Node &n, llvm::StringRef k, int64_t &out) {
  const contract::AstField *f = findField(n, k);
  if (!f || f->kind != contract::AstField::Kind::Integer) return false;
  out = std::get<int64_t>(f->value);
  return true;
}
bool getArray(const contract::Node &n, llvm::StringRef k,
              std::vector<int64_t> &out) {
  const contract::AstField *f = findField(n, k);
  if (!f || f->kind != contract::AstField::Kind::Array) return false;
  out = std::get<std::vector<int64_t>>(f->value);
  return true;
}
bool getFloatSpelling(const contract::Node &n, llvm::StringRef k,
                      std::string &out) {
  const contract::AstField *f = findField(n, k);
  if (!f || f->kind != contract::AstField::Kind::FloatSpelling) return false;
  out = std::get<std::string>(f->value);
  return true;
}

constexpr llvm::StringLiteral kMalformed = "malformed-fuse-site";
constexpr llvm::StringLiteral kSignature = "unsupported-fuse-signature";
constexpr llvm::StringLiteral kBody = "unsupported-fuse-body";

uint64_t fnv1a64(llvm::StringRef s) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (unsigned char c : s) {
    h ^= c;
    h *= 0x100000001b3ULL;
  }
  return h;
}

// Tensor shape of a local; ambiguous means different constructors assigned the same name. Never
// guess one.
struct TensorCtor {
  int rank = 0;
  std::string dtype;
  bool ambiguous = false;
  // Track whether assignment used a known constructor. Nonconstructor calls such as Tensor.device
  // also enter the table as unknown, as frozen collect_tensor_ctors does with None. Refuse only if
  // used as a fusion tensor leaf, not here, preserving acceptance/cause parity.
  bool known = false;
};

// Slot kind for canonical ordering.
enum class Kind { Temp = 0, Scalar = 1, Elem = 2 };

struct Value {
  Kind kind;
  std::string ref; ///< `%t1` / `%s0` / `%a0_e` / `%d_e`
};

// One assign! site.
struct FuseSite {
  int64_t nodeId = -1;
  int64_t line = 0, col = 0;
  size_t start = 0, end = 0;      ///< Byte range to replace: [start,end).
  int rank = 0;
  llvm::SmallVector<std::string, 2> scalarSpelling; ///< Source spellings for s0... .
  llvm::SmallVector<std::string, 2> argNames;       ///< Local names for a0... .
  std::string destName;
  std::string kernel;             ///< Chosen kernel name.
  // Leaf node id to slot (%s0/%a0_e/%d_e). Literals/locals use the same lookup; name-based lookup
  // could confuse distinct leaves.
  std::map<int64_t, std::string> leafRef;
  std::map<int64_t, Kind> leafKind;
};

/// One distinct kernel.
struct FuseEntry {
  std::string name;
  std::string canonicalText; ///< Body retaining @__fx, used as hash input.
  std::string mlirText;      ///< Body with its name substituted.
  int rank = 0;
  unsigned nscalar = 0, ntensor = 0;
  uint64_t signatureHash = 0;
  std::string ranks, shape;
  int64_t line = 0;
  // All source lines folded into this entry. Dedup gives multiple sites; gen.rb joins them with
  // comma-space, so remembering only the first breaks deduplicated output.
  llvm::SmallVector<int64_t, 2> lines;
};

struct Builder {
  const contract::ContractModule &module;
  llvm::StringRef sourceName, sourceText;
  FuseDiagnosticFn diag;
  bool failed = false;

  int64_t sourceFileId = -1;
  llvm::DenseMap<int64_t, const contract::Node *> nodes;
  llvm::DenseMap<int64_t, const contract::NodeType *> types;
  llvm::StringMap<TensorCtor> constructors;
  llvm::SmallVector<FuseSite, 4> sites;
  std::vector<FuseEntry> entries; ///< Deduplicated appearance order.

  Builder(const contract::ContractModule &m, llvm::StringRef n,
          llvm::StringRef t, FuseDiagnosticFn d)
      : module(m), sourceName(n), sourceText(t), diag(d) {}

  const contract::Node *node(int64_t id) const {
    auto it = nodes.find(id);
    return it == nodes.end() ? nullptr : it->second;
  }
  // Parentheses are transparent; strip them so (a+b).relu stays within the subset.
  int64_t unwrap(int64_t id) const {
    for (int guard = 0; guard < 8; ++guard) {
      const contract::Node *n = node(id);
      if (!n || n->kind != "ParenthesesNode")
        return id;
      int64_t body = -1;
      if (!getReference(*n, "body", body) || body < 0)
        return id;
      const contract::Node *b = node(body);
      if (!b || b->kind != "StatementsNode")
        return id;
      std::vector<int64_t> stmts;
      if (!getArray(*b, "body", stmts) || stmts.size() != 1)
        return id;
      id = stmts[0];
    }
    return id;
  }

  const contract::NodeType *typeOf(int64_t id) const {
    auto it = types.find(id);
    return it == types.end() ? nullptr : it->second;
  }

  // Current fused-statement where prefix, fused statement at line N. Prefix every in-statement
  // refusal; empty for file-wide diagnostics.
  std::string curWhere;


  // Admitted method names checked in frozen order: three FUSE_NOT_HERE reasons, root op, then
  // FUSE_BINOPS. Shared by validateOps and emitExpr.
  bool checkOpName(llvm::StringRef name) {
// Preserve refusal order. FUSE_NOT_HERE means valid only inside tensor_def, with three distinct
// reasons, not generic non-tensor operations.
  {
    static const std::pair<const char *, const char *> kNotHere[] = {
        {"sum", "a reduction"}, {"max", "a reduction"}, {"min", "a reduction"},
        {"matvec", "a matrix-vector product"},
        {"conv2d", "a window op (a 2-D convolution)"},
        {"depthwise", "a window op (a per-channel 2-D convolution)"},
        {"mode_mul", "an n-mode product (a resample along one axis)"},
        {"tap_mul", "a banded resample along one axis"},
        {"bilinear", "a bilinear resample"}, {"hist", "a histogram"}};
    const char *blurb = nullptr;
    for (const auto &kv : kNotHere)
      if (name == kv.first) { blurb = kv.second; break; }
    if (blurb) {
      const bool resample = name == "mode_mul" || name == "tap_mul" ||
                            name == "bilinear" || name == "hist";
      const bool window = name == "conv2d" || name == "depthwise";
      if (resample)
        return reject(kBody,
                      "`" + name + "` is " + blurb +
                          ", which may only be written inside a tensor_def. It "
                          "reads elements at indices OTHER than the one being "
                          "written -- a resample reads a neighbourhood whose "
                          "position depends on the two shapes, a histogram reduces "
                          "over every pixel. Stage 3's licence to write into a "
                          "tensor the expression also reads (`y.assign!(x * 2.5 + "
                          "y)`) is precisely that every operand of an all-parallel "
                          "linalg.generic is read at the same index as the element "
                          "being written (E038 s4), and that is the property these "
                          "ops break. Unlike a window op the reason is NOT that the "
                          "coefficients are declared: `mode_mul` takes its "
                          "coefficients as a run-time :mat argument and `bilinear` "
                          "has none at all (E072 s2). It is the aliasing half alone, "
                          "and it is enough (P002 Phase 4, E072 s2)");
      if (window)
        return reject(kBody,
                      "`" + name + "` is " + blurb +
                          ", which may only be written inside a tensor_def. A window "
                          "op reads a NEIGHBOURHOOD of the input, not the element at "
                          "its own index. Stage 3's licence to write into a tensor "
                          "the expression also reads (`y.assign!(x * 2.5 + y)`) is "
                          "precisely that every operand of an all-parallel "
                          "linalg.generic is read at the same index as the element "
                          "being written (E038 s4); a convolution's indexing map is "
                          "`(d0 + d2, d1 + d3)` and two of its iterators are "
                          "reductions, which breaks both halves of that argument at "
                          "once. Window ops therefore live in a tensor_def, where the "
                          "destination is a declared parameter and the generator can "
                          "refuse the aliasing statically (P002 Phase 2, E042 s2)");
      return reject(kBody,
                    "`" + name + "` is " + blurb +
                        ", which may only be written inside a tensor_def -- "
                        "`tensor_def :s, params: [:vec], returns: :scalar` with `(x * "
                        "x).sum` as the body. Stage 3 fuses ELEMENT-WISE expressions "
                        "only: every operand of a `linalg.generic` whose iterators are "
                        "all `parallel` is read at the SAME index as the element being "
                        "written, which is what makes writing into a tensor the "
                        "expression also reads (`y.assign!(x * 2.5 + y)`) safe. `" +
                        name +
                        "` reads other indices, so it is a fusion boundary here and "
                        "its summation order is a declared contract there (R004 "
                        "decision record, E033 s1)");
    }
    if (name == "assign!" || name == "assign")
      return reject(kBody, "`" + name +
                               "` may only be the root of the statement, not a "
                               "sub-expression");
  }
    return true;
  }

  // Before leaf collection, validate every expression operator as frozen _leaves does before
  // constructor rank/dtype lookup. ** and conv2d must be named before unknown-rank errors.
  bool validateOps(int64_t id) {
    id = unwrap(id);
    const contract::Node *n = node(id);
    if (!n)
      return reject(kMalformed, "the fused expression has an unreadable node");
    if (n->kind == "FloatNode" || n->kind == "LocalVariableReadNode")
      return true;
    if (n->kind != "CallNode")
      return reject(kBody, nodeBlurb(n->kind) +
                               " is not in the fused subset. A fused statement is one "
                               "ELEMENT-WISE expression: `*` `+` `-` `/` / `relu` over "
                               "Tensors and Ruby numbers");
    std::string name;
    getString(*n, "name", name);
    if (!checkOpName(name))
      return false;
    int64_t recv = -1;
    if (getReference(*n, "receiver", recv) && recv >= 0)
      if (!validateOps(recv))
        return false;
    int64_t argsId = -1;
    std::vector<int64_t> args;
    if (getReference(*n, "arguments", argsId) && argsId >= 0)
      if (const contract::Node *an = node(argsId))
        if (getArray(*an, "arguments", args))
          for (int64_t a : args)
            if (!validateOps(a))
              return false;
    return true;
  }

  bool reject(llvm::StringRef category, const llvm::Twine &detail) {
    if (!failed) {
      failed = true;
      // Keep category internally for routing, not stderr; frozen output is one where:detail line
      // (2026-09-07 decision).
      diag(category, curWhere.empty() ? detail.str()
                                      : (curWhere + ": " + detail).str());
    }
    return false;
  }

  // Only nodes from the compiled file: shim AST shares the module and must not contribute sites.
  bool inSourceFile(const contract::Node &n) const {
    int64_t f = -1;
    return getInteger(n, "node_file", f) && f == sourceFileId;
  }

  bool resolveSourceFile();
  bool collectConstructors();
  bool collectSites();
  bool buildSite(const contract::Node &call);
  bool emitExpr(int64_t id, const FuseSite &site, unsigned &counter,
                std::string &body, Value &out);
  bool computeSpans();
  std::string renderTable() const;
  std::string renderDispatch() const;
  std::string renderRewrite() const;
};

// ---------------------------------------------------------------------------
// Collection
// ---------------------------------------------------------------------------
bool Builder::resolveSourceFile() {
  for (const contract::Node &n : module.nodes())
    nodes[n.id] = &n;
  for (const contract::NodeType &t : module.nodeTypes())
    types[t.id] = &t;
  unsigned hits = 0;
  for (const contract::Source &s : module.sources())
    if (llvm::StringRef(s.path) == module.sourceFile()) {
      sourceFileId = s.id;
      ++hits;
    }
  if (hits != 1)
    return reject(kMalformed,
                  "the sealed contract names the compiled file " +
                      llvm::Twine(hits) + " times among its sources");
  return true;
}

// Read rank/dtype from x = Tensor.of(:f32,n,xs).
bool Builder::collectConstructors() {
  for (const contract::Node &n : module.nodes()) {
    if (n.kind != "LocalVariableWriteNode" || !inSourceFile(n))
      continue;
    std::string name;
    int64_t valId = -1;
    if (!getString(n, "name", name) || !getReference(n, "value", valId) ||
        valId < 0)
      continue;
    const contract::Node *v = node(valId);
    if (!v || v->kind != "CallNode")
      continue;
    std::string method;
    int64_t recv = -1;
    if (!getString(*v, "name", method) || !getReference(*v, "receiver", recv) ||
        recv < 0)
      continue;
    const contract::Node *r = node(recv);
    std::string recvName;
    if (!r || r->kind != "ConstantReadNode" || !getString(*r, "name", recvName) ||
        recvName != "Tensor")
      continue;
    // Frozen constructors: vec/of rank 1, mat/of_mat 2, ten3 3, ten4 4.
    int rank = method == "vec" || method == "of"       ? 1
               : method == "mat" || method == "of_mat" ? 2
               : method == "ten3"                      ? 3
               : method == "ten4"                      ? 4
                                                       : 0;
    if (rank == 0) {
      // Nonconstructor Tensor.device etc. are unknown entries, not immediate refusals, matching
      // frozen behavior.
      constructors[name] = TensorCtor{0, "", false, false};
      continue;
    }
    // Leading dtype-symbol argument.
    int64_t argsId = -1;
    std::vector<int64_t> args;
    std::string dtype;
    if (getReference(*v, "arguments", argsId) && argsId >= 0)
      if (const contract::Node *an = node(argsId))
        if (getArray(*an, "arguments", args) && !args.empty())
          if (const contract::Node *d = node(args[0]))
            if (d->kind == "SymbolNode")
              getString(*d, "value", dtype);
    if (dtype.empty()) {
      // Unreadable dtype symbol yields (rank,None), as frozen behavior.
      constructors[name] = TensorCtor{0, "", false, false};
      continue;
    }
    auto it = constructors.find(name);
    if (it != constructors.end() &&
        (it->second.rank != rank || it->second.dtype != dtype || !it->second.known))
      it->second = TensorCtor{0, "", true, false};
    else
      constructors[name] = TensorCtor{rank, dtype, false, true};
  }
  return true;
}

// Lower expressions to canonical MLIR. The initial subset was Float/local/binary multiply/add and
// zero-argument relu.
bool Builder::emitExpr(int64_t id, const FuseSite &site, unsigned &counter,
                       std::string &body, Value &out) {
  id = unwrap(id);
  const contract::Node *n = node(id);
  if (!n)
    return reject(kMalformed, "the fused expression has an unreadable node");

  if (n->kind == "FloatNode" || n->kind == "LocalVariableReadNode") {
    auto it = site.leafRef.find(id);
    if (it == site.leafRef.end()) {
      std::string name;
      getString(*n, "name", name);
      return reject(kSignature,
                    "`" + (name.empty() ? std::string("a float literal") : name) +
                        "` is neither a declared Tensor nor a Float slot in the"
                        " fused expression");
    }
    out = Value{site.leafKind.at(id), it->second};
    return true;
  }

  if (n->kind != "CallNode")
    return reject(kBody, nodeBlurb(n->kind) +
                             " is not in the fused subset. A fused statement is one "
                             "ELEMENT-WISE expression: `*` `+` `-` `/` / `relu` over "
                             "Tensors and Ruby numbers");

  std::string name;
  getString(*n, "name", name);
  int64_t recv = -1;
  bool hasRecv = getReference(*n, "receiver", recv) && recv >= 0;
  int64_t argsId = -1;
  std::vector<int64_t> args;
  if (getReference(*n, "arguments", argsId) && argsId >= 0)
    if (const contract::Node *an = node(argsId))
      getArray(*an, "arguments", args);

  if (!hasRecv)
    return reject(kBody, "`" + name + "` has no receiver in the fused expression");

  if (name == "relu") {
    if (!args.empty())
      return reject(kBody, "`relu` takes no argument in the CP3 subset");
    Value v;
    if (!emitExpr(recv, site, counter, body, v))
      return false;
    unsigned z = counter++;
    unsigned t = counter++;
    body += ("    %z" + llvm::Twine(z) + " = arith.constant 0.000000e+00 : f32\n")
                .str();
    // Do not add fastmath to maximumf.
    body += ("    %t" + llvm::Twine(t) + " = arith.maximumf " + v.ref + ", %z" +
             llvm::Twine(z) + " : f32\n")
                .str();
    out = Value{Kind::Temp, ("%t" + llvm::Twine(t)).str()};
    return true;
  }

  if (!checkOpName(name))
    return false;

  // Frozen FUSE_BINOPS has multiply/add/subtract/divide.
  llvm::StringRef op = name == "*"   ? "arith.mulf"
                       : name == "+" ? "arith.addf"
                       : name == "-" ? "arith.subf"
                       : name == "/" ? "arith.divf"
                                     : "";
  if (op.empty())
    return reject(kBody, "method `" + name +
                             "` is not a tensor op. The fused subset is `*`, `+`, "
                             "`-`, `/` plus `relu`, rooted at `dest.assign!(expr)`");
  if (args.size() != 1)
    return reject(kBody, "`" + name + "` takes exactly one operand");
  Value l, r;
  if (!emitExpr(recv, site, counter, body, l))
    return false;
  if (!emitExpr(args[0], site, counter, body, r))
    return false;
  // Canonicalize only commutative multiply/add when RHS is captured scalar and LHS is not: move
  // capture left. This is not a total order of temp/scalar/element; that approximation matched
  // elements accidentally but failed for temps. One s*(t) kernel changed fx1_76b0ea4e95cf to
  // fx1_46d56b557c7f: one operand order changes text hash/name. Never swap subtraction/division.
  if ((name == "*" || name == "+") && r.kind == Kind::Scalar &&
      l.kind != Kind::Scalar)
    std::swap(l, r);
  unsigned t = counter++;
  body += ("    %t" + llvm::Twine(t) + " = " + op + " " + l.ref + ", " + r.ref +
           " fastmath<contract> : f32\n")
              .str();
  out = Value{Kind::Temp, ("%t" + llvm::Twine(t)).str()};
  return true;
}

// Build sites by appearance-order leaves, assigning slots and canonical text.
namespace {
// Collect leaves in expression appearance order; callers refuse unsupported kinds.
bool walkLeaves(Builder &b, int64_t id,
                llvm::SmallVectorImpl<int64_t> &leaves) {
  id = b.unwrap(id);
  const contract::Node *n = b.node(id);
  if (!n)
    return false;
  if (n->kind == "FloatNode" || n->kind == "LocalVariableReadNode") {
    leaves.push_back(id);
    return true;
  }
  if (n->kind != "CallNode")
    return true; // emitExpr reports the classification.
  int64_t recv = -1;
  if (getReference(*n, "receiver", recv) && recv >= 0)
    if (!walkLeaves(b, recv, leaves))
      return false;
  int64_t argsId = -1;
  std::vector<int64_t> args;
  if (getReference(*n, "arguments", argsId) && argsId >= 0)
    if (const contract::Node *an = b.node(argsId))
      if (getArray(*an, "arguments", args))
        for (int64_t a : args)
          if (!walkLeaves(b, a, leaves))
            return false;
  return true;
}
} // namespace

bool Builder::buildSite(const contract::Node &call) {
  FuseSite site;
  site.nodeId = call.id;
  getInteger(call, "node_line", site.line);
  curWhere = ("fused statement at line " + llvm::Twine(site.line)).str();
  getInteger(call, "node_col", site.col);

  int64_t recv = -1;
  if (!getReference(call, "receiver", recv) || recv < 0)
    return reject(kMalformed, "`assign!` has no receiver");
  const contract::Node *r = node(recv);
  if (!r || r->kind != "LocalVariableReadNode" ||
      !getString(*r, "name", site.destName))
    return reject(kMalformed, "the `assign!` receiver is not a plain local");

  int64_t argsId = -1;
  std::vector<int64_t> args;
  if (!getReference(call, "arguments", argsId) || argsId < 0 ||
      !getArray(*node(argsId), "arguments", args) || args.size() != 1)
    return reject(kMalformed, "`assign!` takes exactly 1 argument");

  // Validate all operators before constructor sites, or **/conv2d get unknown-rank instead of the
  // frozen operator-named refusal.
  if (!validateOps(args[0]))
    return false;

  auto ctor = constructors.find(site.destName);
  // Frozen wording distinguishes not constructed in this file from assigned another kind or
  // multiple constructors.
  if (ctor == constructors.end() || !ctor->second.known)
    return reject(kSignature,
                  "cannot tell the rank of `" + site.destName +
                      "`. A fused statement gets the rank and dtype of its "
                      "tensors from their CONSTRUCTION SITE (`Tensor.vec(:f32, "
                      "n)` / `Tensor.mat(:f32, r, c)` / `Tensor.of` / "
                      "`Tensor.of_mat`) in the same file, because spinel's "
                      "inference has neither shape nor f32 (R001 s1.3). `" +
                      site.destName + "` is " +
                      (ctor == constructors.end()
                           ? "never constructed in this file"
                           : "written from something else, or from two "
                             "different constructors"));
  // No rank restriction here: rank 3/4 fusion was added later. Check dtype, including destination,
  // together below.
  site.rank = ctor->second.rank;

  // Map name to dtype/rank with destination first then appearance order (names=[dest]+torder).
  // Collect all before one decision.
  std::vector<std::string> order{site.destName};
  std::map<std::string, std::string> badDtype;
  std::map<std::string, int> leafRank;
  badDtype[site.destName] = ctor->second.dtype;
  leafRank[site.destName] = ctor->second.rank;

  // Assign leaf slots in appearance order: scalars s0..., nondestination tensors a0..., destination
  // d.
  llvm::SmallVector<int64_t, 8> leaves;
  walkLeaves(*this, args[0], leaves);
  for (int64_t id : leaves) {
    const contract::Node *n = node(id);
    if (n->kind == "FloatNode") {
      std::string spelling;
      if (!getFloatSpelling(*n, "value", spelling))
        return reject(kMalformed, "a float literal has no spelling");
      site.leafRef[id] = ("%s" + llvm::Twine(site.scalarSpelling.size())).str();
      site.leafKind[id] = Kind::Scalar;
      site.scalarSpelling.push_back(spelling);
      continue;
    }
    std::string name;
    getString(*n, "name", name);
    if (name == site.destName) {
      site.leafRef[id] = "%d_e";
      site.leafKind[id] = Kind::Elem;
      continue;
    }
    auto c = constructors.find(name);
    if (c != constructors.end()) {
      if (c->second.ambiguous)
        return reject(kSignature, "`" + name +
                                      "` is written by more than one Tensor.*"
                                      " constructor");
      // Collect all tensors before rank/dtype refusal, matching frozen destination-plus-operands
      // diagnostic.
      if (!badDtype.count(name)) order.push_back(name);
      badDtype[name] = c->second.dtype;
      leafRank[name] = c->second.rank;
      // Repeated local uses share a slot.
      bool seen = false;
      for (auto [i, a] : llvm::enumerate(site.argNames))
        if (a == name) {
          site.leafRef[id] = ("%a" + llvm::Twine(i) + "_e").str();
          seen = true;
          break;
        }
      if (!seen) {
        site.leafRef[id] = ("%a" + llvm::Twine(site.argNames.size()) + "_e").str();
        site.argNames.push_back(name);
      }
      site.leafKind[id] = Kind::Elem;
      continue;
    }
    // Nontensor locals must be scalar Float values.
    const contract::NodeType *t = typeOf(id);
    if (!t || t->type != "float")
      return reject(kSignature, "`" + name + "` is neither a declared Tensor"
                                             " nor a Float");
    bool seen = false;
    for (auto [i, sp] : llvm::enumerate(site.scalarSpelling))
      if (sp == name) {
        site.leafRef[id] = ("%s" + llvm::Twine(i)).str();
        seen = true;
        break;
      }
    if (!seen) {
      site.leafRef[id] = ("%s" + llvm::Twine(site.scalarSpelling.size())).str();
      site.scalarSpelling.push_back(name);
    }
    site.leafKind[id] = Kind::Scalar;
  }

  // Check rank/dtype after collecting all tensors, destination first then appearance order.
  // Per-tensor refusals would hide which tensors disagree.
  {
    std::set<int> ranks;
    for (const std::string &n : order) ranks.insert(leafRank[n]);
    if (ranks.size() != 1) {
      std::string rs, list;
      for (int r : ranks) { if (!rs.empty()) rs += "/"; rs += std::to_string(r); }
      for (const std::string &n : order) {
        if (!list.empty()) list += ", ";
        list += n + ":rank" + std::to_string(leafRank[n]);
      }
      return reject(kSignature,
                    "mixes rank-" + rs +
                        " tensors in one element-wise expression (" + list +
                        "). Every operand of a fused statement is read at the same "
                        "index, so they must all have the same rank and shape");
    }
    std::string bad;
    for (const std::string &n : order)
      if (badDtype[n] != "f32") {
        if (!bad.empty()) bad += ", ";
        bad += "`" + n + "`";
      }
    if (!bad.empty())
      return reject(kSignature,
                    bad + " constructed with a dtype other than :f32. A kernel this "
                          "tool writes is arith on f32 throughout; a foreign element "
                          "type is what tensor_extern is for (E037 s6)");
  }

  // ---- canonical text -----------------------------------------------------
  std::string body;
  unsigned counter = 1;
  Value result;
  if (!emitExpr(args[0], site, counter, body, result))
    return false;
  unsigned rid = counter++;

  // Ranks 1..4, including the later rank-3/4 fusion extension.
  std::string tyS = "tensor<";
  for (int i = 0; i < site.rank; ++i) tyS += "?x";
  tyS += "f32>";
  llvm::StringRef ty = tyS;
  // One indexing map per operand: all ins plus one outs. A hardcoded two worked only for one-source
  // fixtures; a second source exposed verifier operand/map count mismatch.
  std::string dimsS;
  for (int i = 0; i < site.rank; ++i) {
    if (i) dimsS += ", ";
    dimsS += "d" + std::to_string(i);
  }
  // Only rank 1 uses module #map alias, preserving the alias-string checks and text-derived kernel
  // names.
  const std::string oneS =
      site.rank == 1 ? "#map"
                     : ("affine_map<(" + dimsS + ") -> (" + dimsS + ")>");
  const llvm::StringRef one = oneS;
  std::string maps = "[";
  for (unsigned i = 0; i < site.argNames.size() + 1; ++i) {
    if (i) maps += ", ";
    maps += one;
  }
  maps += "]";
  std::string itersS = "[";
  for (int i = 0; i < site.rank; ++i) itersS += i ? ", \"parallel\"" : "\"parallel\"";
  itersS += "]";
  llvm::StringRef iters = itersS;

  std::string sig;
  for (unsigned i = 0; i < site.scalarSpelling.size(); ++i)
    sig += ("%s" + llvm::Twine(i) + ": f32, ").str();
  // ins syntax lists all values before all types: ins(%a0,%a1:T,T). Per-value typing accidentally
  // worked for one operand; the second produced expected non-function type.
  std::string insVals, insTys, elems;
  for (unsigned i = 0; i < site.argNames.size(); ++i) {
    sig += ("%a" + llvm::Twine(i) + ": " + ty + ", ").str();
    if (i) { insVals += ", "; insTys += ", "; }
    insVals += ("%a" + llvm::Twine(i)).str();
    insTys += ty;
    elems += ("%a" + llvm::Twine(i) + "_e: f32, ").str();
  }
  const std::string ins = insVals + " : " + insTys;
  sig += ("%d: " + llvm::Twine(ty)).str();
  elems += "%d_e: f32";

  std::string text;
  text += ("func.func @__fx(" + sig + ") -> " + ty + " {\n").str();
  text += ("  %r" + llvm::Twine(rid) + " = linalg.generic {\n").str();
  text += "         indexing_maps = " + maps + ",\n";
  text += ("         iterator_types = " + iters + "\n").str();
  text += "       }\n";
  text += "       ins(" + ins + ")\n";
  text += ("       outs(%d : " + llvm::Twine(ty) + ") {\n").str();
  text += "  ^bb0(" + elems + "):\n";
  text += body;
  text += "    linalg.yield " + result.ref + " : f32\n";
  text += ("  } -> " + llvm::Twine(ty) + "\n").str();
  text += ("  return %r" + llvm::Twine(rid) + " : " + ty + "\n").str();
  text += "}";

  // Identity and deduplication.
  std::string name = ("fx" + llvm::Twine(site.rank) + "_").str();
  {
    char hex[16];
    snprintf(hex, sizeof(hex), "%012llx",
             static_cast<unsigned long long>(fnv1a64(text) & 0xFFFFFFFFFFFFULL));
    name += hex;
  }
  site.kernel = name;
  FuseEntry *prev = nullptr;
  for (FuseEntry &e : entries)
    if (e.name == name)
      prev = &e;
  if (prev) {
    // Same name with different body is a hash collision; never guess that sharing is safe.
    if (prev->canonicalText != text)
      return reject(kMalformed, "kernel-name hash collision on " + name);
    // Retain every deduplicated site line for comma-space gen.rb notes, not just the first.
    prev->lines.push_back(site.line);
  } else {
    FuseEntry e;
    e.name = name;
    e.canonicalText = text;
    e.mlirText = text;
    e.mlirText.replace(e.mlirText.find("@__fx("), strlen("@__fx("),
                       "@" + name + "(");
    e.rank = site.rank;
    e.nscalar = site.scalarSpelling.size();
    e.ntensor = site.argNames.size() + 1;
    e.line = site.line;
    e.lines.push_back(site.line);
    e.ranks = std::string(e.ntensor, static_cast<char>('0' + site.rank));
    // Shape constraints connect anchor a0 to every other tensor along every dimension. Assuming two
    // tensors missed 0:0=2:0 for a three-tensor kernel and changed its signature hash.
    {
      std::string shape;
      for (unsigned t = 1; t < e.ntensor; ++t)
        for (int dim = 0; dim < site.rank; ++dim) {
          if (!shape.empty()) shape += ";";
          shape += "0:" + std::to_string(dim) + "=" + std::to_string(t) + ":" +
                   std::to_string(dim);
        }
      e.shape = shape;
    }
    std::string params;
    for (unsigned i = 0; i < e.nscalar; ++i)
      params += "scalar,";
    static const char *kRankSpelling[] = {"scalar", "vec", "mat", "ten3", "ten4"};
    for (unsigned i = 0; i < e.ntensor; ++i)
      params += std::string(kRankSpelling[site.rank]) + ",";
    params.pop_back();
    std::string sigInput = (name + "|" + params + "|dest=" +
                            llvm::Twine(e.ntensor - 1) + "|ret=0|shape=" + e.shape)
                               .str();
    e.signatureHash = fnv1a64(sigInput) & 0x7fffffffffffffffULL;
    entries.push_back(e);
  }
  sites.push_back(site);
  return true;
}

bool Builder::collectSites() {
  llvm::SmallVector<const contract::Node *, 4> roots;
  for (const contract::Node &n : module.nodes()) {
    if (n.kind != "CallNode" || !inSourceFile(n))
      continue;
    std::string name;
    if (getString(n, "name", name) && name == "assign!")
      roots.push_back(&n);
  }
  llvm::sort(roots, [](const contract::Node *a, const contract::Node *b) {
    int64_t al = 0, bl = 0, ac = 0, bc = 0;
    getInteger(*a, "node_line", al);
    getInteger(*b, "node_line", bl);
    getInteger(*a, "node_col", ac);
    getInteger(*b, "node_col", bc);
    return al != bl ? al < bl : ac < bc;
  });
  if (roots.empty())
    return reject(kMalformed, "the program has no `assign!` statement to fuse");
  for (const contract::Node *r : roots)
    if (!buildSite(*r))
      return false;
  return true;
}

// Rewrite spans/rendering: convert one-based line/column to byte offsets.
static bool offsetOf(llvm::StringRef text, int64_t line, int64_t col,
                     size_t &out) {
  size_t pos = 0;
  for (int64_t l = 1; l < line; ++l) {
    size_t nl = text.find('\n', pos);
    if (nl == llvm::StringRef::npos)
      return false;
    pos = nl + 1;
  }
  if (pos + col > text.size())
    return false;
  out = pos + static_cast<size_t>(col);
  return true;
}

bool Builder::computeSpans() {
  for (FuseSite &s : sites) {
    if (!offsetOf(sourceText, s.line, s.col, s.start))
      return reject(kMalformed, "the `assign!` site is outside the source text");
    // Find assign! opening parenthesis and follow depth to zero. The admitted expressions exclude
    // strings/comments/character literals, so simple depth is sufficient.
    size_t open = sourceText.find('(', s.start);
    if (open == llvm::StringRef::npos)
      return reject(kMalformed, "the `assign!` site has no argument list");
    int depth = 0;
    size_t i = open;
    for (; i < sourceText.size(); ++i) {
      if (sourceText[i] == '(')
        ++depth;
      else if (sourceText[i] == ')') {
        if (--depth == 0)
          break;
      }
    }
    if (depth != 0)
      return reject(kMalformed, "the `assign!` argument list is unbalanced");
    s.end = i + 1;
  }
  return true;
}

std::string Builder::renderRewrite() const {
  std::string out;
  out += ("# Rewritten by tools/mlir/spinel-mlirgen --tensor --fuse from " +
          llvm::Twine(sourceName) + "\n")
             .str();
  out += ("# -- do not edit.  " + llvm::Twine(sites.size()) +
          " fused statement(s) became " + llvm::Twine(entries.size()) +
          " kernel(s); every\n")
             .str();
  out += "# other byte is the original file's.\n";
  // Replace sites backward to preserve earlier byte offsets.
  std::string body = sourceText.str();
  for (auto it = sites.rbegin(); it != sites.rend(); ++it) {
    std::string call = it->kernel + "(";
    bool first = true;
    for (const std::string &s : it->scalarSpelling) {
      if (!first) call += ", ";
      first = false;
      call += s;
    }
    for (const std::string &a : it->argNames) {
      if (!first) call += ", ";
      first = false;
      call += a;
    }
    if (!first) call += ", ";
    call += it->destName + ")";
    body.replace(it->start, it->end - it->start, call);
  }
  return out + body;
}

std::string Builder::renderTable() const {
  std::string out;
  out += ("/* Generated by tools/mlir/spinel-mlirgen --tensor from " +
          llvm::Twine(sourceName) + " -- do not edit. */\n")
             .str();
  out += "#ifndef SP_TENSOR_TABLE_H_\n#define SP_TENSOR_TABLE_H_\n\n";
  out += "typedef struct {\n"
         "  const char *name;\n  const char *fq;\n  int nscalar;\n"
         "  int ntensor;\n  int nin;\n  int dest;\n  int ret_scalar;\n"
         "  const char *ranks;\n  const char *dtypes;\n  const char *shape;\n"
         "  long long sig;\n} sp_t_entry_t;\n\n";
  out += "static const sp_t_entry_t SP_T_TABLE[] = {\n";
  for (const FuseEntry &e : entries)
    out += ("  {\"" + e.name + "\", \"module." + e.name + "\", " +
            llvm::Twine(e.nscalar) + ", " + llvm::Twine(e.ntensor) + ", " +
            llvm::Twine(e.ntensor) + ", " + llvm::Twine(e.ntensor - 1) +
            ", 0, \"" + e.ranks + "\", \"" + std::string(e.ntensor, '0') +
            "\", \"" + e.shape + "\", " + llvm::Twine(e.signatureHash) + "LL},\n")
               .str();
  out += ("};\n#define SP_T_TABLE_N " + llvm::Twine(entries.size()) +
          "\n\n#endif\n")
             .str();
  return out;
}

// Return body only. Emit::generatedRuby writes the same twelve-line frozen header for fuse-only and
// tensor_def sources.
std::string Builder::renderDispatch() const {
  std::string out;
  bool first = true;
  for (const FuseEntry &e : entries) {
    // Frozen output has one blank line between defs, none before the first; single-kernel files hid
    // this difference.
    if (!first) out += "\n";
    first = false;
    std::string params;
    for (unsigned i = 0; i < e.nscalar; ++i)
      params += ("s" + llvm::Twine(i) + ", ").str();
    for (unsigned i = 0; i + 1 < e.ntensor; ++i)
      params += ("a" + llvm::Twine(i) + ", ").str();
    params += "d";
    {
      std::string where;
      for (int64_t ln : e.lines) {
        if (!where.empty()) where += ", ";
        where += ("fused statement at line " + llvm::Twine(ln)).str();
      }
      out += "# fused: " + where + "\n";
    }
    out += "def " + e.name + "(" + params + ")\n";
    // Existing ABI zero-fills four scalar and four handle slots.
    std::string sslots;
    for (unsigned i = 0; i < 4; ++i)
      sslots += i < e.nscalar ? ("s" + llvm::Twine(i) + ", ").str()
                              : std::string("0.0, ");
    std::string hslots;
    for (unsigned i = 0; i + 1 < e.ntensor; ++i)
      hslots += ("a" + llvm::Twine(i) + ".handle, ").str();
    hslots += "d.handle, ";
    for (unsigned i = e.ntensor; i < 4; ++i)
      hslots += "0, ";
    out += ("  rc = SPT.sp_t_invoke_fx(\"" + e.name + "\", " +
            llvm::Twine(e.signatureHash) + ", " + sslots + hslots +
            "d.length)\n")
               .str();
    out += "  if rc != 0\n";
    out += "    raise TensorError, \"" + e.name +
            ": #{SPT.sp_t_last_error}\"\n";
    out += "  end\n  d\nend\n";
  }
  return out;
}

} // namespace

std::optional<FuseArtifacts>
compileFuse(const contract::ContractModule &module, llvm::StringRef sourceName,
               llvm::StringRef sourceText, MLIRContext &context,
               FuseDiagnosticFn diag) {
  Builder b(module, sourceName, sourceText, diag);
  if (!b.resolveSourceFile() || !b.collectConstructors() || !b.collectSites() ||
      !b.computeSpans())
    return std::nullopt;

  // Construct text; header defines #map used by rank-1 kernels.
  std::string text =
      "// Generated by tools/mlir/spinel-mlirgen --tensor from " +
      sourceName.str() + " -- do not edit.\n\n#map = affine_map<(d0) -> (d0)>\n";
  // Entries sort by kernel-name spelling, not occurrence: frozen fused_entries iterates sorted keys
  // of its name dictionary. Names are text FNV-1a, so ordering depends on kernels, not source-site
  // order.
  llvm::sort(b.entries, [](const FuseEntry &x, const FuseEntry &y) {
    return x.name < y.name;
  });
  for (const FuseEntry &e : b.entries)
    text += "\n" + e.mlirText + "\n";

  context.loadDialect<func::FuncDialect, linalg::LinalgDialect,
                      arith::ArithDialect>();
  auto parsed = parseSourceString<ModuleOp>(text, &context);
  if (!parsed) {
    diag(kMalformed, "the generated MLIR does not parse");
    return std::nullopt;
  }

  FuseArtifacts art;
  art.module = std::move(parsed);
  art.mlirText = std::move(text);
  art.rewrittenSource = b.renderRewrite();
  art.tableHeader = b.renderTable();
  art.rubyDispatch = b.renderDispatch();
  art.sites = b.sites.size();
  art.kernels = b.entries.size();
  for (const FuseEntry &e : b.entries) {
    art.entryNames.push_back(e.name);
    art.tableRows.push_back({e.name, e.nscalar, e.ranks, e.shape, e.signatureHash});
  }
  return art;
}

} // namespace spinel_mlir::tensor
