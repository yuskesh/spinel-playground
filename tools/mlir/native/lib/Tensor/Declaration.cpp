// Read tensor_def like frozen collect_tensor_decls, preserving wording/order. Frozen stops at first
// Unsupported, so ordering determines the visible cause.
#include "Declaration.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cmath>
#include <set>

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
bool getInteger(const contract::Node &n, llvm::StringRef key, int64_t &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Integer) return false;
  out = std::get<int64_t>(f->value);
  return true;
}
bool getArray(const contract::Node &n, llvm::StringRef key,
              std::vector<int64_t> &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Array) return false;
  out = std::get<std::vector<int64_t>>(f->value);
  return true;
}

// Copy frozen constants and order; diagnostic sorting depends on the correct collection type.
const std::vector<std::string> kTensorDtypesSorted = {"f32", "u8"};      // sorted()
const std::vector<std::string> kQuantModesSorted   = {"half_even", "half_up"};
const std::vector<std::string> kReductionModes     = {"default", "fixed_tree"};
const std::vector<std::string> kBorderModesSorted  = {"clamp", "reflect", "zero"};
const std::vector<std::string> kPadLowerings       = {"index", "pad_op", "auto"};
const std::vector<int> kWindowSizesSorted          = {3, 5};
constexpr int64_t kFtB = 2;
constexpr int64_t kMaxScalars = 1;
constexpr int64_t kMaxTensors = 4;

// TENSOR_RANK insertion order is ascending rank, used by rank_of diagnostics.
const std::vector<std::pair<std::string, int>> kTensorRank = {
    {"scalar", 0}, {"vec", 1}, {"mat", 2}, {"ten3", 3}, {"ten4", 4}};

std::string joinSyms(const std::vector<std::string> &v, llvm::StringRef sep) {
  std::string out;
  for (const std::string &s : v) {
    if (!out.empty()) out += sep.str();
    out += ":" + s;
  }
  return out;
}

// Python float() rounded to f32 spelling, matching _as_f32.
float asF32(double x) { return static_cast<float>(x); }

} // namespace

int rankOf(llvm::StringRef sym) {
  for (const auto &[k, r] : kTensorRank)
    if (k == sym)
      return r;
  return -1;
}

std::string TensorDecl::where() const {
  std::string s;
  llvm::raw_string_ostream os(s);
  os << "tensor_def :" << name << " (line " << line << ")";
  return s;
}

namespace {

// Read one source file declarations; stop on first failure.
struct DeclReader {
  const contract::ContractModule &module;
  DeclDiagnosticFn diag;
  bool failed = false;

  const contract::Node *node(int64_t id) const {
    for (const contract::Node &n : module.nodes())
      if (n.id == id)
        return &n;
    return nullptr;
  }

  bool fail(const llvm::Twine &detail) {
    if (!failed) {
      failed = true;
      diag(detail.str());
    }
    return false;
  }

  // _sym refuses nonsymbols with frozen wording.
  bool sym(int64_t id, const llvm::Twine &what, std::string &out) {
    const contract::Node *n = id < 0 ? nullptr : node(id);
    if (!n || n->kind != "SymbolNode" || !getString(*n, "value", out))
      return fail(what + ": expected a Symbol, got " +
                  (n ? llvm::StringRef(n->kind) : llvm::StringRef("nothing")));
    return true;
  }

  // read_num admits Integer literals too because coefficients are data.
  bool num(int64_t id, const llvm::Twine &what, double &out) {
    const contract::Node *n = id < 0 ? nullptr : node(id);
    if (n && n->kind == "FloatNode") {
      std::string spelling;
      for (const contract::AstField &f : n->fields)
        if (f.key == "value" && f.kind == contract::AstField::Kind::FloatSpelling)
          spelling = std::get<std::string>(f.value);
      if (!spelling.empty()) {
        out = std::stod(spelling);
        return true;
      }
    }
    if (n && n->kind == "IntegerNode") {
      int64_t v = 0;
      if (getInteger(*n, "value", v)) {
        out = static_cast<double>(v);
        return true;
      }
    }
    return fail(what + ": expected a number, got " +
                (n ? llvm::StringRef(n->kind) : llvm::StringRef("nothing")));
  }

