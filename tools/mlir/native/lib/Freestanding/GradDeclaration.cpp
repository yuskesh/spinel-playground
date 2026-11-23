// Native freestanding_grad_def and G1-fs gate port of read_grad_decls/read_params/gate1. Preserve
// check order and wording: the claim is identical code and diagnostic line for the same input.
// Share scalar AST accessors with Declaration.cpp to keep missing-field semantics in one place.
#include "spinel-mlir/Freestanding/GradDeclaration.h"

#include "../Frontend/Scalar/ScalarAst.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdio>
#include <map>

using namespace llvm;
using namespace spinel_mlir::contract;
namespace ast = spinel_mlir::scalar::ast;

namespace spinel_mlir::freestanding {
namespace {

// printf %g reproduces frozen "tol: %g" spelling.
std::string formatG(double v) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%g", v);
  return std::string(buf);
}

class Ctx {
public:
  explicit Ctx(const ContractModule &m) {
    for (const Node &n : m.nodes())
      byId_[n.id] = &n;
  }
  const Node *node(int64_t id) const {
    auto it = byId_.find(id);
    return it == byId_.end() ? nullptr : it->second;
  }
  const std::map<int64_t, const Node *> &all() const { return byId_; }

private:
  std::map<int64_t, const Node *> byId_;
};

bool symbolValue(const Ctx &c, int64_t id, std::string &out) {
  const Node *n = c.node(id);
  if (!n || (n->kind != "SymbolNode" && n->kind != "StringNode"))
    return false;
  return ast::getString(*n, "value", out) ||
         ast::getString(*n, "unescaped", out);
}

// Frozen lit(): declarations admit only these five literal kinds.
struct Lit {
  enum class Kind { Sym, Num, Arr, Bool } kind = Kind::Sym;
  std::string sym;
  double num = 0.0;
  bool boolean = false;
  std::vector<Lit> arr;
};

bool readLit(const Ctx &c, int64_t id, StringRef where, Lit &out,
             std::string &error) {
  const Node *n = c.node(id);
  if (!n) {
    error = (where + ": missing value").str();
    return false;
  }
  if (n->kind == "SymbolNode") {
    out.kind = Lit::Kind::Sym;
    ast::getString(*n, "value", out.sym);
    return true;
  }
  if (n->kind == "FloatNode") {
    out.kind = Lit::Kind::Num;
    std::string spelling;
    if (ast::getFloatSpelling(*n, "value", spelling))
      out.num = std::strtod(spelling.c_str(), nullptr);
    return true;
  }
  if (n->kind == "IntegerNode") {
    out.kind = Lit::Kind::Num;
    int64_t v = 0;
    ast::getInteger(*n, "value", v);
    out.num = static_cast<double>(v);
    return true;
  }
  if (n->kind == "ArrayNode") {
    out.kind = Lit::Kind::Arr;
    std::vector<int64_t> elems;
    ast::getArray(*n, "elements", elems);
    for (int64_t e : elems) {
      Lit sub;
      if (!readLit(c, e, where, sub, error))
        return false;
      out.arr.push_back(std::move(sub));
    }
    return true;
  }
  if (n->kind == "TrueNode" || n->kind == "FalseNode") {
    out.kind = Lit::Kind::Bool;
    out.boolean = n->kind == "TrueNode";
    return true;
  }
  error = (where + ": `" + n->kind +
           "` is not a literal a grad_def declaration may carry (only Symbols, "
           "numbers and Arrays of them)")
              .str();
  return false;
}

} // namespace

