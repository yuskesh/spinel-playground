// Tensor def/body structure, preserving frozen wording and check order.
#include "Body.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/raw_ostream.h"

#include <functional>
#include <map>

namespace spinel_mlir::tensor {
namespace {

const contract::AstField *findField(const contract::Node &n, llvm::StringRef key) {
  for (const contract::AstField &f : n.fields)
    if (f.key == key)
      return &f;
  return nullptr;
}
bool getReference(const contract::Node &n, llvm::StringRef key, int64_t &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Reference) return false;
  out = std::get<int64_t>(f->value);
  return true;
}
bool getString(const contract::Node &n, llvm::StringRef key, std::string &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::String) return false;
  out = std::get<std::string>(f->value);
  return true;
}
bool getArray(const contract::Node &n, llvm::StringRef key,
              std::vector<int64_t> &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Array) return false;
  out = std::get<std::vector<int64_t>>(f->value);
  return true;
}

// Frozen NODE_BLURB verbatim.
const std::map<std::string, std::string> &blurbTable() {
  static const std::map<std::string, std::string> t = {
    {"WhileNode", "a `while` loop"},
    {"UntilNode", "an `until` loop"},
    {"ForNode", "a `for` loop"},
    {"IfNode", "an `if` (data-dependent control flow)"},
    {"UnlessNode", "an `unless`"},
    {"CaseNode", "a `case`"},
    {"DefNode", "a nested `def`"},
    {"BlockNode", "a block"},
    {"ClassNode", "a `class` definition"},
    {"ModuleNode", "a `module` definition"},
    {"IndexNode", "an index expression (`t[i]`)"},
    {"IntegerNode", "an Integer literal (the tensor subset is f32-only)"},
    {"StringNode", "a String literal"},
    {"ArrayNode", "an Array literal"},
    {"HashNode", "a Hash literal"},
    {"SymbolNode", "a Symbol literal"},
    {"RangeNode", "a Range"},
    {"LocalVariableWriteNode", "an intermediate local variable (that is a fusion boundary -- R004 stage 2)"},
    {"LocalVariableOperatorWriteNode", "an operator-assignment (`+=` desugars to `a = a + b`; use `dest.assign(...)`)"},
    {"InstanceVariableReadNode", "an instance variable"},
    {"ConstantReadNode", "a constant"},
    {"ReturnNode", "an explicit `return`"},
    {"YieldNode", "a `yield`"},
    {"SelfNode", "`self`"},
    {"NilNode", "`nil`"},
    {"TrueNode", "`true`"},
    {"FalseNode", "`false`"},
    {"CallNode", "a method call"},
    {"LocalVariableReadNode", "a local variable read"},  };
  return t;
}

// Operator enumeration in sorted order, matching TENSOR_BINOPS/TENSOR_UNOPS and TENSOR_PROLOGUE_OPS
// minus TENSOR_TENSOR_OPS.
constexpr llvm::StringLiteral kBinops = "`*` `**` `+` `-` `/`";
constexpr llvm::StringLiteral kUnops = "`abs` `relu` `sqrt`";
constexpr llvm::StringLiteral kPrologue =
    "`bilinear` `conv2d` `depthwise` `hist` `mode_mul` `tap_mul`";
/// TENSOR_ROOTS = {"assign"} | TENSOR_REDUCERS.
const std::vector<std::string> kRoots = {"assign", "max", "min", "sum"};
// Closed operator set; always sort diagnostic spellings.
const std::vector<std::string> kBinopsSet = {"*", "**", "+", "-", "/"};
const std::vector<std::string> kUnopsSet = {"abs", "relu", "sqrt"};
const std::vector<std::string> kCmpopsSet = {"ge"};
// Prologue operations. Initial traversal checked only names and marked unavailable native forms
// pending without scanning inside. Window operations were added at the next checkpoint.
const std::vector<std::string> kWindowOps = {"conv2d", "depthwise"};
// Additional prologue family: identify by name without inspecting contents.
const std::vector<std::string> kPrologueOps = {"mode_mul", "tap_mul", "bilinear", "hist"};
// Sorted TENSOR_WINDOW_OPS for _check_window_kw diagnostics.
constexpr llvm::StringLiteral kWindowOpList = "conv2d` / `depthwise";
const std::string kBinopsList = "`*`, `**`, `+`, `-`, `/`";
const std::string kUnopsList = "`abs`, `relu`, `sqrt`";
const std::string kCmpopsList = "`ge`";
const std::string kPrologueList =
    "`bilinear`, `conv2d`, `depthwise`, `hist`, `mode_mul`, `tap_mul`";

// Check forbidden def parameter forms in frozen order.
const std::vector<std::string> kBadParamFaces = {
    "optionals", "keywords", "posts", "rest", "block", "keyword_rest"};

} // namespace