  /// read_gen_dtype.
  bool genDtype(int64_t id, const llvm::Twine &what, std::string &out) {
    if (!sym(id, what, out))
      return false;
    if (!llvm::is_contained(kTensorDtypesSorted, out))
      return fail(what + ": dtype :" + out + " is not supported (" +
                  joinSyms(kTensorDtypesSorted, "/") +
                  "; there is no :f64 -- the M1 GPU has none, E030 s3.  "
                  ":f16/:i8/:i32 are types a tensor_extern may name, but a kernel "
                  "this tool WRITES computes in f32 and E039 added :u8 only as a "
                  "boundary type)");
    return true;
  }

  // read_dtype: tensor_extern may use any shim-supported element type, separately from
  // generated-kernel dtype restrictions.
  bool externDtype(int64_t id, const llvm::Twine &what, std::string &out) {
    if (!sym(id, what, out))
      return false;
    static const char *kExternDtypes[] = {"f16", "f32", "i32", "i8", "u8"};
    if (!llvm::is_contained(kExternDtypes, out)) {
      std::string names;
      for (const char *d : kExternDtypes) {   // Already lexically sorted.
        if (!names.empty()) names += "/";
        names += std::string(":") + d;
      }
      return fail(what + ": dtype :" + out + " is not one of " + names +
                  " -- these are the element types sp_tensor_shim.c can allocate, "
                  "upload and read back, and a module using anything else is "
                  "refused here rather than at the first invoke");
    }
    return true;
  }

  // read_shape: fixed Integer or symbolic dimension variable.
  bool shape(int64_t id, const llvm::Twine &where,
             std::vector<TensorExtern::Dim> &out) {
    const contract::Node *e = id < 0 ? nullptr : node(id);
    if (!e || e->kind != "ArrayNode")
      return fail(where + ": a shape is an Array of Integers and Symbols, got " +
                  (e ? llvm::StringRef(e->kind) : llvm::StringRef("nothing")));
    std::vector<int64_t> elems;
    getArray(*e, "elements", elems);
    for (int64_t dId : elems) {
      const contract::Node *dn = dId < 0 ? nullptr : node(dId);
      TensorExtern::Dim d;
      if (dn && dn->kind == "IntegerNode" && getInteger(*dn, "value", d.value)) {
        d.fixed = true;
      } else if (dn && dn->kind == "SymbolNode" && getString(*dn, "value", d.sym)) {
        d.fixed = false;
      } else {
        return fail(where + ": a dimension is an Integer (fixed) or a Symbol "
                    "(a dimension variable), got " +
                    (dn ? llvm::StringRef(dn->kind) : llvm::StringRef("nothing")));
      }
      out.push_back(std::move(d));
    }
    return true;
  }

  std::optional<std::vector<TensorDecl>> run();
  std::optional<std::vector<TensorExtern>> runExterns();
};

} // namespace

std::optional<std::vector<TensorDecl>>
collectTensorDecls(const contract::ContractModule &module,
                   DeclDiagnosticFn diag) {
  DeclReader r{module, diag};
  return r.run();
}

std::string TensorExtern::where() const {
  return "tensor_extern :" + name + " (line " + std::to_string(line) + ")";
}

std::optional<std::vector<TensorExtern>>
collectTensorExterns(const contract::ContractModule &module,
                     DeclDiagnosticFn diag) {
  DeclReader r{module, diag};
  return r.runExterns();
}