std::optional<std::vector<FsDecl>>
readGradBoundaryDeclarations(const ContractModule &module, std::string &error) {
  Ctx c(module);
  const Node *root = c.node(module.root());
  int64_t stmtsId = -1;
  const Node *stmts =
      root && ast::getReference(*root, "statements", stmtsId) ? c.node(stmtsId)
                                                              : nullptr;
  if (!stmts) {
    error = "the contract module has no top-level statements";
    return std::nullopt;
  }
  std::vector<int64_t> body;
  ast::getArray(*stmts, "body", body);

  std::vector<FsDecl> out;
  for (int64_t id : body) {
    const Node *n = c.node(id);
    if (!n || n->kind != "CallNode")
      continue;
    std::string callee;
    if (!ast::getString(*n, "name", callee) || callee != "freestanding_def")
      continue;
    int64_t line = 0;
    ast::getInteger(*n, "node_line", line);
    std::string where = ("freestanding_def (line " + Twine(line) + ")").str();
    int64_t argsId = -1;
    ast::getReference(*n, "arguments", argsId);
    const Node *argsN = argsId >= 0 ? c.node(argsId) : nullptr;
    std::vector<int64_t> args;
    if (argsN)
      ast::getArray(*argsN, "arguments", args);
    FsDecl d;
    d.line = line;
    if (args.empty() || !symbolValue(c, args[0], d.name)) {
      error = where + ": missing the method name";
      return std::nullopt;
    }
    // Only the final KeywordHashNode, matching _kwargs.
    std::map<std::string, int64_t> kw;
    if (args.size() > 1) {
      const Node *last = c.node(args.back());
      if (last &&
          (last->kind == "KeywordHashNode" || last->kind == "HashNode")) {
        std::vector<int64_t> elems;
        ast::getArray(*last, "elements", elems);
        for (int64_t e : elems) {
          const Node *assoc = c.node(e);
          if (!assoc || assoc->kind != "AssocNode") {
            error = where + ": only `key: value` pairs";
            return std::nullopt;
          }
          int64_t keyId = -1, valId = -1;
          ast::getReference(*assoc, "key", keyId);
          ast::getReference(*assoc, "value", valId);
          std::string keyName;
          if (!symbolValue(c, keyId, keyName)) {
            error = where + ": keyword keys must be symbols";
            return std::nullopt;
          }
          kw[keyName] = valId;
        }
      }
    }
    auto it = kw.find("params");
    const Node *paramsN = it == kw.end() ? nullptr : c.node(it->second);
    if (!paramsN || paramsN->kind != "ArrayNode") {
      error = where + ": params: must be an Array";
      return std::nullopt;
    }
    std::vector<int64_t> pes;
    ast::getArray(*paramsN, "elements", pes);
    for (int64_t pe : pes) {
      const Node *pn = c.node(pe);
      FsParam param;
      if (pn && pn->kind == "ArrayNode") {
        std::vector<int64_t> two;
        ast::getArray(*pn, "elements", two);
        std::string tag, dir;
        if (two.size() != 2 || !symbolValue(c, two[0], tag) ||
            !symbolValue(c, two[1], dir)) {
          error = where + ": a buffer entry is [:<elem>_buf, :<dir>]";
          return std::nullopt;
        }
        StringRef t(tag);
        if (!t.ends_with("_buf") ||
            !llvm::is_contained(bufferElementTypes(), t.drop_back(4))) {
          error = where + ": unknown buffer element type :" + tag;
          return std::nullopt;
        }
        if (!llvm::is_contained(bufferDirections(), StringRef(dir))) {
          error = where + ": unknown direction :" + dir;
          return std::nullopt;
        }
        param.kind = FsParam::Kind::Buffer;
        param.type = t.drop_back(4).str();
        param.direction = dir;
      } else {
        std::string sym;
        if (!symbolValue(c, pe, sym)) {
          error = where + ": params: entries are Symbols or Arrays";
          return std::nullopt;
        }
        if (sym == "len") {
          param.kind = FsParam::Kind::Len;
          param.type = "i32";
        } else if (llvm::is_contained(boundaryScalarTypes(), StringRef(sym))) {
          param.kind = FsParam::Kind::Scalar;
          param.type = sym;
        } else {
          error = where + ": unknown boundary type :" + sym;
          return std::nullopt;
        }
      }
      d.params.push_back(param);
    }
    auto rt = kw.find("returns");
    const Node *rn = rt == kw.end() ? nullptr : c.node(rt->second);
    if (!rn || rn->kind != "SymbolNode") {
      error = where + ": returns: must be a Symbol";
      return std::nullopt;
    }
    ast::getString(*rn, "value", d.returns);
    auto ex = kw.find("export");
    if (ex != kw.end()) {
      std::string v;
      if (symbolValue(c, ex->second, v))
        d.exportSymbol = v;
    }
    out.push_back(std::move(d));
  }
  return out;
}

