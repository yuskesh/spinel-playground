// Collect freestanding_def from ContractModule AST, match def, and walk bodies at D1/D2/B/C. Share
// ScalarAst.h accessors with the scalar importer so missing-field meaning has one source. The
// initial decision deferred a public header until a third consumer appeared.
#include "spinel-mlir/Freestanding/Declaration.h"
#include "spinel-mlir/Core/Intrinsics.h"
#include "spinel-mlir/Support/IntegerWidth.h"

#include "../Frontend/Scalar/ScalarAst.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Support/raw_ostream.h"

#include <map>
#include <set>

using namespace llvm;
using namespace spinel_mlir::contract;
namespace ast = spinel_mlir::scalar::ast;

namespace spinel_mlir::freestanding {
namespace {

class Ctx {
public:
  Ctx(const ContractModule &m, FsDiagnosticFn diag) : diag_(diag) {
    for (const Node &n : m.nodes())
      byId_[n.id] = &n;
  }
  const Node *node(int64_t id) const {
    auto it = byId_.find(id);
    return it == byId_.end() ? nullptr : it->second;
  }
  bool reject(Stage stage, Category category, StringRef subject, int argPos,
              const Twine &detail) {
    Rejection r;
    r.stage = stage;
    r.category = category;
    r.subject = subject.str();
    r.argPos = argPos;
    r.detail = detail.str();
    diag_(r);
    return false;
  }

private:
  FsDiagnosticFn diag_;
  std::map<int64_t, const Node *> byId_;
};

bool symbolValue(const Ctx &c, int64_t id, std::string &out) {
  const Node *n = c.node(id);
  if (!n || (n->kind != "SymbolNode" && n->kind != "StringNode"))
    return false;
  return ast::getString(*n, "value", out) ||
         ast::getString(*n, "unescaped", out);
}

bool isFloatType(StringRef t) { return t == "f32" || t == "f64"; }

std::string joinRefs(ArrayRef<StringRef> set) {
  std::string out;
  for (size_t i = 0; i < set.size(); ++i) {
    if (i) out += " ";
    out += ":" + set[i].str();
  }
  return out;
}

} // namespace

std::optional<std::vector<FsDecl>>
readFreestandingDeclarations(const ContractModule &module,
                             const FreestandingProfile &profile,
                             FsDiagnosticFn diag) {
  Ctx c(module, diag);
  // Entry-source spelling corresponding to frozen self.src, named by b01/b09 diagnostics; take the
  // first source-table entry.
  StringRef entrySrc =
      module.sources().empty() ? StringRef("") : StringRef(module.sources().front().path);
  const Node *root = c.node(module.root());
  if (!root)
    return std::nullopt;
  int64_t stmtsId = -1;
  if (!ast::getReference(*root, "statements", stmtsId))
    return std::nullopt;
  const Node *stmts = c.node(stmtsId);
  if (!stmts)
    return std::nullopt;
  std::vector<int64_t> body;
  ast::getArray(*stmts, "body", body);

  // Collect top-level defs for stages D2 and C.
  std::map<std::string, const Node *> defs;
  for (int64_t id : body) {
    const Node *n = c.node(id);
    if (!n || n->kind != "DefNode")
      continue;
    int64_t recv = -1;
    ast::getReference(*n, "receiver", recv);
    if (recv >= 0)
      continue;
    std::string name;
    if (ast::getString(*n, "name", name))
      defs[name] = n;
  }

// A builtin class reopened or changed at the top level (in this file or a
// file it requires). The declared methods' operators on an Integer or a
// Float lower to the builtin operation, so a reopened `+` would never run
// in the object although Ruby would call it. The CORE route refuses the
// same file (binding-environment); this lane refuses it here, by name.
static const std::set<std::string> kBuiltins = {
    "Integer", "Float", "Numeric", "Comparable", "Kernel", "Object", "BasicObject"};
static const std::set<std::string> kChanges = {
    "prepend", "include", "extend", "class_eval", "class_exec", "module_eval",
    "module_exec", "define_method", "alias_method", "remove_method",
    "undef_method", "send", "public_send", "instance_eval"};
auto builtinNamed = [&](int64_t id) -> std::string {
  const Node *k = id >= 0 ? c.node(id) : nullptr;
  std::string name;
  if (!k || !ast::getString(*k, "name", name) || !kBuiltins.count(name))
    return {};
  if (k->kind == "ConstantReadNode")
    return name;
  int64_t parent = -1;
  if (k->kind == "ConstantPathNode" && !ast::getReference(*k, "parent", parent))
    return name;
  return {};
};
auto where = [&](const Node &n) {
  int64_t line = 0, file = -1;
  ast::getInteger(n, "node_line", line);
  ast::getInteger(n, "node_file", file);
  std::string path = entrySrc.str();
  for (const auto &s : module.sources())
    if (s.id == file) path = s.path;
  return path + ":" + std::to_string(line);
};
for (int64_t id : body) {
  const Node *n = c.node(id);
  if (!n)
    continue;
  std::string cls, form;
  int64_t ref = -1;
  if (n->kind == "ClassNode" || n->kind == "ModuleNode") {
    ast::getReference(*n, "constant_path", ref);
    cls = builtinNamed(ref);
    form = (n->kind == "ClassNode" ? "class " : "module ") + cls;
  } else if (n->kind == "SingletonClassNode") {
    ast::getReference(*n, "expression", ref);
    cls = builtinNamed(ref);
    form = "class << " + cls;
  } else if (n->kind == "CallNode") {
    std::string callee;
    ast::getReference(*n, "receiver", ref);
    if (ast::getString(*n, "name", callee) && kChanges.count(callee)) {
      cls = builtinNamed(ref);
      form = cls + "." + callee;
    }
  }
  if (cls.empty())
    continue;
  c.reject(Stage::D1, Category::ReopenedBuiltin, cls, 0,
           where(*n) + ": `" + form + "` changes the builtin class " + cls +
               " at the top level. A freestanding method's operators on an "
               "Integer or a Float lower to the builtin operation, so the "
               "changed definitions would never run (the CORE route refuses "
               "the same file: binding-environment). Remove it, or write the "
               "operation as a top-level method the declared method calls.");
  return std::nullopt;
}

  std::vector<FsDecl> out;
  // Remember the declaration where alongside each symbol: frozen diagnostics name the declaration
  // that used it first.
  llvm::StringMap<std::string> seenExports;
  for (int64_t id : body) {
    const Node *n = c.node(id);
    if (!n || n->kind != "CallNode")
      continue;
    std::string callee;
    if (!ast::getString(*n, "name", callee) || callee != "freestanding_def")
      continue;
    int64_t recv = -1;
    ast::getReference(*n, "receiver", recv);
    if (recv >= 0)
      continue;

    int64_t line = 0;
    ast::getInteger(*n, "node_line", line);
    int64_t argsId = -1;
    ast::getReference(*n, "arguments", argsId);
    const Node *argsN = argsId >= 0 ? c.node(argsId) : nullptr;
    std::vector<int64_t> args;
    if (argsN)
      ast::getArray(*argsN, "arguments", args);
    if (args.empty()) {
      c.reject(Stage::D1, Category::BadBoundaryType, "freestanding_def", 0,
               "freestanding_def (line " + Twine(line) +
                   "): missing the method name");
      return std::nullopt;
    }
    FsDecl d;
    d.line = line;
    if (!symbolValue(c, args[0], d.name)) {
      c.reject(Stage::D1, Category::BadBoundaryType, "freestanding_def", 0,
               "freestanding_def (line " + Twine(line) +
                   ") first argument is not a Symbol");
      return std::nullopt;
    }
    std::string where = ("freestanding_def :" + d.name + " (line " +
                         Twine(line) + ")").str();

    // Collect keywords; anything outside the closed set is a D1 refusal.
    std::map<std::string, int64_t> kw;
    for (size_t i = 1; i < args.size(); ++i) {
      const Node *k = c.node(args[i]);
      if (!k || k->kind != "KeywordHashNode") {
        c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
                 // Preserve frozen wording, which omits bounds: even though kKnownKw admits five
                 // keys including it. This list was already stale in Python; the port deliberately
                 // copied it and recorded that limitation.
                 where + ": positional argument " +
                     (k ? StringRef(k->kind) : StringRef("")) +
                     " is not allowed; use "
                     "params:/returns:/export:/overflow:");
        return std::nullopt;
      }
      std::vector<int64_t> elems;
      ast::getArray(*k, "elements", elems);
      for (int64_t e : elems) {
        const Node *assoc = c.node(e);
        if (!assoc)
          continue;
        int64_t keyId = -1, valId = -1;
        ast::getReference(*assoc, "key", keyId);
        ast::getReference(*assoc, "value", valId);
        std::string keyName;
        if (symbolValue(c, keyId, keyName))
          kw[keyName] = valId;
      }
    }
    static const StringRef kKnownKw[] = {"params", "returns", "export",
                                         "overflow", "bounds"};
    static_assert(sizeof(kKnownKw) / sizeof(StringRef) == 5, "");
    for (auto &kv : kw)
      if (!llvm::is_contained(kKnownKw, StringRef(kv.first))) {
        c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
                 // Frozen wording verbatim, including (s) and the list.
                 where + ": unknown keyword(s) " + kv.first +
                     " (params:, returns:, export:, overflow:, bounds:)");
        return std::nullopt;
      }