std::string nodeBlurb(llvm::StringRef kind) {
  auto it = blurbTable().find(kind.str());
  if (it != blurbTable().end())
    return it->second;
  return (llvm::Twine("a ") + kind).str();
}

std::map<std::string, int64_t> topLevelDefs(const contract::ContractModule &m) {
  std::map<std::string, int64_t> out;
  auto node = [&](int64_t id) -> const contract::Node * {
    for (const contract::Node &n : m.nodes())
      if (n.id == id) return &n;
    return nullptr;
  };
  const contract::Node *root = node(m.root());
  if (!root) return out;
  int64_t stmtsId = -1;
  if (!getReference(*root, "statements", stmtsId) || stmtsId < 0) return out;
  const contract::Node *stmts = node(stmtsId);
  if (!stmts) return out;
  std::vector<int64_t> body;
  getArray(*stmts, "body", body);
  for (int64_t id : body) {
    const contract::Node *n = node(id);
    std::string name;
    if (n && n->kind == "DefNode" && getString(*n, "name", name))
      out.emplace(name, n->id);
  }
  return out;
}

std::optional<TensorBody>
readTensorBody(const contract::ContractModule &m, const TensorDecl &decl,
               int64_t defNode, DeclDiagnosticFn diag) {
  auto node = [&](int64_t id) -> const contract::Node * {
    if (id < 0) return nullptr;
    for (const contract::Node &n : m.nodes())
      if (n.id == id) return &n;
    return nullptr;
  };
  const std::string whereStr = decl.where();
  const llvm::StringRef where = whereStr;
  bool failed = false;
  auto fail = [&](const llvm::Twine &d) {
    if (!failed) { failed = true; diag(d.str()); }
    return std::nullopt;
  };

  const contract::Node *def = node(defNode);
  if (!def)
    return fail(where + ": no top-level `def " + decl.name +
                "` to go with the declaration");

  // ---- `_read_params` -----------------------------------------------------
  TensorBody b;
  int64_t paramsId = -1;
  getReference(*def, "parameters", paramsId);
  const contract::Node *params = node(paramsId);
  if (params) {
    // Refuse any non-required-positional parameter form. Frozen AST wrapper uses @@field for arrays
    // and @field for references, but contract names are bare rest/optionals/etc. Prefixing @ would
    // never match and wrongly admit def k(a,x,y,*rest), caught by rest_param.
    for (const std::string &face : kBadParamFaces) {
      std::vector<int64_t> arr;
      int64_t ref = -1;
      const bool hasArr = getArray(*params, face, arr) && !arr.empty();
      const bool hasRef = getReference(*params, face, ref) && ref >= 0;
      if (hasArr || hasRef)
        return fail(where + ": '" + face +
                    "' parameters are not in the tensor subset (only required "
                    "positional ones)");
    }
    std::vector<int64_t> req;
    getArray(*params, "requireds", req);
    for (int64_t id : req) {
      const contract::Node *p = node(id);
      if (!p || p->kind != "RequiredParameterNode")
        return fail(where + ": parameter kind " +
                    (p ? llvm::StringRef(p->kind) : llvm::StringRef("nothing")) +
                    " is not in the tensor subset");
      std::string nm;
      getString(*p, "name", nm);
      b.paramNames.push_back(nm);
    }
  }
  for (size_t i = 0; i < b.paramNames.size() && i < decl.params.size(); ++i)
    b.rank[b.paramNames[i]] = rankOf(decl.params[i]);
  b.ewRank = decl.dest >= 0 && decl.dest < static_cast<int64_t>(decl.params.size())
                 ? rankOf(decl.params[decl.dest])
                 : 1;
  if (b.paramNames.size() != decl.params.size()) {
    std::string declared;
    for (const std::string &p : decl.params) {
      if (!declared.empty()) declared += ", ";
      declared += ":" + p;
    }
    std::string got;
    for (const std::string &n : b.paramNames) {
      if (!got.empty()) got += ", ";
      got += n;
    }
    if (got.empty()) got = "none";
    return fail(where + ": declares " + llvm::Twine(decl.params.size()) +
                " parameter(s) [" + declared + "] but `def " + decl.name +
                "` takes " + llvm::Twine(b.paramNames.size()) + " (" + got + ")");
  }

  // Structural build checks.
  int64_t bodyId = -1;
  getReference(*def, "body", bodyId);
  std::vector<int64_t> stmts;
  if (const contract::Node *bn = node(bodyId))
    getArray(*bn, "body", stmts);
  if (stmts.size() != 1) {
    std::string what;
    for (int64_t id : stmts) {
      const contract::Node *t = node(id);
      if (!what.empty()) what += ", ";
      what += nodeBlurb(t ? llvm::StringRef(t->kind) : llvm::StringRef("nothing"));
    }
    return fail(where + ": a tensor_def body must be exactly one expression (found " +
                llvm::Twine(stmts.size()) + " statements: " + what +
                "). An intermediate statement is a fusion boundary -- R004 stage 2.");
  }
  const contract::Node *root = node(stmts[0]);
  auto rejectNode = [&](const contract::Node *n, llvm::StringRef extra) {
    return fail(where + ": " +
                nodeBlurb(n ? llvm::StringRef(n->kind) : llvm::StringRef("nothing")) +
                " is not in the tensor subset" + extra +
                ". A tensor_def body is one tensor expression: " + kBinops + " / " +
                kUnops + " / `matvec` / " + kPrologue +
                " over :mat/:vec/:ten3/:ten4/:scalar parameters, rooted at "
                "`dest.assign(expr)` or `expr.sum` / `.max` / `.min`.");
  };
  if (!root || root->kind != "CallNode")
    return rejectNode(root, " as the body root");
  std::string rootName;
  getString(*root, "name", rootName);
  if (!llvm::is_contained(kRoots, rootName))
    return fail(where + ": the body root is `" + rootName +
                "`; a tensor_def body must be rooted at `dest.assign(expr)` "
                "(destination-passing) or `expr.sum` / `expr.max` / `expr.min` "
                "(reduction)");
  b.root = rootName;
  b.rootNode = root->id;
  // Before generating a reduction, require returns:scalar, matching _build_reduce. Otherwise func
  // result and linalg output conflict and the verifier, rather than a source diagnostic, rejects
  // the f32 return type.
  if (rootName != "assign" && decl.returns != "scalar")
    return fail(where + ": the body reduces with `." + rootName +
                "` but the declaration has no returns: :scalar");

  // Scan expression sources in first-appearance order, matching _scan. This is also the first
  // structural gate for unnamed node kinds. Initial prologue families such as conv2d were marked
  // pending by name without scanning contents.
  std::function<bool(int64_t)> scan;
  auto unwrap = [&](int64_t id) -> const contract::Node * {
    const contract::Node *n = node(id);
    while (n && (n->kind == "ParenthesesNode" || n->kind == "StatementsNode")) {
      std::vector<int64_t> inner;
      if (n->kind == "StatementsNode") {
        getArray(*n, "body", inner);
      } else {
        int64_t b = -1;
        if (getReference(*n, "body", b) && b >= 0) inner.push_back(b);
      }
      std::vector<int64_t> live;
      for (int64_t i : inner)
        if (i >= 0 && node(i)) live.push_back(i);
      if (live.size() != 1) {
        fail(where + ": a parenthesised group must hold exactly one expression (found " +
             llvm::Twine(live.size()) + ")");
        return static_cast<const contract::Node *>(nullptr);
      }
      n = node(live[0]);
    }
    return n;
  };
  auto rankName = [&](int r) -> std::string {
    for (const auto &kv : std::vector<std::pair<std::string, int>>{
             {"scalar", 0}, {"vec", 1}, {"mat", 2}, {"ten3", 3}, {"ten4", 4}})
      if (kv.second == r) return kv.first;
    return "?";
  };
  // Parameter name to declared dtype; dtypes: aligns with params:.
  auto dtypeOf = [&](llvm::StringRef nm) -> std::string {
    for (size_t i = 0; i < b.paramNames.size(); ++i)
      if (b.paramNames[i] == nm)
        return i < decl.dtypes.size() ? decl.dtypes[i] : decl.dtype;
    return decl.dtype;
  };
  // Match _param_of refusal: nonvariable nodes name their syntax, and variable names not in
  // parameters are refused by name.
  auto paramOf = [&](const contract::Node *n, llvm::StringRef what,
                     std::string &out) -> bool {
    if (!n || n->kind != "LocalVariableReadNode") {
      rejectNode(n ? n : def, what);
      return false;
    }
    getString(*n, "name", out);
    if (!b.rank.count(out)) {
      fail(where + ": `" + out + "` is not a parameter of this tensor_def; a body "
                   "may only mention its own parameters");
      return false;
    }
    return true;
  };
  auto addSource = [&](TensorSource s) {
    for (const TensorSource &x : b.sources) {
      // Deduplicate windows by canonical (src,win,op), so repeating a convolution does not rely on
      // CSE to avoid duplicates.
      if (s.kind == TensorSource::Kind::Window) {
        if (x.kind == s.kind && x.name == s.name && x.win == s.win && x.op == s.op)
          return;
        continue;
      }
      // Deduplicate mode by (src,axis,mat), tap by (src,axis,idx,wgt), bilinear/hist by src.
      if (s.kind == TensorSource::Kind::Mode || s.kind == TensorSource::Kind::Tap ||
          s.kind == TensorSource::Kind::Bilinear ||
          s.kind == TensorSource::Kind::Hist) {
        if (x.kind == s.kind && x.name == s.name && x.axis == s.axis &&
            x.mat == s.mat && x.idx == s.idx && x.wgt == s.wgt)
          return;
        continue;
      }
      if (x.kind == s.kind && x.name == s.name && x.node == s.node) return;
    }
    b.sources.push_back(std::move(s));
  };
  scan = [&](int64_t id) -> bool {
    if (failed) return false;
    const contract::Node *n = unwrap(id);
    if (failed) return false;
    if (!n) { fail(where + ": empty expression"); return false; }
    if (n->kind == "LocalVariableReadNode") {
      std::string name;
      if (!paramOf(n, " as an operand", name)) return false;
      const int r = b.rank[name];
      if (r >= 1 && r != b.ewRank) {
        if (r == 2 && b.ewRank == 1) {
          fail(where + ": `" + name + "` is a :mat parameter and rank-2 values have "
               "exactly one op in the subset: `" + name + ".matvec(v)`. A :mat cannot "
               "appear in an element-wise expression");
          return false;
        }
        fail(where + ": `" + name + "` is rank " + llvm::Twine(r) +
             " but this body's element-wise iteration space is rank " +
             llvm::Twine(b.ewRank) + " (the destination's rank). Every operand of an "
             "all-parallel linalg.generic is read at the SAME index, so they must all "
             "have the same rank");
        return false;
      }
      if (r >= 1) { TensorSource s; s.kind = TensorSource::Kind::Param; s.name = name; addSource(s); }
      return true;
    }
    if (n->kind == "FloatNode") return true;
    if (n->kind != "CallNode") { rejectNode(n, ""); return false; }
    std::string op;
    getString(*n, "name", op);
    int64_t blockId = -1;
    if (getReference(*n, "block", blockId) && blockId >= 0) {
      fail(where + ": a block on `" + op + "` is not in the tensor subset");
      return false;
    }
    int64_t argsId = -1;
    std::vector<int64_t> args;
    if (getReference(*n, "arguments", argsId) && argsId >= 0)
      if (const contract::Node *an = node(argsId)) getArray(*an, "arguments", args);
    if (llvm::is_contained(kPrologueOps, op)) {
      // mode_mul/tap_mul/bilinear/hist build whole tensors in the prologue, then elementwise
      // regions read results through identity. Like matvec/windows, with their own frozen refusal
      // set.
      const std::string axList = ":d0 / :d1";
      if (b.root != "assign") {
        if (op == "hist")
          fail(where + ": `" + op + "` produces a whole tensor; a histogram followed "
               "by a reduction is two stages");
        else if (op == "mode_mul")
          fail(where + ": `" + op + "` produces a whole tensor and a reduction body "
               "reads every operand at the same index. A resample followed by a "
               "reduction is two stages; write the resample as its own tensor_def");
        else
          fail(where + ": `" + op + "` produces a whole tensor and a reduction body "
               "reads every operand at the same index; write the resample as its own "
               "tensor_def");
        return false;
      }
      const int wantRank = op == "hist" ? 1 : 3;
      if (b.ewRank != wantRank) {
        if (op == "hist")
          fail(where + ": `" + op + "` produces a rank-1 tensor of counts and this "
               "body writes a rank-" + llvm::Twine(b.ewRank) + " destination. The "
               "destination IS the bin axis -- its length is the number of bins");
        else if (op == "mode_mul")
          fail(where + ": `" + op + "` needs a rank-3 (:ten3) destination and this "
               "body writes a rank-" + llvm::Twine(b.ewRank) + " one. The n-mode "
               "product contracts ONE axis of a rank-3 tensor with a matrix and "
               "leaves the other two alone, which is only a shape the region can "
               "read at its own index when both are rank 3");
        else if (op == "tap_mul")
          fail(where + ": `" + op + "` needs a rank-3 (:ten3) destination and this "
               "body writes a rank-" + llvm::Twine(b.ewRank) + " one");
        else
          fail(where + ": `" + op + "` needs a rank-3 (:ten3, i.e. (H, W, C)) "
               "destination and this body writes a rank-" + llvm::Twine(b.ewRank) +
               " one -- the OUTPUT SHAPE is where a resample learns what to "
               "resample to");
        return false;
      }
      // Argument count.
      const size_t wantArgs = op == "mode_mul" ? 2 : op == "tap_mul" ? 3 : 0;
      if (args.size() != wantArgs) {
        if (op == "mode_mul")
          fail(where + ": `" + op + "` takes exactly two arguments -- the Symbol "
               "naming the axis to contract (" + axList + ") and the :mat parameter "
               "holding the coefficients (got " + llvm::Twine(args.size()) + ")");
        else if (op == "tap_mul")
          fail(where + ": `" + op + "` takes exactly three arguments -- the Symbol "
               "naming the axis (" + axList + "), the :mat of TAP POSITIONS and the "
               ":mat of WEIGHTS, both (n_out, K) (got " + llvm::Twine(args.size()) +
               ")");
        else if (op == "bilinear")
          fail(where + ": `" + op + "` takes no arguments (got " +
               llvm::Twine(args.size()) + "). Both shapes are already in the call: "
               "the source is the receiver and the target is the destination, so "
               "there is nothing left to say -- and a scale factor said a second "
               "time could disagree with them");
        else
          fail(where + ": `" + op + "` takes no arguments (got " +
               llvm::Twine(args.size()) + "); the number of bins is the "
               "destination's length");
        return false;
      }
      int axis = 0;
      std::string axname;
      if (op == "mode_mul" || op == "tap_mul") {
        const contract::Node *an = unwrap(args[0]);
        if (failed) return false;
        if (!an || an->kind != "SymbolNode" || !getString(*an, "value", axname)) {
          fail(where + ": the `" + op + "` axis: expected a Symbol, got " +
               (an ? llvm::StringRef(an->kind) : llvm::StringRef("nothing")));
          return false;
        }
        if (axname != "d0" && axname != "d1") {
          if (op == "mode_mul")
            fail(where + ": `" + op + "(:" + axname + ", ...)` but the axis must be "
                 "one of " + axList + ". :d2 is the CHANNEL axis of an (H, W, C) "
                 "image and contracting it is a colour-space transform -- nothing in "
                 "P002 asks for one, so it is refused by name rather than emitted "
                 "untested");
          else
            fail(where + ": `" + op + "(:" + axname + ", ...)` but the axis must be "
                 "one of " + axList);
          return false;
        }
        axis = axname == "d0" ? 0 : 1;
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      std::string src;
      if (!paramOf(node(recvId), (llvm::Twine(" as the `") + op + "` receiver").str(),
                   src))
        return false;
      if (b.rank[src] != 3) {
        if (op == "mode_mul")
          fail(where + ": `" + src + "." + op + "(:" + axname + ", ...)` but `" + src +
               "` is declared :" + rankName(b.rank[src]) +
               "; the n-mode product reads a rank-3 tensor");
        else if (op == "tap_mul")
          fail(where + ": `" + src + "." + op + "(:" + axname + ", ...)` but `" + src +
               "` is declared :" + rankName(b.rank[src]) +
               "; a banded resample reads a rank-3 tensor");
        else if (op == "bilinear")
          fail(where + ": `" + src + "." + op + "` but `" + src + "` is declared :" +
               rankName(b.rank[src]) + "; `" + op + "` reads a rank-3 image");
        else
          fail(where + ": `" + src + "." + op + "` but `" + src + "` is declared :" +
               rankName(b.rank[src]) + "; `" + op +
               "` counts the elements of a rank-3 image");
        return false;
      }
      // _non_identity_gate refuses a destination receiver, controlling unsafe aliasing.
      auto nonIdentityGate = [&](const std::string &call, const std::string &nm,
                                 const std::string &extra) -> bool {
        if (decl.dest < 0 || nm != b.paramNames[decl.dest]) return true;
        fail(where + ": `" + nm + "." + call + "` reads the DESTINATION `" + nm +
             "`, and " + extra + ". E038 s4's safety argument is that every operand "
             "of an all-parallel linalg.generic is read at the SAME index as the "
             "element being written, so `dst.assign(dst + src * a)` cannot see a "
             "half-written destination no matter how the backend tiles it. That "
             "argument does not hold here, so whether a tap is the old value or one "
             "this same dispatch already overwrote is the tiling order's business. "
             "Write the result to a different tensor");
        return false;
      };
      TensorSource s;
      s.name = src;
      s.axis = axis;
      s.op = op;
      s.node = n->id;
      if (op == "mode_mul") {
        std::string mat;
        if (!paramOf(unwrap(args[1]),
                     (llvm::Twine(" as the `") + op + "` coefficient matrix").str(),
                     mat))
          return false;
        if (b.rank[mat] != 2) {
          fail(where + ": `" + src + "." + op + "(:" + axname + ", " + mat +
               ")` but `" + mat + "` is declared :" + rankName(b.rank[mat]) +
               "; the coefficients of an n-mode product are a :mat whose rows are "
               "the input positions along the contracted axis and whose columns are "
               "the output positions");
          return false;
        }
        if (dtypeOf(mat) != "f32") {
          fail(where + ": the coefficient matrix `" + mat + "` is declared :" +
               dtypeOf(mat) + ". A resampling weight is a fraction and :u8 is a "
               "BOUNDARY type with no fractions in it (E039); declare the matrix "
               ":f32");
          return false;
        }
        const std::string call = op + "(:" + axname + ", " + mat + ")";
        if (!nonIdentityGate(call, src,
                             "an n-mode product reads the WHOLE contracted axis -- "
                             "output position i reads every input position along that "
                             "axis whose weight is non-zero"))
          return false;
        if (!nonIdentityGate(call, mat,
                             "the coefficient matrix would be overwritten by the "
                             "result"))
          return false;
        s.kind = TensorSource::Kind::Mode;
        s.mat = mat;
      } else if (op == "tap_mul") {
        std::string idx, wgt;
        if (!paramOf(unwrap(args[1]),
                     (llvm::Twine(" as the `") + op + "` tap-position matrix").str(),
                     idx))
          return false;
        if (!paramOf(unwrap(args[2]),
                     (llvm::Twine(" as the `") + op + "` weight matrix").str(), wgt))
          return false;
        const std::pair<const std::string *, const char *> two[2] = {
            {&idx, "tap-position"}, {&wgt, "weight"}};
        for (const auto &kv : two) {
          const std::string &nm = *kv.first;
          if (b.rank[nm] != 2) {
            fail(where + ": `" + op + "`'s " + kv.second + " argument `" + nm +
                 "` is declared :" + rankName(b.rank[nm]) +
                 "; it must be a :mat of shape (n_out, K)");
            return false;
          }
          if (dtypeOf(nm) != "f32") {
            fail(where + ": `" + op + "`'s " + kv.second + " argument `" + nm +
                 "` is declared :" + dtypeOf(nm) + "; it must be :f32");
            return false;
          }
        }
        if (idx == wgt) {
          fail(where + ": `" + op + "(:" + axname + ", " + idx + ", " + wgt +
               ")` passes the SAME matrix as the tap positions and the weights. They "
               "are read at the same (i, k) but mean different things -- one is an "
               "index into the contracted axis, the other is a fraction -- and a "
               "program that meant to pass one of them twice has lost half of its "
               "resample");
          return false;
        }
        const std::string call = op + "(:" + axname + ", " + idx + ", " + wgt + ")";
        if (!nonIdentityGate(call, src,
                             "a banded resample reads K positions along the "
                             "contracted axis, chosen by the tap matrix"))
          return false;
        for (const std::string &nm : {idx, wgt})
          if (!nonIdentityGate(call, nm,
                               "the coefficients would be overwritten by the result"))
            return false;
        s.kind = TensorSource::Kind::Tap;
        s.idx = idx;
        s.wgt = wgt;
      } else if (op == "bilinear") {
        if (!nonIdentityGate(op, src,
                             "a bilinear resample reads a 2x2 NEIGHBOURHOOD at a "
                             "data-independent but shape-dependent position"))
          return false;
        s.kind = TensorSource::Kind::Bilinear;
      } else {
        if (dtypeOf(src) != "u8") {
          fail(where + ": `" + src + "." + op + "` but `" + src + "` is declared :" +
               dtypeOf(src) + ". A bin index is an exact integer and this lowering "
               "compares the pixel to the bin number as an integer (R005 p21); an f32 "
               "image has no bins until somebody says how it is quantised, and that "
               "is a semantic this op cannot state");
          return false;
        }
        s.kind = TensorSource::Kind::Hist;
      }
      addSource(s);
      return true;
    }
    if (llvm::is_contained(kWindowOps, op)) {
      // Scan src.conv2d(:name)/src.depthwise(:name), matching _scan_window. All but its final two
      // lines are refusals; the first reserves the capability added by the next stage.
      if (b.root != "assign") {
        fail(where + ": `" + op + "` is a window op and a reduction body reads every "
             "operand at the same index (its map is the rank-1 identity and its "
             "iterator is `reduction`). A window over an image followed by a reduction "
             "is two stages; write the window as its own tensor_def");
        return false;
      }
      if (b.ewRank != 3) {
        fail(where + ": `" + op + "` needs a rank-3 (:ten3, i.e. (H, W, C)) destination "
             "and this body writes a rank-" + llvm::Twine(b.ewRank) +
             " one. E042 lowers a window op to the NHWC named linalg op with N pinned "
             "to 1; a rank-4 (:ten4) batch of images is P002 Phase 3 and is refused "
             "here rather than emitted untested");
        return false;
      }
      if (decl.windows.empty()) {
        fail(where + ": `" + op + "` names a window but the declaration has no "
             "`windows:`. The coefficients of a window op are DECLARED, not passed: "
             "they are folded into an `arith.constant dense<...>` and are part of the "
             "signature hash (E042 s1)");
        return false;
      }
      if (args.size() != 1) {
        fail(where + ": `" + op + "` takes exactly one argument, the Symbol naming a "
             "`windows:` entry (got " + llvm::Twine(args.size()) + ")");
        return false;
      }
      const contract::Node *wn = unwrap(args[0]);
      if (failed) return false;
      std::string wname;
      if (!wn || wn->kind != "SymbolNode" || !getString(*wn, "value", wname)) {
        fail(where + ": the `" + op + "` argument: expected a Symbol, got " +
             (wn ? llvm::StringRef(wn->kind) : llvm::StringRef("nothing")));
        return false;
      }
      if (!decl.windows.count(wname)) {
        std::string names;
        for (const auto &kv : decl.windows) {   // std::map is lexically sorted.
          if (!names.empty()) names += ", ";
          names += ":" + kv.first;
        }
        fail(where + ": `" + op + "(:" + wname + ")` but this declaration's `windows:` "
             "are " + names);
        return false;
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      std::string src;
      if (!paramOf(node(recvId), (llvm::Twine(" as the `") + op + "` receiver").str(), src))
        return false;
      if (b.rank[src] != 3) {
        fail(where + ": `" + src + "." + op + "(:" + wname + ")` but `" + src +
             "` is declared :" + rankName(b.rank[src]) +
             "; a window op reads a rank-3 image");
        return false;
      }
      if (op == "conv2d" && decl.channels != 1) {
        fail(where + ": `conv2d` lowers to linalg.conv_2d_nhwc_hwcf, which SUMS over "
             "the input channels, and this declaration says channels: " +
             llvm::Twine(decl.channels) + " -- so it would silently produce one channel "
             "out of " + llvm::Twine(decl.channels) +
             " in. Use `depthwise` for a per-channel window");
        return false;
      }
      // Refusal reserved for the next capability stage, controlling unsafe aliasing.
      if (decl.dest >= 0 && src == b.paramNames[decl.dest]) {
        fail(where + ": `" + src + "." + op + "(:" + wname + ")` reads the DESTINATION `" +
             src + "` through a window. That is not safe and the reason is exactly the "
             "one that makes the element-wise case safe: E038 s4's argument is that "
             "every operand of an all-parallel linalg.generic is read at the SAME index "
             "as the element being written, so `dst.assign(dst + src * a)` cannot see a "
             "half-written destination no matter how the backend tiles it. A window op "
             "reads a NEIGHBOURHOOD -- its indexing map is `(d0 + d2, d1 + d3)` and two "
             "of its iterators are reductions (R005 s1.4) -- so output pixel i depends "
             "on input pixels i-1, i, i+1, and whether those are the old values or the "
             "new ones is the tiling order's business. Write the result to a different "
             "tensor");
        return false;
      }
      TensorSource s;
      s.kind = TensorSource::Kind::Window;
      s.name = src; s.win = wname; s.op = op; s.node = n->id;
      addSource(s);
      return true;
    }
    if (op == "matvec") {
      if (b.ewRank != 1) {
        fail(where + ": `matvec` produces a rank-1 value and this body writes a rank-" +
             llvm::Twine(b.ewRank) + " destination. R005 s2.4-E: the linear-algebra "
             "vocabulary is not given a meaning at rank >= 3 -- what an image needs is "
             "element-wise ops and window ops (P002 Phase 2), not matvec");
        return false;
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      std::string mat;
      if (!paramOf(node(recvId), " as the `matvec` receiver", mat)) return false;
      if (b.rank[mat] != 2) {
        fail(where + ": `" + mat + ".matvec(...)` but `" + mat + "` is declared :" +
             rankName(b.rank[mat]) + "; matvec needs a rank-2 (:mat) receiver");
        return false;
      }
      if (args.size() != 1) {
        fail(where + ": `matvec` takes exactly one vector (got " +
             llvm::Twine(args.size()) + ")");
        return false;
      }
      std::string vec;
      if (!paramOf(unwrap(args[0]), " as the `matvec` operand", vec)) return false;
      if (b.rank[vec] != 1) {
        fail(where + ": `" + mat + ".matvec(" + vec + ")` but `" + vec +
             "` is declared :" + rankName(b.rank[vec]) +
             "; matvec multiplies a :mat by a :vec");
        return false;
      }
      TensorSource s;
      s.kind = TensorSource::Kind::Matvec;
      s.node = n->id; s.mat = mat; s.vec = vec;
      addSource(s);
      return true;
    }
    if (llvm::is_contained(kUnopsSet, op)) {
      if (!args.empty()) {
        fail(where + ": `" + op + "` takes no arguments (got " +
             llvm::Twine(args.size()) + ")");
        return false;
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      return scan(recvId);
    }
    if (llvm::is_contained(kCmpopsSet, op)) {
      if (args.size() != 1) {
        fail(where + ": `" + op + "` takes exactly one operand (got " +
             llvm::Twine(args.size()) + ")");
        return false;
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      return scan(recvId) && scan(args[0]);
    }
    if (!llvm::is_contained(kBinopsSet, op)) {
      int64_t recvId = -1;
      const bool hasRecv = getReference(*n, "receiver", recvId) && recvId >= 0;
      if (!hasRecv && args.empty()) {
        fail(where + ": `" + op + "` is not a parameter of this tensor_def (a bare name "
             "with no receiver is a method call in Ruby, and a tensor_def body may only "
             "mention its own parameters)");
        return false;
      }
      if (llvm::is_contained(kRoots, op)) {
        fail(where + ": `" + op + "` may only be the root of a tensor_def body, not a "
             "sub-expression (a reduction inside an element-wise expression is a fusion "
             "boundary -- R004 stage 2)");
        return false;
      }
      fail(where + ": method `" + op + "` is not a tensor op. The subset is " +
           kBinopsList + " plus " + kUnopsList + ", " + kCmpopsList +
           ", `matvec`, " + kPrologueList +
           " and the roots `assign` / `sum` / `max` / `min`.");
      return false;
    }
    if (args.size() != 1) {
      fail(where + ": `" + op + "` takes exactly one operand (got " +
           llvm::Twine(args.size()) + ")");
      return false;
    }
    int64_t recvId = -1;
    getReference(*n, "receiver", recvId);
    return scan(recvId) && scan(args[0]);
  };

  if (rootName == "assign") {
    if (decl.dest < 0)
      return fail(where + ": the body assigns but the declaration has no dest:");
    const std::string destName = b.paramNames[decl.dest];
    int64_t recvId = -1;
    getReference(*root, "receiver", recvId);
    const contract::Node *recv = node(recvId);
    if (!recv || recv->kind != "LocalVariableReadNode")
      return rejectNode(recv ? recv : root, " as the `assign` receiver");
    std::string recvName;
    getString(*recv, "name", recvName);
    if (recvName != destName)
      return fail(where + ": `" + recvName + ".assign(...)` but dest: " +
                  llvm::Twine(decl.dest) + " declares `" + destName +
                  "` as the destination");
    int64_t argsId = -1;
    std::vector<int64_t> args;
    if (getReference(*root, "arguments", argsId) && argsId >= 0)
      if (const contract::Node *an = node(argsId))
        getArray(*an, "arguments", args);
    if (args.size() != 1)
      return fail(where + ": `assign` takes exactly one expression (got " +
                  llvm::Twine(args.size()) + ")");
    b.exprNode = args[0];
  } else {
    int64_t recvId = -1;
    getReference(*root, "receiver", recvId);
    b.exprNode = recvId;
  }
  if (!scan(b.exprNode))
    return std::nullopt;
  // _check_window_kw refuses declared window keywords when the body has no window operation: an unread declared attribute is worse than no attribute. Reductions, including fixed_tree, refuse matvec because it already reduces; default/fixed_tree diagnostics differ with their reasons.
  if (b.root != "assign" &&
      llvm::any_of(b.sources, [](const TensorSource &s) {
        return s.kind == TensorSource::Kind::Matvec;
      })) {
    if (decl.reduction == "fixed_tree")
      fail(where + ": reduction: :fixed_tree does not cover `matvec` (its dot "
                   "products are reductions of their own and IREE orders them; E033 "
                   "leaves matvec in :default mode). Write the matvec as its own "
                   "tensor_def.");
    else
      fail(where + ": `matvec` inside a reduction is not in the E033 subset (that is "
                   "a two-stage reduction; write the matvec as its own tensor_def)");
    return std::nullopt;
  }
  const bool anyWindow = llvm::any_of(b.sources, [](const TensorSource &s) {
    return s.kind == TensorSource::Kind::Window;
  });
  if (!anyWindow && !decl.windowKw.empty() && !b.hasUnimplementedPrologue) {
    std::string kws;
    for (const std::string &k : decl.windowKw) {
      if (!kws.empty()) kws += ", ";
      kws += k + ":";
    }
    fail(where + ": " + kws + " but the body has no window op. " +
         (decl.windowKw.size() > 1 ? "They" : "It") +
         " only mean something to `" + kWindowOpList +
         "` -- a declared attribute that nothing reads is worse than a missing one");
    return std::nullopt;
  }
  return b;
}

} // namespace spinel_mlir::tensor