std::optional<std::vector<FsGradDecl>>
readFreestandingGradDeclarations(const ContractModule &module,
                                 std::vector<GradReject> &rejects,
                                 std::string &error) {
  Ctx c(module);
  const Node *root = c.node(module.root());
  if (!root) {
    error = "the contract module has no root";
    return std::nullopt;
  }
  int64_t stmtsId = -1;
  if (!ast::getReference(*root, "statements", stmtsId)) {
    error = "the contract module has no top-level statements";
    return std::nullopt;
  }
  const Node *stmts = c.node(stmtsId);
  if (!stmts) {
    error = "the contract module has no top-level statements";
    return std::nullopt;
  }
  std::vector<int64_t> body;
  ast::getArray(*stmts, "body", body);

  std::vector<FsGradDecl> out;
  std::map<std::string, int64_t> seen;
  for (int64_t id : body) {
    const Node *n = c.node(id);
    if (!n || n->kind != "CallNode")
      continue;
    std::string callee;
    if (!ast::getString(*n, "name", callee) ||
        callee != "freestanding_grad_def")
      continue;
    int64_t line = 0;
    ast::getInteger(*n, "node_line", line);
    std::string where =
        ("freestanding_grad_def (line " + Twine(line) + ")").str();
    int64_t recv = -1;
    ast::getReference(*n, "receiver", recv);
    if (recv >= 0) {
      error = where + ": must be a top-level call with no receiver";
      return std::nullopt;
    }
    int64_t argsId = -1;
    ast::getReference(*n, "arguments", argsId);
    const Node *argsN = argsId >= 0 ? c.node(argsId) : nullptr;
    std::vector<int64_t> args;
    if (argsN)
      ast::getArray(*argsN, "arguments", args);
    std::string name;
    if (args.empty() || !symbolValue(c, args[0], name)) {
      error = where + ": missing the method name";
      return std::nullopt;
    }
    FsGradDecl d;
    d.name = name;
    d.line = line;
    auto dup = seen.find(d.name);
    if (dup != seen.end()) {
      // Only g08 is a Reject during reading, preserving frozen ordering.
      GradReject r;
      r.target = d.name;
      r.line = line;
      r.code = "g08";
      r.message = (where + ": " + d.name +
                   " already has a freestanding_grad_def at line " +
                   Twine(dup->second))
                      .str();
      rejects.push_back(r);
      return std::nullopt;
    }
    seen[d.name] = line;

    // Only the final KeywordHashNode supplies keywords (_kwargs).
    std::vector<std::pair<std::string, int64_t>> kw;
    if (args.size() > 1) {
      const Node *last = c.node(args.back());
      if (last && (last->kind == "KeywordHashNode" || last->kind == "HashNode")) {
        std::vector<int64_t> elems;
        ast::getArray(*last, "elements", elems);
        for (int64_t e : elems) {
          const Node *assoc = c.node(e);
          if (!assoc || assoc->kind != "AssocNode") {
            error = where + ": only `key: value` pairs";
            return std::nullopt;
          }
          int64_t keyId = -1, valId = -1;
          ast::getReference(*assoc, "key", keyId);
          ast::getReference(*assoc, "value", valId);
          const Node *k = keyId >= 0 ? c.node(keyId) : nullptr;
          if (!k || k->kind != "SymbolNode") {
            error = where + ": keyword keys must be symbols";
            return std::nullopt;
          }
          std::string keyName;
          ast::getString(*k, "value", keyName);
          kw.emplace_back(keyName, valId);
        }
      }
    }

    for (auto &kv : kw) {
      const std::string &k = kv.first;
      Lit v;
      if (k == "wrt") {
        if (!readLit(c, kv.second, where, v, error))
          return std::nullopt;
        if (v.kind == Lit::Kind::Sym) {
          d.wrt.push_back(v.sym);
        } else if (v.kind == Lit::Kind::Arr) {
          for (const Lit &e : v.arr) {
            if (e.kind != Lit::Kind::Sym) {
              error = where + ": wrt: takes parameter names";
              return std::nullopt;
            }
            d.wrt.push_back(e.sym);
          }
        } else {
          error = where + ": wrt: takes a Symbol or an Array";
          return std::nullopt;
        }
      } else if (k == "mode") {
        if (!readLit(c, kv.second, where, v, error))
          return std::nullopt;
        d.mode = v.sym;
      } else if (k == "tol") {
        if (!readLit(c, kv.second, where, v, error))
          return std::nullopt;
        d.tol = v.num;
      } else if (k == "export") {
        if (!readLit(c, kv.second, where, v, error))
          return std::nullopt;
        d.exportSymbol = v.sym;
      } else if (k == "hvp") {
        if (!readLit(c, kv.second, where, v, error))
          return std::nullopt;
        if (v.kind != Lit::Kind::Bool) {
          error = where + ": hvp: takes true or false";
          return std::nullopt;
        }
        d.hvp = v.boolean;
      } else {
        error = where + ": unknown keyword `" + k +
                ":` (wrt/mode/tol/export/hvp)";
        return std::nullopt;
      }
    }
    out.push_back(std::move(d));
  }
  return out;
}

std::optional<std::vector<std::string>>
readDefParameterNames(const ContractModule &module, StringRef name) {
  Ctx c(module);
  // Walk in id order, matching sorted(ast.n.values(), key=id). If defs share a name, the first one
  // wins; this ordering is contractual.
  for (auto &kv : c.all()) {
    const Node *n = kv.second;
    if (!n || n->kind != "DefNode")
      continue;
    std::string defName;
    if (!ast::getString(*n, "name", defName) || defName != name)
      continue;
    int64_t psId = -1;
    if (!ast::getReference(*n, "parameters", psId) || psId < 0)
      return std::vector<std::string>{};
    const Node *ps = c.node(psId);
    if (!ps)
      return std::vector<std::string>{};
    std::vector<int64_t> reqs;
    ast::getArray(*ps, "requireds", reqs);
    std::vector<std::string> out;
    for (int64_t r : reqs) {
      const Node *rn = c.node(r);
      std::string pname;
      if (rn)
        ast::getString(*rn, "name", pname);
      out.push_back(pname);
    }
    return out;
  }
  return std::nullopt;
}