    // ---- params ----
    auto it = kw.find("params");
    const Node *paramsN = it == kw.end() ? nullptr : c.node(it->second);
    if (!paramsN || paramsN->kind != "ArrayNode") {
      c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
               where + ": params: must be an Array of boundary types");
      return std::nullopt;
    }
    std::vector<int64_t> pes;
    ast::getArray(*paramsN, "elements", pes);
    int pos = 0;
    for (int64_t pe : pes) {
      ++pos;
      const Node *pn = c.node(pe);
      FsParam param;
      if (pn && pn->kind == "ArrayNode") {
        std::vector<int64_t> two;
        ast::getArray(*pn, "elements", two);
        if (two.size() != 2) {
          c.reject(Stage::D1, Category::BufferElemMismatch, d.name, pos,
                   where + " params:: a buffer parameter is written "
                           "[:<elem>_buf, :<dir>] -- two entries -- not " +
                       Twine(two.size()));
          return std::nullopt;
        }
        std::string tag, dir;
        symbolValue(c, two[0], tag);
        symbolValue(c, two[1], dir);
        StringRef t(tag);
        if (!t.ends_with("_buf") ||
            !llvm::is_contained(bufferElementTypes(), t.drop_back(4))) {
          c.reject(Stage::D1, Category::BufferElemMismatch, d.name, pos,
                   where + " params:: :" + tag +
                       " is not a buffer element type. They are " +
                       joinRefs(bufferElementTypes()));
          return std::nullopt;
        }
        if (!llvm::is_contained(bufferDirections(), StringRef(dir))) {
          c.reject(Stage::D1, Category::BufferDirectionViolation, d.name, pos,
                   where + " params:: :" + dir +
                       " is not a buffer direction. They are " +
                       joinRefs(bufferDirections()));
          return std::nullopt;
        }
        param.kind = FsParam::Kind::Buffer;
        param.type = t.drop_back(4).str();
        param.direction = dir;
      } else {
        std::string s;
        if (!symbolValue(c, pe, s)) {
          c.reject(Stage::D1, Category::BadBoundaryType, d.name, pos,
                   where + " params:: entry is neither a Symbol nor an Array");
          return std::nullopt;
        }
        if (s == "len") {
          param.kind = FsParam::Kind::Len;
          param.type = "i32";
        } else if (!llvm::is_contained(boundaryScalarTypes(), StringRef(s))) {
          c.reject(Stage::D1, Category::BadBoundaryType, d.name, pos,
                   where + " params:: :" + s +
                       " is not a freestanding scalar boundary type. The "
                       "scalars are " + joinRefs(boundaryScalarTypes()));
          return std::nullopt;
        } else {
          param.kind = FsParam::Kind::Scalar;
          param.type = s;
        }
      }
      d.params.push_back(param);
    }
    // Length governance: apply the same rules in the same order as for externs.
    for (size_t i = 0; i < d.params.size(); ++i) {
      if (d.params[i].kind != FsParam::Kind::Len)
        continue;
      if (i == 0 || d.params[i - 1].kind != FsParam::Kind::Buffer) {
        c.reject(Stage::D1, Category::BufferLenGovernance, d.name,
                 static_cast<int>(i + 1),
                 where + ": `:len` must come directly after a buffer parameter "
                         "-- it names THAT buffer's length");
        return std::nullopt;
      }
      size_t j = i;
      while (j > 0 && d.params[j - 1].kind == FsParam::Kind::Buffer &&
             d.params[j - 1].lenIndex < 0) {
        d.params[j - 1].lenIndex = static_cast<int>(i);
        --j;
      }
      d.params[i].bufIndex = static_cast<int>(j);
    }

    // ---- returns ----
    it = kw.find("returns");
    if (it == kw.end()) {
      c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
               where + ": returns: is required -- a freestanding boundary has "
                       "no `void` (the integer subset's methods all yield a "
                       "value)");
      return std::nullopt;
    }
    const Node *rn = c.node(it->second);
    if (rn && rn->kind == "ArrayNode") {
      c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
               where + ": a buffer cannot be RETURNED. The caller owns the "
                       "memory");
      return std::nullopt;
    }
    if (!symbolValue(c, it->second, d.returns) ||
        !llvm::is_contained(boundaryScalarTypes(), StringRef(d.returns))) {
      c.reject(Stage::D1, Category::BadBoundaryType, d.name, 0,
               where + " returns:: :" + d.returns +
                   " is not a freestanding scalar boundary type. The scalars "
                   "are " + joinRefs(boundaryScalarTypes()));
      return std::nullopt;
    }

    // ---- export / overflow / bounds ----
    d.exportSymbol = "spinel_" + d.name;
    it = kw.find("export");
    if (it != kw.end()) {
      std::string ex;
      if (symbolValue(c, it->second, ex)) {
        // export: becomes a linked C symbol and must be a C identifier. Share isCIdentifier with
        // extern symbols/trap hooks. Explicit empty export is an error, not a request for default
        // spinel_<name>; the first implementation excluded empty from checking and silently
        // defaulted it, unlike frozen Python.
        if (!isCIdentifier(ex)) {
          c.reject(Stage::D1, Category::BadExportSymbol, d.name, 0,
                   // Frozen wording includes one colon.
                   where + ": export: '" + ex + "' is not a C identifier");
          return std::nullopt;
        }
        d.exportSymbol = ex;
      }
    }
    d.overflow = profile.overflow().str();
    it = kw.find("overflow");
    if (it != kw.end()) {
      std::string ov;
      symbolValue(c, it->second, ov);
      if (ov == "raise") {
        c.reject(Stage::D1, Category::AbiWidthMismatch, d.name, 0,
                 where + ": overflow: :raise is not available on a "
                         "freestanding target (P003 decision record D-2: "
                         "sp_raise_cls needs a setjmp stack and the string "
                         "heap). The policies are :trap and :wrap.");
        return std::nullopt;
      }
      if (!llvm::is_contained(overflowModes(), StringRef(ov))) {
        c.reject(Stage::D1, Category::AbiWidthMismatch, d.name, 0,
                 where + ": overflow: :" + ov + " is not one of " +
                     joinRefs(overflowModes()));
        return std::nullopt;
      }
      d.overflow = ov;
    }
    d.bounds = "trap";
    it = kw.find("bounds");
    if (it != kw.end()) {
      std::string bd;
      symbolValue(c, it->second, bd);
      if (!llvm::is_contained(boundsModes(), StringRef(bd))) {
        c.reject(Stage::D1, Category::BufferLenGovernance, d.name, 0,
                 where + ": bounds: :" + bd + " is not one of " +
                     joinRefs(boundsModes()));
        return std::nullopt;
      }
      if (!llvm::any_of(d.params, [](const FsParam &p) {
            return p.kind == FsParam::Kind::Buffer;
          })) {
        c.reject(Stage::D1, Category::BufferLenGovernance, d.name, 0,
                 where + ": bounds: only means something for a declaration "
                         "that has a buffer parameter");
        return std::nullopt;
      }
      d.bounds = bd;
    }
    // Export symbols must not collide with profile extern symbols: that would define and import the
    // same symbol, leaving link selection outside the kernel contract. Preserve frozen wording.
    for (const FsExtern &e : profile.externs()) {
      if (e.symbol != d.exportSymbol)
        continue;
      c.reject(Stage::D1, Category::UndefAllowlistViolation, d.exportSymbol, 0,
               "platform extern symbol '" + e.symbol +
                   "' is also the export symbol of freestanding_def :" + d.name +
                   " (line " + Twine(d.line) +
                   "). The kernel cannot both define and import one symbol "
                   "(E081)");
      return std::nullopt;
    }
    {
      auto seen = seenExports.find(d.exportSymbol);
      if (seen != seenExports.end()) {
        c.reject(Stage::D1, Category::UndefAllowlistViolation, d.exportSymbol,
                 0,
                 where + ": export symbol '" + d.exportSymbol +
                     "' is already used by " + seen->second);
        return std::nullopt;
      }
      seenExports[d.exportSymbol] = where;
    }

    // D2: declaration/def argument counts.
    auto def = defs.find(d.name);
    if (def == defs.end()) {
      // Frozen Generator.want wording has no where prefix and names the file.
      c.reject(Stage::D2, Category::AbiWidthMismatch, d.name, 0,
               "no top-level method '" + d.name + "' in " + entrySrc);
      return std::nullopt;
    }
    int64_t paramsId = -1;
    size_t defArity = 0;
    if (ast::getReference(*def->second, "parameters", paramsId) &&
        paramsId >= 0) {
      if (const Node *pn = c.node(paramsId)) {
        std::vector<int64_t> req;
        ast::getArray(*pn, "requireds", req);
        defArity = req.size();
      }
    }
    if (defArity != d.params.size()) {
      c.reject(Stage::D2, Category::AbiWidthMismatch, d.name, 0,
               where + ": the declaration says " + Twine(d.params.size()) +
                   " parameter(s) but `def " + d.name + "` takes " +
                   Twine(defArity) +
                   ". The declaration is the boundary contract; make them "
                   "agree. (E077: a buffer and its `:len` are TWO entries and "
                   "TWO Ruby parameters -- `params: [[:u8_buf, :in], :len]` "
                   "needs `def " + d.name + "(buf, n)`.)");
      return std::nullopt;
    }
    out.push_back(std::move(d));
  }

  if (out.empty()) {
    Rejection r;
    r.stage = Stage::D1;
    r.category = Category::BadBoundaryType;
    r.subject = "freestanding_def";
    // Frozen wording includes both example lines.
    r.detail =
        ("no freestanding_def declaration in " + entrySrc +
         ". --freestanding compiles DECLARED boundaries, not whatever methods "
         "happen to be in the file: the boundary type of every argument and "
         "the return value is a fact the declaration states and inference "
         "cannot (P003 s'\u30ec\u30d3\u30e5\u30fc\u9069\u5408-2'). Add e.g.\n"
         "    require_relative \"spinel/freestanding\"\n"
         "    freestanding_def :add, params: [:i32, :i32], returns: :i32").str();
    diag(r);
    return std::nullopt;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Stages B / C
// ---------------------------------------------------------------------------
namespace {

// Buffer capabilities: in reads, out writes, inout does both. Require callee want capabilities to
// be included in caller got. bufferDirections owns the three words; D1/P2 already refused others.
bool directionLicenses(StringRef got, StringRef want) {
  auto reads = [](StringRef d) { return d == "in" || d == "inout"; };
  auto writes = [](StringRef d) { return d == "out" || d == "inout"; };
  if (reads(want) && !reads(got))
    return false;
  if (writes(want) && !writes(got))
    return false;
  return true;
}

struct BodyScan {
  Ctx &c;
  const FreestandingProfile &profile;
  const FsDecl &decl;
  const std::map<std::string, FsParam> &params;
  // Name to one-based declaration position. Deriving position from type/direction incorrectly names
  // the first of two same-typed buffers.
  const std::map<std::string, int> &paramPos;
  const StringSet<> &topLevel;
  unsigned integerBits; ///< the body's Integer width, for the 64-bit forms
  bool ok = true;

  const Node *n(int64_t id) const { return c.node(id); }

  /// Decision 0042 stage 4: a CORE intrinsic (Core/Intrinsics.h), recognised
  /// here as on the other CORE routes. False after a refusal.
  bool checkIntrinsic(const Node &call, const spinel_mlir::core::CoreIntrinsic &in,
                      StringRef name, int64_t recv) {
    auto refuse = [&](Category cat, const Twine &detail) {
      ok = c.reject(Stage::C, cat, name, 0, decl.name + ": " + detail);
      return false;
    };
    if (recv >= 0)
      return refuse(Category::UnsupportedIntrinsicCall,
                    "`" + name + "` is a CORE intrinsic and is called with no receiver");
    if (topLevel.contains(name))
      return refuse(Category::ConflictingIntrinsic,
                    "`" + name + "` is defined in this source and is also the CORE intrinsic");
    int64_t blockId = -1;
    if (ast::getReference(call, "block", blockId) && blockId >= 0)
      return refuse(Category::UnsupportedIntrinsicCall,
                    "`" + name + "` is a CORE intrinsic and takes no block");
    int64_t argsId = -1;
    ast::getReference(call, "arguments", argsId);
    std::vector<int64_t> args;
    if (argsId >= 0)
      if (const Node *an = n(argsId))
        ast::getArray(*an, "arguments", args);
    for (int64_t id : args)
      if (const Node *a = n(id); a && a->kind != "IntegerNode" &&
          (a->kind == "SplatNode" || a->kind == "KeywordHashNode" ||
           a->kind == "BlockArgumentNode"))
        return refuse(Category::UnsupportedIntrinsicCall,
                      "`" + name + "` takes plain positional arguments");
    if (args.size() != in.arity)
      return refuse(Category::UnsupportedIntrinsicCall,
                    "`" + name + "` takes " + Twine(in.arity) + " argument(s), " +
                        Twine(args.size()) + " given");
    if (in.wide && integerBits == 32)
      return refuse(Category::UnsupportedIntrinsicCall,
                    "`" + name + "` computes on 64-bit words and this body is 32 bits; "
                    "a 64-bit form is refused on a 32-bit body, as int64 is "
                    "(decision 0019's revision)");
    if (in.literal) {
      const Node *lit = n(args[0]);
      int64_t value = 0;
      std::string big;
      std::optional<int64_t> v;
      if (lit && lit->kind == "IntegerNode" && ast::getInteger(*lit, "value", value)) {
        const bool hasBig = ast::getString(*lit, "bigval", big);
        v = spinel_mlir::core::u32LiteralValue(value, hasBig ? &big : nullptr);
      }
      if (!v)
        return refuse(Category::UnsupportedIntrinsicCall,
                      "core_u32 takes an Integer literal in 0..4294967295");
    }
    return true;
  }

  void walk(int64_t id) {
    if (!ok || id < 0)
      return;
    const Node *node = n(id);
    if (!node)
      return;

    // Stage B refuses buffer/:len parameter rebinding: caller owns the address and bounds checks
    // depend on the original length. Rebinding either invalidates the contract. Preserve frozen
    // wording.
    if (node->kind == "LocalVariableWriteNode" ||
        node->kind == "LocalVariableOperatorWriteNode" ||
        node->kind == "LocalVariableTargetNode") {
      std::string base;
      if (ast::getString(*node, "name", base)) {
        auto p = params.find(base);
        if (p != params.end() && (p->second.kind == FsParam::Kind::Buffer ||
                                  p->second.kind == FsParam::Kind::Len)) {
          const bool isBuf = p->second.kind == FsParam::Kind::Buffer;
          int idx = 0;
          if (auto pos = paramPos.find(base); pos != paramPos.end())
            idx = pos->second;
          ok = c.reject(Stage::B, Category::BufferLenGovernance, decl.name, idx,
                        decl.name + ": `" + base + "` is a " +
                            (isBuf ? "buffer" : "length") +
                            " parameter and cannot be reassigned (" +
                            (isBuf ? "its address is the caller's"
                                   : "the bounds check compares against it") +
                            ")");
          return;
        }
      }
    }

    if (node->kind == "CallNode") {
      std::string name;
      ast::getString(*node, "name", name);
      int64_t recv = -1;
      ast::getReference(*node, "receiver", recv);

      // Stage B: stores to :in buffers.
      if (name == "[]=" && recv >= 0) {
        const Node *r = n(recv);
        std::string base;
        if (r && r->kind == "LocalVariableReadNode" &&
            ast::getString(*r, "name", base)) {
          auto p = params.find(base);
          if (p != params.end() && p->second.kind == FsParam::Kind::Buffer &&
              p->second.direction == "in") {
            // Use the one-based declaration position by unique name. Earlier type/direction reverse
            // lookup reported the first buffer for writes to a second identical one.
            int idx = 0;
            if (auto pos = paramPos.find(base); pos != paramPos.end())
              idx = pos->second;
            ok = c.reject(Stage::B, Category::BufferDirectionViolation,
                          decl.name, idx,
                          decl.name + ": `" + base +
                              "[i] = ...` WRITES a buffer declared `:in`. The "
                              "caller owns it and said it was read-only");
            return;
          }
        }
      }

      // Stage B: reads from :out buffers. Caller contents are unspecified by this direction
      // contract, so reading is outside it. Preserve frozen wording.
      if (name == "[]" && recv >= 0) {
        const Node *r = n(recv);
        std::string base;
        if (r && r->kind == "LocalVariableReadNode" &&
            ast::getString(*r, "name", base)) {
          auto p = params.find(base);
          if (p != params.end() && p->second.kind == FsParam::Kind::Buffer &&
              p->second.direction == "out") {
            int idx = 0;
            if (auto pos = paramPos.find(base); pos != paramPos.end())
              idx = pos->second;
            ok = c.reject(Stage::B, Category::BufferDirectionViolation,
                          decl.name, idx,
                          decl.name + ": `" + base +
                              "[i]` READS a buffer declared `:out`. The "
                              "direction is part of the boundary contract");
            return;
          }
        }
      }

      // Decision 0042 stage 4: a CORE intrinsic, with or without a receiver
      // (a receiver is refused by name). Its literal argument is not walked.
      if (const auto *in = spinel_mlir::core::coreIntrinsic(name);
          in && !profile.findExtern(name)) {
        if (!checkIntrinsic(*node, *in, name, recv))
          return;
        if (in->literal)
          return;
      } else
      // Stage C: receiverless calls.
      if (recv < 0 && !name.empty() && name != "[]" && name != "[]=") {
        const FsExtern *ext = profile.findExtern(name);
        if (ext) {
          checkExternCall(*node, *ext);
          if (!ok)
            return;
        } else if (!topLevel.contains(name) && !isOperatorName(name)) {
          ok = c.reject(Stage::C, Category::UndeclaredPlatformExtern, name, 0,
                        decl.name + ": call to '" + name +
                            "', which is not a top-level method in this file "
                            "and is not declared by the profile");
          return;
        }
      }
    }

    for (const AstField &f : node->fields) {
      if (f.kind == AstField::Kind::Reference) {
        int64_t ref = std::get<int64_t>(f.value);
        if (ref >= 0)
          walk(ref);
      } else if (f.kind == AstField::Kind::Array) {
        for (int64_t child : std::get<std::vector<int64_t>>(f.value))
          walk(child);
      }
    }
  }

  static bool isOperatorName(StringRef n) {
    static const StringRef ops[] = {"+", "-", "*", "/", "%", "<", ">", "<=",
                                    ">=", "==", "!=", "-@", "+@", "<<", ">>",
                                    "&", "|", "^", "~"};
    return llvm::is_contained(ops, n);
  }

  void checkExternCall(const Node &call, const FsExtern &ext) {
    int64_t argsId = -1;
    ast::getReference(call, "arguments", argsId);
    std::vector<int64_t> args;
    if (argsId >= 0)
      if (const Node *an = n(argsId))
        ast::getArray(*an, "arguments", args);
    if (args.size() != ext.params.size()) {
      ok = c.reject(Stage::C, Category::ExternSignatureMismatch, ext.name, 0,
                    decl.name + ": call to platform extern '" + ext.name +
                        "' with " + Twine(args.size()) +
                        " argument(s); the profile declares " +
                        Twine(ext.params.size()));
      return;
    }
    for (size_t i = 0; i < args.size(); ++i) {
      const FsParam &want = ext.params[i];
      const Node *a = n(args[i]);
      if (!a)
        continue;
      std::string base;
      const FsParam *got = nullptr;
      if (a->kind == "LocalVariableReadNode" &&
          ast::getString(*a, "name", base)) {
        auto p = params.find(base);
        if (p != params.end())
          got = &p->second;
      }
      if (!got)
        continue; // Arguments not typed by declarations are outside the initial check scope.
      int pos = static_cast<int>(i + 1);
      if (want.kind == FsParam::Kind::Buffer &&
          got->kind != FsParam::Kind::Buffer) {
        ok = c.reject(Stage::C, Category::ExternSignatureMismatch, ext.name,
                      pos,
                      decl.name + ": argument " + Twine(pos) +
                          " of platform extern '" + ext.name +
                          "' is a scalar, but the profile declares a buffer");
        return;
      }
      if (want.kind != FsParam::Kind::Buffer &&
          got->kind == FsParam::Kind::Buffer) {
        ok = c.reject(Stage::C, Category::ExternSignatureMismatch, ext.name,
                      pos,
                      decl.name + ": passing buffer `" + base +
                          "` to platform extern '" + ext.name +
                          "' where the profile declares :" + want.type);
        return;
      }
      if (want.kind == FsParam::Kind::Buffer &&
          got->kind == FsParam::Kind::Buffer) {
        if (want.type != got->type) {
          ok = c.reject(Stage::C, Category::BufferElemMismatch, ext.name, pos,
                        decl.name + ": argument " + Twine(pos) +
                            " of platform extern '" + ext.name +
                            "' is a " + got->type + " buffer, but the profile "
                            "declares " + want.type);
          return;
        }
        // Direction matching is capability inclusion: extern-required read/write rights must be
        // permitted by the kernel declaration. The pointer carries that contract across the
        // boundary; writes require caller write permission. The earlier element-type-only check
        // missed this compile-time half.
        if (!directionLicenses(got->direction, want.direction)) {
          ok = c.reject(Stage::C, Category::BufferDirectionViolation, ext.name,
                        pos,
                        decl.name + ": argument " + Twine(pos) +
                            " of platform extern '" + ext.name + "' passes a [:" +
                            got->type + "_buf, :" + got->direction +
                            "], where the profile declares [:" + want.type +
                            "_buf, :" + want.direction + "]");
          return;
        }
        continue;
      }
      if (want.kind == FsParam::Kind::Scalar &&
          isFloatType(want.type) != isFloatType(got->type)) {
        ok = c.reject(Stage::C, Category::ExternSignatureMismatch, ext.name,
                      pos,
                      decl.name + ": argument " + Twine(pos) +
                          " of platform extern '" + ext.name + "' is a " +
                          (isFloatType(got->type) ? "Float" : "Integer") +
                          ", but the profile declares :" + want.type);
        return;
      }
    }
  }
};

} // namespace

bool checkFreestandingBodies(const ContractModule &module,
                             const FreestandingProfile &profile,
                             ArrayRef<FsDecl> decls, FsDiagnosticFn diag,
                             unsigned integerBits) {
  Ctx c(module, diag);
  StringSet<> topLevel;
  std::map<std::string, const Node *> defs;
  const Node *root = c.node(module.root());
  if (!root)
    return true;
  int64_t stmtsId = -1;
  ast::getReference(*root, "statements", stmtsId);
  const Node *stmts = c.node(stmtsId);
  if (!stmts)
    return true;
  std::vector<int64_t> body;
  ast::getArray(*stmts, "body", body);
  for (int64_t id : body) {
    const Node *n = c.node(id);
    if (!n || n->kind != "DefNode")
      continue;
    std::string name;
    if (ast::getString(*n, "name", name)) {
      topLevel.insert(name);
      defs[name] = n;
      // Decision 0042 stage 4, a change to 0022's rule here: a top-level
      // definition of an intrinsic's name is refused wherever it is, called
      // or not, because the prelude the reader's copy gets defines it too.
      if (spinel_mlir::core::coreIntrinsic(name))
        return c.reject(Stage::C, Category::ConflictingIntrinsic, name, 0,
                        "`" + name + "` is defined in this source and is also the "
                        "CORE intrinsic; the intrinsics' prelude defines it for "
                        "the analysis, so the two cannot both be meant");
    }
  }
  const unsigned bits =
      integerBits ? integerBits : spinel_mlir::profileIntegerBits(profile.intWidth());

  for (const FsDecl &d : decls) {
    auto def = defs.find(d.name);
    if (def == defs.end())
      continue;
    // Associate declaration positions with def argument names; D2 already checked their counts.
    std::map<std::string, FsParam> params;
    std::map<std::string, int> paramPos;
    int64_t paramsId = -1;
    if (ast::getReference(*def->second, "parameters", paramsId) &&
        paramsId >= 0) {
      if (const Node *pn = c.node(paramsId)) {
        std::vector<int64_t> req;
        ast::getArray(*pn, "requireds", req);
        for (size_t i = 0; i < req.size() && i < d.params.size(); ++i) {
          const Node *rp = c.node(req[i]);
          std::string nm;
          if (rp && ast::getString(*rp, "name", nm)) {
            params[nm] = d.params[i];
            paramPos[nm] = static_cast<int>(i + 1);
          }
        }
      }
    }
    int64_t bodyId = -1;
    ast::getReference(*def->second, "body", bodyId);
    BodyScan scan{c, profile, d, params, paramPos, topLevel, bits};
    scan.walk(bodyId);
    if (!scan.ok)
      return false;
  }
  return true;
}

} // namespace spinel_mlir::freestanding