namespace {

std::optional<std::vector<TensorDecl>> DeclReader::run() {
  std::vector<TensorDecl> out;
  const contract::Node *root = node(module.root());
  if (!root)
    return out;
  int64_t stmtsId = -1;
  if (!getReference(*root, "statements", stmtsId) || stmtsId < 0)
    return out;
  const contract::Node *stmts = node(stmtsId);
  if (!stmts)
    return out;
  std::vector<int64_t> body;
  getArray(*stmts, "body", body);

  for (int64_t stId : body) {
    const contract::Node *st = stId < 0 ? nullptr : node(stId);
    if (!st || st->kind != "CallNode")
      continue;
    std::string callName;
    if (!getString(*st, "name", callName) || callName != "tensor_def")
      continue;
    int64_t recv = -1;
    if (getReference(*st, "receiver", recv) && recv >= 0) {
      fail("tensor_def must be a top-level call with no receiver");
      return std::nullopt;
    }
    int64_t line = 0;
    getInteger(*st, "node_line", line);

    int64_t argsId = -1;
    std::vector<int64_t> args;
    if (getReference(*st, "arguments", argsId) && argsId >= 0) {
      const contract::Node *an = node(argsId);
      if (an)
        getArray(*an, "arguments", args);
    }
    if (args.empty()) {
      fail("tensor_def: missing the kernel name");
      return std::nullopt;
    }
    std::string where0;
    {
      llvm::raw_string_ostream os(where0);
      os << "tensor_def (line " << line << ")";
    }
    std::string name;
    if (!sym(args[0], where0 + " first argument", name))
      return std::nullopt;
    std::string where;
    {
      llvm::raw_string_ostream os(where);
      os << "tensor_def :" << name << " (line " << line << ")";
    }

    // Collect keywords; positional arguments are forbidden.
    std::vector<std::pair<std::string, int64_t>> kw;  // Appearance order
    auto kwGet = [&](llvm::StringRef k) -> int64_t {
      for (const auto &[key, v] : kw)
        if (key == k)
          return v;
      return -2;   // Use a different sentinel: -1 means a nil-valued reference.
    };
    auto kwHas = [&](llvm::StringRef k) { return kwGet(k) != -2; };
    for (size_t i = 1; i < args.size(); ++i) {
      const contract::Node *extra = node(args[i]);
      if (!extra || extra->kind != "KeywordHashNode") {
        fail(where + ": positional argument " +
             (extra ? llvm::StringRef(extra->kind) : llvm::StringRef("nothing")) +
             " is not allowed; use dtype:/params:/dest:/returns:/reduction:");
        return std::nullopt;
      }
      std::vector<int64_t> elements;
      getArray(*extra, "elements", elements);
      for (int64_t aId : elements) {
        const contract::Node *assoc = node(aId);
        if (!assoc)
          continue;
        int64_t keyId = -1, valId = -1;
        getReference(*assoc, "key", keyId);
        getReference(*assoc, "value", valId);
        std::string key;
        if (!sym(keyId, where + " keyword", key))
          return std::nullopt;
        kw.emplace_back(key, valId);
      }
    }
    static const std::vector<std::string> kKnown = {
        "dtype", "params", "dest", "returns", "reduction", "tree_arity",
        "dtypes", "quant", "windows", "window_scale", "channels", "border",
        "pad_via"};
    std::set<std::string> unknown;
    for (const auto &[key, _] : kw)
      if (!llvm::is_contained(kKnown, key))
        unknown.insert(key);
    if (!unknown.empty()) {
      std::string joined;
      for (const std::string &u : unknown) {
        if (!joined.empty()) joined += ", ";
        joined += u;
      }
      fail(where + ": unknown keyword(s) " + joined +
           " (dtype:, params:, dest:, returns:, reduction:, tree_arity:, "
           "dtypes:, quant:, windows:, window_scale:, channels:, border:, "
           "pad_via:)");
      return std::nullopt;
    }
    if (!kwHas("dtype")) {
      fail(where +
           ": dtype: is required and has no default -- spinel's inference has no "
           "f32 (R001 s1.3), so the dtype has to be a syntactic fact (R004 s3.1)");
      return std::nullopt;
    }
    TensorDecl d;
    d.name = name;
    d.line = line;
    if (!genDtype(kwGet("dtype"), where + " dtype:", d.dtype))
      return std::nullopt;

    // params:
    int64_t pId = kwGet("params");
    const contract::Node *pn = pId >= 0 ? node(pId) : nullptr;
    if (!pn || pn->kind != "ArrayNode") {
      fail(where + ": params: must be an Array of :scalar/:vec/:mat");
      return std::nullopt;
    }
    std::vector<int64_t> pElems;
    getArray(*pn, "elements", pElems);
    for (int64_t e : pElems) {
      std::string p;
      if (!sym(e, where + " params:", p))
        return std::nullopt;
      d.params.push_back(p);
    }
    for (const std::string &p : d.params) {
      if (rankOf(p) < 0) {
        std::vector<std::string> names;
        for (const auto &[k, _] : kTensorRank) names.push_back(k);
        // Frozen rank_of prefixes only where, not params:.
        fail(where + ": rank :" + p + " is not one of " + joinSyms(names, "/"));
        return std::nullopt;
      }
    }

    // dtypes:
    if (kwHas("dtypes")) {
      const contract::Node *dn = kwGet("dtypes") >= 0 ? node(kwGet("dtypes")) : nullptr;
      if (!dn || dn->kind != "ArrayNode") {
        fail(where + ": dtypes: must be an Array with one dtype per params: entry");
        return std::nullopt;
      }
      std::vector<int64_t> dElems;
      getArray(*dn, "elements", dElems);
      for (int64_t e : dElems) {
        std::string dt;
        if (!genDtype(e, where + " dtypes:", dt))
          return std::nullopt;
        d.dtypes.push_back(dt);
      }
      if (d.dtypes.size() != d.params.size()) {
        fail(where + ": dtypes: has " + llvm::Twine(d.dtypes.size()) +
             " entries but params: has " + llvm::Twine(d.params.size()));
        return std::nullopt;
      }
      for (size_t i = 0; i < d.params.size(); ++i)
        if (d.params[i] == "scalar" && d.dtypes[i] != "f32") {
          fail(where + ": a :scalar parameter is captured into the region as an "
                       "f32 value and cannot be :" + d.dtypes[i]);
          return std::nullopt;
        }
    }
    const bool hadDtypes = !d.dtypes.empty();
    if (!hadDtypes)
      d.dtypes.assign(d.params.size(), d.dtype);

    // quant:
    if (kwHas("quant")) {
      if (!sym(kwGet("quant"), where + " quant:", d.quant))
        return std::nullopt;
      if (!llvm::is_contained(kQuantModesSorted, d.quant)) {
        fail(where + ": quant: :" + d.quant +
             " is not a rounding contract. The modes are :half_even "
             "(math.roundeven -- what IREE implements on BOTH devices, R005 s3.2) "
             "and :half_up (floor(x + 0.5)). They disagree, and not rarely: a "
             "dyadic gain puts a THIRD of an image exactly on a rounding boundary "
             "(E039 s4), so this is a semantic decision and not a detail");
        return std::nullopt;
      }
      const bool anyU8 = hadDtypes && llvm::is_contained(d.dtypes, std::string("u8"));
      if (!anyU8 && d.dtype != "u8") {
        fail(where + ": quant: only means something on a kernel whose DESTINATION "
                     "is :u8 -- it names how an f32 value becomes a byte, and this "
                     "declaration writes f32");
        return std::nullopt;
      }
    }

    // dest:
    if (kwHas("dest")) {
      const contract::Node *dn = kwGet("dest") >= 0 ? node(kwGet("dest")) : nullptr;
      if (!dn || dn->kind != "IntegerNode") {
        fail(where + ": dest: must be an Integer parameter index");
        return std::nullopt;
      }
      if (!getInteger(*dn, "value", d.dest)) {
        fail(where + ": could not read dest: from the AST");
        return std::nullopt;
      }
    }
    // returns:
    if (kwHas("returns")) {
      if (!sym(kwGet("returns"), where + " returns:", d.returns))
        return std::nullopt;
      if (d.returns != "scalar") {
        fail(where + ": returns: :" + d.returns +
             " is not supported (only :scalar)");
        return std::nullopt;
      }
    }
    // reduction:
    if (kwHas("reduction")) {
      if (!sym(kwGet("reduction"), where + " reduction:", d.reduction))
        return std::nullopt;
      if (!llvm::is_contained(kReductionModes, d.reduction)) {
        fail(where + ": reduction: :" + d.reduction +
             " is not a summation-order mode. The modes are :default "
             "(backend-defined order, normwise tolerance) and :fixed_tree "
             "(device-independent order, bitwise across backends) -- R004 "
             "decision record");
        return std::nullopt;
      }
      if (d.returns != "scalar") {
        fail(where + ": reduction: :" + d.reduction +
             " is only meaningful on a kernel that reduces (returns: :scalar); "
             "this declaration has no reduction to order");
        return std::nullopt;
      }
    }
    // tree_arity:
    d.treeArity = kFtB;
    if (kwHas("tree_arity")) {
      const contract::Node *an = kwGet("tree_arity") >= 0 ? node(kwGet("tree_arity")) : nullptr;
      if (!an || an->kind != "IntegerNode") {
        fail(where + ": tree_arity: must be an Integer");
        return std::nullopt;
      }
      bool haveValue = getInteger(*an, "value", d.treeArity);
      if (d.reduction != "fixed_tree") {
        fail(where + ": tree_arity: only means something under reduction: "
                     ":fixed_tree (the default mode's order is the backend's to "
                     "choose)");
        return std::nullopt;
      }
      if (!haveValue || d.treeArity < 2 || d.treeArity > 16 ||
          (d.treeArity & (d.treeArity - 1)) != 0) {
        fail(where + ": tree_arity: " +
             (haveValue ? llvm::Twine(d.treeArity) : llvm::Twine("None")) +
             " is not a power of two in 2..16");
        return std::nullopt;
      }
    }
    if (d.dest >= 0 && d.returns != "none") {
      fail(where + ": dest: and returns: are exclusive -- a kernel either writes "
                   "its destination or returns a scalar");
      return std::nullopt;
    }
    if (d.dest < 0 && d.returns == "none") {
      fail(where + ": needs either dest: (destination-passing) or returns: :scalar");
      return std::nullopt;
    }
    if (d.dest >= 0) {
      if (d.dest >= static_cast<int64_t>(d.params.size())) {
        fail(where + ": dest: " + llvm::Twine(d.dest) +
             " is out of range for " + llvm::Twine(d.params.size()) + " parameter(s)");
        return std::nullopt;
      }
      if (d.params[d.dest] == "scalar") {
        fail(where + ": dest: " + llvm::Twine(d.dest) + " names a :" +
             d.params[d.dest] + " parameter; the destination must be a tensor");
        return std::nullopt;
      }
      if (d.params[d.dest] == "mat") {
        fail(where + ": dest: " + llvm::Twine(d.dest) +
             " names a :mat parameter; a rank-2 destination is not in the E033 "
             "subset (the only rank-2 op is `matvec`, whose result is rank 1)");
        return std::nullopt;
      }
    }
    int64_t nsc = 0, ntn = 0;
    for (const std::string &p : d.params)
      (p == "scalar" ? nsc : ntn)++;
    if (nsc > kMaxScalars || ntn > kMaxTensors) {
      fail(where + ": " + llvm::Twine(nsc) + " scalar / " + llvm::Twine(ntn) +
           " tensor parameters exceeds the dispatch entry in spinel/tensor.rb "
           "(max " + llvm::Twine(kMaxScalars) + " scalar / " +
           llvm::Twine(kMaxTensors) + " tensor)");
      return std::nullopt;
    }
    if (d.returns == "scalar" &&
        llvm::any_of(d.dtypes, [](const std::string &x) { return x != "f32"; })) {
      fail(where + ": a reducing kernel returns an f32 scalar, so its operands are "
                   "f32 too; :u8 is an element-wise boundary type in E039 and a "
                   "reduction over bytes is Phase 2 (P002)");
      return std::nullopt;
    }
    if (d.dest >= 0 && d.dtypes[d.dest] == "u8" && rankOf(d.params[d.dest]) == 0) {
      fail(where + ": a :u8 destination must be a tensor");
      return std::nullopt;
    }

    // ---- Window operations -------------------------------------------------
    double scale = 1.0;
    if (kwHas("window_scale") && !num(kwGet("window_scale"), where + " window_scale:", scale))
      return std::nullopt;
    if (kwHas("windows")) {
      const contract::Node *hn = kwGet("windows") >= 0 ? node(kwGet("windows")) : nullptr;
      if (!hn || hn->kind != "HashNode") {
        fail(where + ": windows: must be a Hash of name => 2-D coefficient Array, "
                     "e.g. `windows: { blur: [[1.0, 2.0, 1.0], [2.0, 4.0, 2.0], "
                     "[1.0, 2.0, 1.0]] }`");
        return std::nullopt;
      }
      std::vector<int64_t> elements;
      getArray(*hn, "elements", elements);
      for (int64_t aId : elements) {
        const contract::Node *assoc = node(aId);
        if (!assoc)
          continue;
        int64_t keyId = -1, valId = -1;
        getReference(*assoc, "key", keyId);
        getReference(*assoc, "value", valId);
        std::string wn;
        if (!sym(keyId, where + " windows: key", wn))
          return std::nullopt;
        const contract::Node *rowsn = valId >= 0 ? node(valId) : nullptr;
        if (!rowsn || rowsn->kind != "ArrayNode") {
          fail(where + ": window :" + wn + " must be a 2-D Array of numbers");
          return std::nullopt;
        }
        std::vector<int64_t> rowIds;
        getArray(*rowsn, "elements", rowIds);
        std::vector<std::vector<float>> rows;
        std::vector<size_t> widths;
        for (int64_t rId : rowIds) {
          const contract::Node *rn = rId >= 0 ? node(rId) : nullptr;
          if (!rn || rn->kind != "ArrayNode") {
            fail(where + ": window :" + wn +
                 " must be a 2-D Array of numbers (one Array per row)");
            return std::nullopt;
          }
          std::vector<int64_t> cells;
          getArray(*rn, "elements", cells);
          std::vector<float> row;
          for (int64_t c : cells) {
            double v = 0;
            if (!num(c, where + " window :" + wn, v))
              return std::nullopt;
            row.push_back(asF32(v));
          }
          widths.push_back(row.size());
          rows.push_back(std::move(row));
        }
        const size_t kh = rows.size();
        const bool square =
            llvm::is_contained(kWindowSizesSorted, static_cast<int>(kh)) &&
            llvm::all_of(widths, [&](size_t w) { return w == kh; });
        if (!square) {
          std::string lens;
          for (size_t w : widths) {
            if (!lens.empty()) lens += ",";
            lens += std::to_string(w);
          }
          if (lens.empty()) lens = "-";
          std::string sizes;
          for (int sz : kWindowSizesSorted) {
            if (!sizes.empty()) sizes += "/";
            sizes += std::to_string(sz) + "x" + std::to_string(sz);
          }
          fail(where + ": window :" + wn + " has " + llvm::Twine(kh) +
               " row(s) of length " + lens +
               "; a window must be SQUARE and one of " + sizes +
               ". An even size has no centre pixel and a bigger one has not been "
               "measured (the derived error bound is gamma_k for k = the window "
               "area -- E042 s4)");
          return std::nullopt;
        }
        // Fold scale as f32 here, affecting module text/signature hash.
        for (auto &row : rows)
          for (float &c : row)
            c = asF32(asF32(c) * asF32(scale));
        d.windows[wn] = std::move(rows);
      }
    }
    if (kwHas("channels")) {
      const contract::Node *cn = kwGet("channels") >= 0 ? node(kwGet("channels")) : nullptr;
      int64_t v = 0;
      if (!cn || cn->kind != "IntegerNode" || !getInteger(*cn, "value", v)) {
        fail(where + ": channels: must be an Integer");
        return std::nullopt;
      }
      d.channels = v;
      if (d.channels < 1 || d.channels > 4) {
        fail(where + ": channels: " + llvm::Twine(d.channels) +
             " is out of range 1..4. The channel count is STATIC because the "
             "window coefficients are declared and a constant filter has a static "
             "shape (E042 s1); the ceiling is 4 because nothing in P002 asks for "
             "more and each value is its own .vmfb entry");
        return std::nullopt;
      }
    }
    if (kwHas("border")) {
      if (!sym(kwGet("border"), where + " border:", d.border))
        return std::nullopt;
      if (!llvm::is_contained(kBorderModesSorted, d.border)) {
        fail(where + ": border: :" + d.border +
             " is not a border contract. The modes are " +
             joinSyms(kBorderModesSorted, "/") +
             ". What happens outside the image is a SEMANTIC decision, not a "
             "detail -- R005 s6/E042 s3 -- and it is declared for the same reason "
             "`reduction:` and `quant:` are: the .vmfb is baked at compile time");
        return std::nullopt;
      }
    }
    if (kwHas("pad_via")) {
      if (!sym(kwGet("pad_via"), where + " pad_via:", d.padVia))
        return std::nullopt;
      if (!llvm::is_contained(kPadLowerings, d.padVia)) {
        fail(where + ": pad_via: :" + d.padVia +
             " is not a border lowering. The choices are :index (one "
             "linalg.generic computes the border by index arithmetic -- the "
             "default, 1 dispatch) and :pad_op (`tensor.pad` in front of the "
             "convolution -- R005 p14's form, 1 dispatch more) and :auto (E069 W4: "
             "the faster one for the device this module is being built for -- "
             ":pad_op on the CPU backend, :index on Metal). They compute the same "
             "pixels; E042 s5 measured the difference");
        return std::nullopt;
      }
      if (d.padVia == "pad_op" && d.border != "zero") {
        fail(where + ": pad_via: :pad_op only lowers border: :zero (`tensor.pad` "
                     "fills with one constant). :" + d.border +
             " needs the index arithmetic");
        return std::nullopt;
      }
    }
    // Collect in fixed Python order, not source order.
    for (const char *k : {"windows", "window_scale", "channels", "border", "pad_via"})
      if (kwHas(k))
        d.windowKw.emplace_back(k);

    out.push_back(std::move(d));
  }
  return out;
}

} // namespace
} // namespace spinel_mlir::tensor