bool checkGradGate1(const FsGradDecl &g, const FsDecl *fs,
                    const std::vector<std::string> *pnames, GradReject &out) {
  std::string where = ("freestanding_grad_def :" + g.name + " (line " +
                       Twine(g.line) + ")")
                          .str();
  auto refuse = [&](StringRef code, const Twine &msg) {
    out.target = g.name;
    out.line = g.line;
    out.code = code.str();
    out.message = msg.str();
    return false;
  };

  if (!fs)
    return refuse("g01", where + ": there is no `freestanding_def :" + g.name +
                             "` in this file. The gradient is taken of a "
                             "BOUNDARY, not of a method.");
  if (g.mode != "reverse")
    return refuse("g05", where + ": mode: :" + g.mode +
                             " is not implemented; only :reverse. (forward mode "
                             "is P007 Phase 4 -- it is refused rather than "
                             "silently turned into reverse.)");
  if (fs->returns != "f64")
    return refuse("g02", where + ": returns: :" + fs->returns +
                             " -- the loss must be `returns: :f64`. An :f32 "
                             "result rounds the value the derivative is taken "
                             "of (E077 D-4), so the gradient would be the "
                             "gradient of a different function than the one the "
                             "boundary computes.");
  if (g.wrt.empty())
    return refuse("g09", where + ": wrt: is empty. A gradient with respect to "
                                 "nothing is not a gradient.");
  if (!(g.tol > 0.0))
    return refuse("g07", where + ": tol: " + formatG(g.tol) +
                             " -- the G3 threshold must be positive.");
  if (!pnames)
    return refuse("g10", where + ": no `def " + g.name + "` in this file");
  if (pnames->size() != fs->params.size())
    return refuse("g11", where + ": `def " + g.name + "` takes " +
                             Twine(pnames->size()) +
                             " parameters but the boundary declares " +
                             Twine(fs->params.size()));
  for (size_t i = 0; i < fs->params.size(); ++i) {
    const FsParam &p = fs->params[i];
    if (p.kind == FsParam::Kind::Buffer && p.direction != "in")
      return refuse("g06", where + ": parameter `" + (*pnames)[i] +
                               "` is a [:" + p.type + "_buf, :" + p.direction +
                               "] buffer. A differentiated kernel may not write "
                               "memory: the adjoint would have to reverse the "
                               "write, and Enzyme is being told every other "
                               "buffer is `enzyme_const`. Split the write into "
                               "a separate freestanding_def.");
  }
  for (const std::string &w : g.wrt) {
    auto it = llvm::find(*pnames, w);
    if (it == pnames->end()) {
      std::string joined;
      for (size_t i = 0; i < pnames->size(); ++i) {
        if (i)
          joined += ", ";
        joined += (*pnames)[i];
      }
      return refuse("g04", where + ": wrt: :" + w +
                               " is not a parameter of `def " + g.name + "(" +
                               joined + ")`");
    }
    const FsParam &p = fs->params[std::distance(pnames->begin(), it)];
    if (p.kind != FsParam::Kind::Buffer) {
      std::string spelled =
          p.kind == FsParam::Kind::Len ? std::string(":len") : (":" + p.type);
      return refuse("g03", where + ": wrt: :" + w + " is a " + spelled +
                               " at the boundary, not a buffer. v1 "
                               "differentiates with respect to [:f64_buf, :in] "
                               "parameters only -- an active SCALAR's "
                               "derivative comes back through reverse mode's "
                               "return value, which would change the boundary "
                               "signature (see spinel/grad_freestanding.rb).");
    }
    if (p.type != "f64")
      return refuse("g03", where + ": wrt: :" + w + " is a [:" + p.type +
                               "_buf, :in]. Only f64 elements are active: "
                               "Spinel infers in f64 and an f32 element would "
                               "round the shadow (E077 D-4).");
  }
  if (g.hvp && g.wrt.size() != 1)
    return refuse("g12", where + ": hvp: true with " + Twine(g.wrt.size()) +
                             " wrt: parameters. The forward-over-reverse "
                             "product takes its direction along ONE "
                             "[:f64_buf, :in] buffer (E082 fwd1, at the "
                             "freestanding boundary); split the declaration or "
                             "drop hvp:.");
  return true;
}

} // namespace spinel_mlir::freestanding