namespace spinel_mlir::tensor {

// tensor_extern names a foreign .vmfb entry. Without a body, no signature part can be inferred:
// require every field and preserve frozen wording.
std::optional<std::vector<TensorExtern>> DeclReader::runExterns() {
  std::vector<TensorExtern> out;
  const contract::Node *root = node(module.root());
  if (!root) return out;
  int64_t stmtsId = -1;
  if (!getReference(*root, "statements", stmtsId) || stmtsId < 0) return out;
  const contract::Node *stmts = node(stmtsId);
  if (!stmts) return out;
  std::vector<int64_t> body;
  getArray(*stmts, "body", body);

  for (int64_t stId : body) {
    const contract::Node *st = stId < 0 ? nullptr : node(stId);
    if (!st || st->kind != "CallNode") continue;
    std::string callName;
    if (!getString(*st, "name", callName) || callName != "tensor_extern") continue;
    int64_t recv = -1;
    if (getReference(*st, "receiver", recv) && recv >= 0) {
      fail("tensor_extern must be a top-level call with no receiver");
      return std::nullopt;
    }
    int64_t argsId = -1;
    std::vector<int64_t> args;
    if (getReference(*st, "arguments", argsId) && argsId >= 0)
      if (const contract::Node *an = node(argsId)) getArray(*an, "arguments", args);
    if (args.empty()) {
      fail("tensor_extern: missing the entry name");
      return std::nullopt;
    }
    int64_t line = 0;
    getInteger(*st, "node_line", line);

    TensorExtern x;
    x.line = line;
    const std::string where0 =
        "tensor_extern (line " + std::to_string(line) + ")";
    if (!sym(args[0], where0 + " first argument", x.name)) return std::nullopt;
    const std::string where = x.where();

    // Collect keywords without positional arguments.
    std::map<std::string, int64_t> kw;
    for (size_t i = 1; i < args.size(); ++i) {
      const contract::Node *extra = args[i] < 0 ? nullptr : node(args[i]);
      if (!extra || extra->kind != "KeywordHashNode") {
        fail(where + ": positional argument " +
             (extra ? llvm::StringRef(extra->kind) : llvm::StringRef("nothing")) +
             " is not allowed");
        return std::nullopt;
      }
      std::vector<int64_t> elems;
      getArray(*extra, "elements", elems);
      for (int64_t aId : elems) {
        const contract::Node *assoc = aId < 0 ? nullptr : node(aId);
        if (!assoc) continue;
        int64_t kId = -1, vId = -1;
        getReference(*assoc, "key", kId);
        getReference(*assoc, "value", vId);
        std::string key;
        if (!sym(kId, where + " keyword", key)) return std::nullopt;
        kw[key] = vId;
      }
    }
    static const char *kKnown[] = {"dtype",   "dtypes",        "entry",
                                   "params",  "returns",       "returns_dtype",
                                   "returns_shape", "shapes",  "vm_module"};
    {
      std::vector<std::string> unknown;   // std::map is lexically sorted.
      for (const auto &kv : kw)
        if (!llvm::is_contained(kKnown, kv.first)) unknown.push_back(kv.first);
      if (!unknown.empty()) {
        std::string u, k;
        for (const std::string &n : unknown) { if (!u.empty()) u += ", "; u += n; }
        for (const char *n : kKnown) { if (!k.empty()) k += ", "; k += std::string(n) + ":"; }
        fail(where + ": unknown keyword(s) " + u + " (" + k + ")");
        return std::nullopt;
      }
    }
    for (const char *req : {"dtype", "vm_module", "entry", "params", "shapes",
                            "returns", "returns_shape"})
      if (!kw.count(req)) {
        fail(where + ": " + req +
             ": is required -- a foreign entry has no body to read it out of, so "
             "every part of its signature has to be written down");
        return std::nullopt;
      }

    if (!externDtype(kw["dtype"], where + " dtype:", x.dtype)) return std::nullopt;
    if (!sym(kw["vm_module"], where + " vm_module:", x.vmModule)) return std::nullopt;
    if (!sym(kw["entry"], where + " entry:", x.entry)) return std::nullopt;

    const contract::Node *pn = kw["params"] < 0 ? nullptr : node(kw["params"]);
    if (!pn || pn->kind != "ArrayNode") {
      fail(where + ": params: must be an Array of :vec/:mat");
      return std::nullopt;
    }
    std::vector<int64_t> pel;
    getArray(*pn, "elements", pel);
    for (int64_t e : pel) {
      std::string p;
      if (!sym(e, where + " params:", p)) return std::nullopt;
      if (p == "scalar") {
        fail(where + ": a :scalar parameter is not in the tensor_extern subset "
                     "(E034 exports take tensors only)");
        return std::nullopt;
      }
      if (rankOf(p) < 0) {
        fail(where + ": :" + p + " is not a tensor kind");
        return std::nullopt;
      }
      x.params.push_back(p);
    }

    const contract::Node *sn = kw["shapes"] < 0 ? nullptr : node(kw["shapes"]);
    if (!sn || sn->kind != "ArrayNode") {
      fail(where + ": shapes: must be an Array of per-parameter shape Arrays");
      return std::nullopt;
    }
    std::vector<int64_t> sel;
    getArray(*sn, "elements", sel);
    for (int64_t e : sel) {
      std::vector<TensorExtern::Dim> dims;
      if (!shape(e, where, dims)) return std::nullopt;
      x.shapes.push_back(std::move(dims));
    }
    if (x.shapes.size() != x.params.size()) {
      fail(where + ": shapes: has " + llvm::Twine(x.shapes.size()) +
           " entries but params: has " + llvm::Twine(x.params.size()));
      return std::nullopt;
    }

    if (!sym(kw["returns"], where + " returns:", x.returns)) return std::nullopt;
    if (x.returns == "scalar") {
      fail(where + ": returns: :scalar is not in the tensor_extern subset "
                   "(E034 exports return a tensor)");
      return std::nullopt;
    }
    if (rankOf(x.returns) < 0) {
      fail(where + ": :" + x.returns + " is not a tensor kind");
      return std::nullopt;
    }
    if (!shape(kw["returns_shape"], where, x.returnsShape)) return std::nullopt;

    // Match rank against shape dimension count across concatenated parameters/results.
    {
      std::vector<std::string> kinds(x.params);
      kinds.push_back(x.returns);
      std::vector<const std::vector<TensorExtern::Dim> *> shps;
      for (const auto &v : x.shapes) shps.push_back(&v);
      shps.push_back(&x.returnsShape);
      for (size_t i = 0; i < kinds.size(); ++i) {
        const int r = rankOf(kinds[i]);
        if (static_cast<int>(shps[i]->size()) != r) {
          fail(where + ": a :" + kinds[i] + " is rank " + llvm::Twine(r) +
               " but its shape has " + llvm::Twine(shps[i]->size()) +
               " dimension(s)");
          return std::nullopt;
        }
      }
    }
    if (x.params.size() + 1 > 4) {
      fail(where + ": " + llvm::Twine(x.params.size()) +
           " argument(s) + 1 result exceeds the dispatch entry in "
           "spinel/tensor.rb (max 4 tensors)");
      return std::nullopt;
    }

    if (kw.count("dtypes")) {
      const contract::Node *dn = kw["dtypes"] < 0 ? nullptr : node(kw["dtypes"]);
      if (!dn || dn->kind != "ArrayNode") {
        fail(where + ": dtypes: must be an Array with one dtype per params: entry");
        return std::nullopt;
      }
      std::vector<int64_t> del;
      getArray(*dn, "elements", del);
      for (int64_t e : del) {
        std::string d;
        if (!externDtype(e, where + " dtypes:", d)) return std::nullopt;
        x.dtypes.push_back(d);
      }
      if (x.dtypes.size() != x.params.size()) {
        fail(where + ": dtypes: has " + llvm::Twine(x.dtypes.size()) +
             " entries but params: has " + llvm::Twine(x.params.size()));
        return std::nullopt;
      }
    }
    if (kw.count("returns_dtype") &&
        !externDtype(kw["returns_dtype"], where + " returns_dtype:", x.returnsDtype))
      return std::nullopt;

    out.push_back(std::move(x));
  }
  return out;
}

} // namespace spinel_mlir::tensor
