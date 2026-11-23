// Parse typedump faces individually. ReaderInternal.h defines value/diagnostic
// rules. Historically these parsers refused only face-local defects; sealing,
// cross-table references and public readContract came at the next checkpoint.
// Never default invalid input: report the first unreadable, duplicate or
// missing value as <face>:<line>: <category>: <detail> and return false.
#include "ReaderInternal.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/Twine.h"

#include <algorithm>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <tuple>
#include <utility>

using namespace llvm;

namespace spinel_mlir::contract::internal {
namespace {

bool fail(ContractDiagnosticFn diag, StringRef face, int64_t line,
          StringRef category, const Twine &detail) {
  diag((face + ":" + Twine(line) + ": " + category + ": " + detail).str());
  return false;
}

enum class IntErr { Ok, Bad, Overflow };

// Strict int64: accept only -?[0-9]+, not leading + or whitespace.
IntErr parseI64(StringRef s, int64_t &v) {
  StringRef digits = s;
  digits.consume_front("-");
  if (digits.empty() ||
      !llvm::all_of(digits, [](char c) { return c >= '0' && c <= '9'; }))
    return IntErr::Bad;
  return s.getAsInteger(10, v) ? IntErr::Overflow : IntErr::Ok;
}

// Decode producer ast_esc %XX escapes; return false unless percent is followed by two hexadecimal
// digits.
bool decodeEscapes(StringRef in, std::string &out) {
  out.clear();
  out.reserve(in.size());
  for (size_t i = 0; i < in.size(); ++i) {
    char c = in[i];
    if (c != '%') {
      out += c;
      continue;
    }
    if (i + 2 >= in.size()) // Percent requires two following hex digits.
      return false;
    unsigned hi = llvm::hexDigitValue(in[i + 1]);
    unsigned lo = llvm::hexDigitValue(in[i + 2]);
    if (hi == ~0U || lo == ~0U)
      return false;
    out += static_cast<char>((hi << 4) | lo);
    i += 2;
  }
  return true;
}

// Iterate lines without treating the final trailing newline as a row; stop when cb returns false.
template <typename Fn> bool forEachLine(StringRef text, Fn cb) {
  int64_t lineno = 0;
  while (!text.empty()) {
    auto split = text.split('\n');
    ++lineno;
    if (!cb(lineno, split.first))
      return false;
    text = split.second;
  }
  return true;
}

// Split on a single space with KeepEmpty and require exact arity. The caller decides whether the
// last field may be empty.
void splitSpaces(StringRef line, SmallVectorImpl<StringRef> &out) {
  out.clear();
  line.split(out, ' ', /*MaxSplit=*/-1, /*KeepEmpty=*/true);
}

} // namespace

//===----------------------------------------------------------------------===//
// ast face
//===----------------------------------------------------------------------===//
bool parseAstFace(StringRef text, ParsedAst &out, ContractDiagnosticFn diag) {
  StringRef face = "ast";
  bool sawSource = false, sawRoot = false;
  std::set<int64_t> nodeIds;
  std::set<int64_t> fileIds; // FILE ids referenced by node_file must be unique on input.
  std::set<std::pair<int64_t, std::string>> fieldKeys;
  auto findNode = [&](int64_t id) -> Node * {
    for (auto &n : out.nodes)
      if (n.id == id)
        return &n;
    return nullptr;
  };

  bool okAll = forEachLine(text, [&](int64_t ln, StringRef line) {
    SmallVector<StringRef, 8> t;
    splitSpaces(line, t);
    StringRef tag = t.empty() ? StringRef() : t[0];

    if (tag == "SOURCE_FILE") {
      if (t.size() != 2)
        return fail(diag, face, ln, "bad-field-count",
                    "SOURCE_FILE takes 1 field");
      if (sawSource)
        return fail(diag, face, ln, "duplicate-source-file", line);
      if (!decodeEscapes(t[1], out.sourceFile))
        return fail(diag, face, ln, "malformed-escape", t[1]);
      sawSource = true;
      return true;
    }
    if (tag == "FILE") {
      if (t.size() != 3 || t[1].empty())
        return fail(diag, face, ln, "bad-field-count", "FILE takes 2 fields");
      int64_t id;
      switch (parseI64(t[1], id)) {
      case IntErr::Bad:
        return fail(diag, face, ln, "bad-integer", t[1]);
      case IntErr::Overflow:
        return fail(diag, face, ln, "integer-overflow", t[1]);
      case IntErr::Ok:
        break;
      }
      if (id < 0)
        return fail(diag, face, ln, "negative-value", "FILE id " + t[1]);
      if (!fileIds.insert(id).second)
        return fail(diag, face, ln, "duplicate-file-id", "FILE id " + t[1]);
      Source s;
      s.id = id;
      if (!decodeEscapes(t[2], s.path))
        return fail(diag, face, ln, "malformed-escape", t[2]);
      out.files.push_back(std::move(s));
      return true;
    }
    if (tag == "ROOT") {
      if (t.size() != 2 || t[1].empty())
        return fail(diag, face, ln, "bad-field-count", "ROOT takes 1 field");
      if (sawRoot)
        return fail(diag, face, ln, "duplicate-root", line);
      int64_t id;
      switch (parseI64(t[1], id)) {
      case IntErr::Bad:
        return fail(diag, face, ln, "bad-integer", t[1]);
      case IntErr::Overflow:
        return fail(diag, face, ln, "integer-overflow", t[1]);
      case IntErr::Ok:
        break;
      }
      if (id < 0)
        return fail(diag, face, ln, "negative-value", "ROOT " + t[1]);
      out.root = id;
      out.rootLine = ln;
      sawRoot = true;
      return true;
    }
    if (tag == "N") {
      if (t.size() != 3 || t[1].empty() || t[2].empty())
        return fail(diag, face, ln, "bad-field-count", "N takes 2 fields");
      int64_t id;
      switch (parseI64(t[1], id)) {
      case IntErr::Bad:
        return fail(diag, face, ln, "bad-integer", t[1]);
      case IntErr::Overflow:
        return fail(diag, face, ln, "integer-overflow", t[1]);
      case IntErr::Ok:
        break;
      }
      if (id < 0)
        return fail(diag, face, ln, "negative-value", "node id " + t[1]);
      if (!nodeIds.insert(id).second)
        return fail(diag, face, ln, "duplicate-node", "node id " + t[1]);
      Node n;
      n.id = id;
      n.kind = t[2].str();
      out.nodes.push_back(std::move(n));
      return true;
    }
    if (tag == "S" || tag == "I" || tag == "F" || tag == "R" || tag == "A") {
      // Format: <tag> <id> <key> <payload>. Escaped payload has no raw spaces, so five or more
      // tokens means excess columns. Only S/A may have empty payload.
      if (t.size() != 4 || t[1].empty() || t[2].empty())
        return fail(diag, face, ln, "bad-field-count",
                    tag + " takes 3 fields");
      if (t[3].empty() && tag != "S" && tag != "A")
        return fail(diag, face, ln, "bad-field-count",
                    tag + " needs a payload");
      int64_t id;
      switch (parseI64(t[1], id)) {
      case IntErr::Bad:
        return fail(diag, face, ln, "bad-integer", t[1]);
      case IntErr::Overflow:
        return fail(diag, face, ln, "integer-overflow", t[1]);
      case IntErr::Ok:
        break;
      }
      Node *n = findNode(id);
      if (!n)
        return fail(diag, face, ln, "field-before-node",
                    tag + " for undeclared node " + t[1]);
      if (!fieldKeys.insert({id, t[2].str()}).second)
        return fail(diag, face, ln, "duplicate-field-key",
                    "node " + t[1] + " key '" + t[2] + "'");
      AstField f;
      f.key = t[2].str();
      if (tag == "S") {
        std::string v;
        if (!decodeEscapes(t[3], v))
          return fail(diag, face, ln, "malformed-escape", t[3]);
        f.kind = AstField::Kind::String;
        f.value = std::move(v);
      } else if (tag == "I") {
        int64_t v;
        switch (parseI64(t[3], v)) {
        case IntErr::Bad:
          return fail(diag, face, ln, "bad-integer", t[3]);
        case IntErr::Overflow:
          return fail(diag, face, ln, "integer-overflow", t[3]);
        case IntErr::Ok:
          break;
        }
        f.kind = AstField::Kind::Integer;
        f.value = v;
      } else if (tag == "F") {
        // Preserve raw spelling rather than converting to double.
        f.kind = AstField::Kind::FloatSpelling;
        f.value = t[3].str();
      } else if (tag == "R") {
        int64_t v;
        switch (parseI64(t[3], v)) {
        case IntErr::Bad:
          return fail(diag, face, ln, "bad-integer", t[3]);
        case IntErr::Overflow:
          return fail(diag, face, ln, "integer-overflow", t[3]);
        case IntErr::Ok:
          break;
        }
        if (v < -1)
          return fail(diag, face, ln, "negative-value",
                      "R " + t[3] + " (only -1 means no reference)");
        f.kind = AstField::Kind::Reference;
        f.value = v;
      } else { // A
        std::vector<int64_t> ids;
        if (!t[3].empty()) {
          SmallVector<StringRef, 8> elems;
          t[3].split(elems, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/true);
          for (StringRef e : elems) {
            if (e.empty())
              return fail(diag, face, ln, "bad-field-count",
                          "empty array element");
            int64_t v;
            switch (parseI64(e, v)) {
            case IntErr::Bad:
              return fail(diag, face, ln, "bad-integer", e);
            case IntErr::Overflow:
              return fail(diag, face, ln, "integer-overflow", e);
            case IntErr::Ok:
              break;
            }
            if (v < 0)
              return fail(diag, face, ln, "negative-value", "array element " + e);
            ids.push_back(v);
          }
        }
        f.kind = AstField::Kind::Array;
        f.value = std::move(ids);
      }
      out.fieldLines.push_back({id, t[2].str(), ln});
      // Capture producer field order before canonicalization: the following llvm::sort reorders by
      // key.
      f.producerOrder = static_cast<unsigned>(n->fields.size());
      n->fields.push_back(std::move(f));
      return true;
    }
    if (line.empty())
      return fail(diag, face, ln, "bad-field-count", "empty line");
    return fail(diag, face, ln, "unknown-record-tag", "'" + tag + "'");
  });
  if (!okAll)
    return false;
  if (!sawSource)
    return fail(diag, face, 0, "missing-source-file", "no SOURCE_FILE record");
  if (!sawRoot)
    return fail(diag, face, 0, "missing-root", "no ROOT record");
  return true;
}

// Shared parsing for the three TSV faces.
namespace {

// Require exact header and column counts. Empty cells are valid, distinct from missing columns,
// which the tab count detects.
template <typename RowFn>
bool parseTsv(StringRef text, StringRef face, StringRef header, size_t ncols,
              ContractDiagnosticFn diag, RowFn onRow) {
  bool sawHeader = false;
  bool okAll = forEachLine(text, [&](int64_t ln, StringRef line) {
    if (ln == 1) {
      if (line != header)
        return fail(diag, face, 1, "bad-header",
                    "expected '" + header + "', got '" + line + "'");
      sawHeader = true;
      return true;
    }
    SmallVector<StringRef, 8> cols;
    line.split(cols, '\t', /*MaxSplit=*/-1, /*KeepEmpty=*/true);
    if (cols.size() != ncols)
      return fail(diag, face, ln, "bad-field-count",
                  "expected " + Twine(ncols) + " columns, got " +
                      Twine(cols.size()));
    return onRow(ln, cols);
  });
  if (!okAll)
    return false;
  if (!sawHeader) // Refuse empty input with no header.
    return fail(diag, face, 0, "bad-header", "empty input");
  return true;
}

// Nonnegative int64 cell.
bool parseCellId(StringRef face, int64_t ln, StringRef what, StringRef cell,
                 int64_t &v, ContractDiagnosticFn diag) {
  switch (parseI64(cell, v)) {
  case IntErr::Bad:
    return fail(diag, face, ln, "bad-integer", what + " '" + cell + "'");
  case IntErr::Overflow:
    return fail(diag, face, ln, "integer-overflow", what + " '" + cell + "'");
  case IntErr::Ok:
    break;
  }
  if (v < 0)
    return fail(diag, face, ln, "negative-value", what + " '" + cell + "'");
  return true;
}

// Boolean cells are exactly 0 or 1; do not infer other spellings.
bool parseCellBool(StringRef face, int64_t ln, StringRef what, StringRef cell,
                   bool &v, ContractDiagnosticFn diag) {
  if (cell == "0")
    v = false;
  else if (cell == "1")
    v = true;
  else
    return fail(diag, face, ln, "bad-bool", what + " '" + cell + "'");
  return true;
}

} // namespace

//===----------------------------------------------------------------------===//
// nodes face
//===----------------------------------------------------------------------===//
bool parseNodesFace(StringRef text, std::vector<NodeType> &out,
                    ContractDiagnosticFn diag) {
  StringRef face = "nodes";
  std::set<int64_t> ids;
  return parseTsv(
      text, face, "id\tkind\ttype\tscope\tscope_name\tline\tcol\tdetail", 8,
      diag, [&](int64_t ln, ArrayRef<StringRef> c) {
        NodeType t;
        if (!parseCellId(face, ln, "id", c[0], t.id, diag) ||
            !parseCellId(face, ln, "scope", c[3], t.scope, diag) ||
            !parseCellId(face, ln, "line", c[5], t.line, diag) ||
            !parseCellId(face, ln, "col", c[6], t.column, diag))
          return false;
        if (!ids.insert(t.id).second)
          return fail(diag, face, ln, "duplicate-node", "node id " + c[0]);
        t.kind = c[1].str();
        t.type = c[2].str();
        t.scopeName = c[4].str();
        t.detail = c[7].str(); // Empty detail is valid.
        out.push_back(std::move(t));
        return true;
      });
}

//===----------------------------------------------------------------------===//
// locals face
//===----------------------------------------------------------------------===//
bool parseLocalsFace(StringRef text, std::vector<Local> &out,
                     ContractDiagnosticFn diag) {
  StringRef face = "locals";
  std::set<std::pair<int64_t, int64_t>> slots;
  return parseTsv(
      text, face,
      "scope\tscope_name\tslot\tname\ttype\tis_param\tis_cell\tnullable_int", 8,
      diag, [&](int64_t ln, ArrayRef<StringRef> c) {
        Local l;
        if (!parseCellId(face, ln, "scope", c[0], l.scope, diag) ||
            !parseCellId(face, ln, "slot", c[2], l.slot, diag))
          return false;
        if (!slots.insert({l.scope, l.slot}).second)
          return fail(diag, face, ln, "duplicate-local-slot",
                      "scope " + c[0] + " slot " + c[2]);
        l.scopeName = c[1].str();
        l.name = c[3].str();
        l.type = c[4].str();
        if (!parseCellBool(face, ln, "is_param", c[5], l.isParam, diag) ||
            !parseCellBool(face, ln, "is_cell", c[6], l.isCell, diag) ||
            !parseCellBool(face, ln, "nullable_int", c[7], l.nullableInt, diag))
          return false;
        out.push_back(std::move(l));
        return true;
      });
}

//===----------------------------------------------------------------------===//
// methods face
//===----------------------------------------------------------------------===//
bool parseMethodsFace(StringRef text, std::vector<Method> &out,
                      ContractDiagnosticFn diag) {
  StringRef face = "methods";
  std::set<int64_t> scopes;
  return parseTsv(
      text, face, "scope\tname\tclass\tret\tnparams\tparams\tabi_scalar", 7,
      diag, [&](int64_t ln, ArrayRef<StringRef> c) {
        Method m;
        int64_t nparams;
        if (!parseCellId(face, ln, "scope", c[0], m.scope, diag) ||
            !parseCellId(face, ln, "nparams", c[4], nparams, diag))
          return false;
        if (!scopes.insert(m.scope).second)
          return fail(diag, face, ln, "duplicate-method-scope",
                      "scope " + c[0]);
        m.name = c[1].str();
        m.className = c[2].str();
        m.returnType = c[3].str();
        // Parameter rule: nparams == 0 iff spelling is "-". Refuse empty string as distinct from
        // "-".
        StringRef params = c[5];
        if (nparams == 0) {
          if (params != "-")
            return fail(diag, face, ln, "malformed-method-params",
                        "nparams 0 requires params '-', got '" + params + "'");
        } else {
          if (params == "-" || params.empty())
            return fail(diag, face, ln, "malformed-method-params",
                        "nparams " + Twine(nparams) + " but no parameters");
          SmallVector<StringRef, 8> toks;
          params.split(toks, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/true);
          if ((int64_t)toks.size() != nparams)
            return fail(diag, face, ln, "malformed-method-params",
                        "nparams " + Twine(nparams) + " but " +
                            Twine((uint64_t)toks.size()) + " parameters");
          for (StringRef tok : toks) {
            // Split name/type at the last colon.
            size_t pos = tok.rfind(':');
            if (pos == StringRef::npos || pos == 0 || pos + 1 == tok.size())
              return fail(diag, face, ln, "malformed-method-params",
                          "parameter '" + tok + "' is not name:type");
            Parameter p;
            p.name = tok.substr(0, pos).str();
            p.type = tok.substr(pos + 1).str();
            m.parameters.push_back(std::move(p));
          }
        }
        if (c[6] == "yes")
          m.scalarAbi = true;
        else if (c[6] == "no")
          m.scalarAbi = false;
        else
          return fail(diag, face, ln, "bad-abi-scalar",
                      "abi_scalar '" + c[6] + "' (yes/no only)");
        out.push_back(std::move(m));
        return true;
      });
}

} // namespace spinel_mlir::contract::internal

// Cross-table validation and sealing.
namespace spinel_mlir::contract {

// Model.h friend: the only path validating all four parsed tables and sealing an immutable module.
// Partial models cannot bypass it.
class ContractBuilder {
public:
  static std::unique_ptr<ContractModule>
  seal(internal::ParsedContractTables &&t, ContractDiagnosticFn diag);
};

namespace {

using internal::ParsedContractTables;

bool vfail(ContractDiagnosticFn diag, llvm::StringRef face, int64_t line,
           llvm::StringRef category, const llvm::Twine &detail) {
  diag((face + ":" + llvm::Twine(line) + ": " + category + ": " + detail)
           .str());
  return false;
}

// Check source, ROOT, node references, node types, scopes, locals, then methods;
// report the first inconsistency only. The sole recognized in-place analysis
// rewrite (AnalysisRewrite) is parsed Module.new { ... }: a new CallNode with
// Module receiver and a block becomes ConstantReadNode for SpinelAnon... .
// Do not recognize anything less specific.
bool isAnonymousModuleRewrite(const ParsedContractTables &t, const Node &astNode,
                              const NodeType &ty) {
  if (astNode.kind != "CallNode" || ty.kind != "ConstantReadNode" ||
      !llvm::StringRef(ty.detail).starts_with("SpinelAnon"))
    return false;
  auto field = [](const Node &n, llvm::StringRef key) -> const AstField * {
    for (const AstField &f : n.fields)
      if (f.key == key) return &f;
    return nullptr;
  };
  const AstField *name = field(astNode, "name");
  const AstField *receiver = field(astNode, "receiver");
  const AstField *block = field(astNode, "block");
  if (!name || name->kind != AstField::Kind::String ||
      std::get<std::string>(name->value) != "new" || !receiver ||
      receiver->kind != AstField::Kind::Reference || !block ||
      block->kind != AstField::Kind::Reference ||
      std::get<int64_t>(block->value) == -1)
    return false;
  const int64_t rid = std::get<int64_t>(receiver->value);
  for (const Node &r : t.ast.nodes) {
    if (r.id != rid) continue;
    const AstField *rname = field(r, "name");
    return r.kind == "ConstantReadNode" && rname &&
           rname->kind == AstField::Kind::String &&
           std::get<std::string>(rname->value) == "Module";
  }
  return false;
}

bool validateCrossTables(const ParsedContractTables &t,
                         ContractDiagnosticFn diag,
                         std::vector<AnalysisRewrite> &rewrites) {
  std::set<int64_t> nodeIds;
  for (const Node &n : t.ast.nodes)
    nodeIds.insert(n.id);
  std::set<int64_t> fileIds;
  for (const Source &s : t.ast.files)
    fileIds.insert(s.id);
  auto fieldLine = [&](int64_t node, llvm::StringRef key) -> int64_t {
    for (const auto &fl : t.ast.fieldLines)
      if (fl.node == node && key == fl.key)
        return fl.line;
    return 0;
  };

  // ROOT must refer to an existing node.
  if (!nodeIds.count(t.ast.root))
    return vfail(diag, "ast", t.ast.rootLine, "dangling-reference",
                 "ROOT -> " + llvm::Twine(t.ast.root));

  // Node R/A/node_file references.
  for (const Node &n : t.ast.nodes) {
    for (const AstField &f : n.fields) {
      if (f.kind == AstField::Kind::Reference) {
        int64_t v = std::get<int64_t>(f.value);
        if (v != -1 && !nodeIds.count(v))
          return vfail(diag, "ast", fieldLine(n.id, f.key),
                       "dangling-reference",
                       "node " + llvm::Twine(n.id) + " field '" + f.key +
                           "' -> " + llvm::Twine(v));
      } else if (f.kind == AstField::Kind::Array) {
        for (int64_t v : std::get<std::vector<int64_t>>(f.value))
          if (!nodeIds.count(v))
            return vfail(diag, "ast", fieldLine(n.id, f.key),
                         "dangling-reference",
                         "node " + llvm::Twine(n.id) + " field '" + f.key +
                             "' -> " + llvm::Twine(v));
      } else if (f.kind == AstField::Kind::Integer && f.key == "node_file") {
        int64_t v = std::get<int64_t>(f.value);
        if (!fileIds.count(v))
          return vfail(diag, "ast", fieldLine(n.id, f.key),
                       "dangling-reference",
                       "node " + llvm::Twine(n.id) +
                           " field 'node_file' -> " + llvm::Twine(v) +
                           " (no FILE)");
      }
    }
  }

  // Each nodes-face id must exist in ast with matching kind. Row order determines line numbers;
  // header is line 1 and parsing already refused blank rows.
  {
    std::map<int64_t, llvm::StringRef> astKind;
    std::map<int64_t, const Node *> astNode;
    for (const Node &n : t.ast.nodes) {
      astKind[n.id] = n.kind;
      astNode[n.id] = &n;
    }
    // Dead branches (AnalysisRewrite::DeadBranch), identified before the rows
    // are read. Exactly these shapes, the ones upstream folds:
    //   IfNode     whose predicate is a FalseNode or NilNode -> `statements`
    //   UnlessNode whose predicate is a TrueNode             -> `statements`
    //   IfNode     whose predicate is a TrueNode             -> `subsequent`
    // and only when that branch holds a DefNode and EVERY node of it is a
    // NilNode in the nodes face. For `if nil` the predicate itself becomes a
    // FalseNode, which belongs to the same rewrite.
    std::map<int64_t, std::string> nodesKindOf;
    for (const NodeType &ty : t.nodeTypes) nodesKindOf[ty.id] = ty.kind;
    auto refOf = [](const Node &n, llvm::StringRef key) -> int64_t {
      for (const AstField &f : n.fields)
        if (f.key == key && f.kind == AstField::Kind::Reference)
          return std::get<int64_t>(f.value);
      return -1;
    };
    std::map<int64_t, std::string> foldAllowed;  // id -> the kind it may become
    for (const Node &n : t.ast.nodes) {
      if (n.kind != "IfNode" && n.kind != "UnlessNode") continue;
      const int64_t pred = refOf(n, "predicate");
      auto pk = astKind.find(pred);
      if (pk == astKind.end()) continue;
      int64_t dead = -1;
      if (n.kind == "IfNode" && (pk->second == "FalseNode" || pk->second == "NilNode"))
        dead = refOf(n, "statements");
      else if (n.kind == "UnlessNode" && pk->second == "TrueNode")
        dead = refOf(n, "statements");
      else if (n.kind == "IfNode" && pk->second == "TrueNode")
        dead = refOf(n, "subsequent");
      if (dead < 0 || !astNode.count(dead)) continue;
      std::vector<int64_t> branch, work{dead};
      std::set<int64_t> seen;
      bool hasDef = false, allNil = true;
      while (!work.empty()) {
        const int64_t id = work.back();
        work.pop_back();
        if (id < 0 || !seen.insert(id).second || !astNode.count(id)) continue;
        branch.push_back(id);
        const Node &b = *astNode[id];
        if (b.kind == "DefNode") hasDef = true;
        auto nk = nodesKindOf.find(id);
        if (nk == nodesKindOf.end() || nk->second != "NilNode") allNil = false;
        for (const AstField &f : b.fields) {
          if (f.kind == AstField::Kind::Reference)
            work.push_back(std::get<int64_t>(f.value));
          else if (f.kind == AstField::Kind::Array)
            for (int64_t c : std::get<std::vector<int64_t>>(f.value))
              work.push_back(c);
        }
      }
      if (!hasDef || !allNil) continue;
      for (int64_t id : branch)
        if (astKind[id] != "NilNode") foldAllowed[id] = "NilNode";
      if (pk->second == "NilNode" && nodesKindOf[pred] == "FalseNode")
        foldAllowed[pred] = "FalseNode";
      std::sort(branch.begin(), branch.end());
      rewrites.push_back({AnalysisRewrite::Kind::DeadBranch, n.id, n.kind,
                          "NilNode", pk->second.str(), {}, branch});
    }

    // Pruned methods (AnalysisRewrite::PrunedMethod): upstream blanks a def
    // whose name no node of the program holds. Exactly: a DefNode not already
    // in a dead branch, EVERY node of which is a NilNode in the nodes face, and
    // whose name no string field of another node holds (a def's own `name`
    // field excepted, as upstream excepts it).
    std::map<std::string, int> heldNames;
    for (const Node &n : t.ast.nodes)
      for (const AstField &f : n.fields)
        if (f.kind == AstField::Kind::String &&
            !(n.kind == "DefNode" && f.key == "name"))
          ++heldNames[std::get<std::string>(f.value)];
    auto subtreeOf = [&](int64_t root, std::vector<int64_t> &out) {
      std::vector<int64_t> work{root};
      std::set<int64_t> seen;
      while (!work.empty()) {
        const int64_t id = work.back();
        work.pop_back();
        if (id < 0 || !seen.insert(id).second || !astNode.count(id)) continue;
        out.push_back(id);
        for (const AstField &f : astNode[id]->fields) {
          if (f.kind == AstField::Kind::Reference)
            work.push_back(std::get<int64_t>(f.value));
          else if (f.kind == AstField::Kind::Array)
            for (int64_t c : std::get<std::vector<int64_t>>(f.value))
              work.push_back(c);
        }
      }
    };
    for (const Node &n : t.ast.nodes) {
      if (n.kind != "DefNode" || foldAllowed.count(n.id)) continue;
      auto nk = nodesKindOf.find(n.id);
      if (nk == nodesKindOf.end() || nk->second != "NilNode") continue;
      std::string name;
      for (const AstField &f : n.fields)
        if (f.key == "name" && f.kind == AstField::Kind::String)
          name = std::get<std::string>(f.value);
      if (name.empty() || heldNames.count(name)) continue;
      std::vector<int64_t> def;
      subtreeOf(n.id, def);
      bool allNil = true;
      for (int64_t id : def) {
        auto k = nodesKindOf.find(id);
        if (k == nodesKindOf.end() || k->second != "NilNode") allNil = false;
      }
      if (!allNil) continue;
      for (int64_t id : def)
        if (astKind[id] != "NilNode") foldAllowed[id] = "NilNode";
      std::sort(def.begin(), def.end());
      rewrites.push_back({AnalysisRewrite::Kind::PrunedMethod, n.id, n.kind,
                          "NilNode", name, {}, def});
    }

    // Peeled parentheses (AnalysisRewrite::ParenPeel): a ParenthesesNode whose
    // body is a StatementsNode of exactly one expression, both NilNodes in the
    // nodes face while that expression is not (or is itself a peeled pair).
    std::set<int64_t> peeled;
    std::function<bool(int64_t)> isPeel = [&](int64_t p) -> bool {
      auto pn = astNode.find(p);
      if (pn == astNode.end() || pn->second->kind != "ParenthesesNode") return false;
      if (peeled.count(p)) return true;
      const int64_t s = refOf(*pn->second, "body");
      auto sn = astNode.find(s);
      if (sn == astNode.end() || sn->second->kind != "StatementsNode") return false;
      std::vector<int64_t> body;
      for (const AstField &f : sn->second->fields)
        if (f.key == "body" && f.kind == AstField::Kind::Array)
          body = std::get<std::vector<int64_t>>(f.value);
      if (body.size() != 1) return false;
      if (nodesKindOf[p] != "NilNode" || nodesKindOf[s] != "NilNode") return false;
      const int64_t e = body.front();
      auto ek = nodesKindOf.find(e);
      if (ek == nodesKindOf.end()) return false;
      if (ek->second == "NilNode" && astKind[e] != "NilNode" && !isPeel(e)) return false;
      peeled.insert(p);
      foldAllowed[p] = "NilNode";
      foldAllowed[s] = "NilNode";
      rewrites.push_back({AnalysisRewrite::Kind::ParenPeel, p, "ParenthesesNode",
                          "NilNode", "", {}, {p, s}});
      return true;
    };
    for (const Node &n : t.ast.nodes)
      if (n.kind == "ParenthesesNode" && !foldAllowed.count(n.id)) isPeel(n.id);

    // Dynamic sends (AnalysisRewrite::DynamicSend): a parsed CallNode named
    // `send`, `__send__` or `public_send` whose first argument is not a
    // Symbol or String literal. Upstream's lowering adds, in that send's
    // scope and with no position (0:0), only: one CallNode per candidate name
    // -- a value of a SymbolNode in the program --, an ArgumentsNode per arm
    // at most, and for a receiverless send one SelfNode. Rows of that shape
    // are attributed to the send below; anything else stays unresolved.
    std::map<int64_t, int64_t> nodesScopeOf;
    for (const NodeType &ty : t.nodeTypes) nodesScopeOf[ty.id] = ty.scope;
    std::set<std::string> symbolNames;
    for (const Node &n : t.ast.nodes)
      if (n.kind == "SymbolNode")
        for (const AstField &f : n.fields)
          if (f.key == "value" && f.kind == AstField::Kind::String)
            symbolNames.insert(std::get<std::string>(f.value));
    struct DynamicSend { size_t rewrite; int64_t scope; bool receiverless; int self = 0, calls = 0, args = 0; };
    std::vector<DynamicSend> dynamicSends;
    for (const Node &n : t.ast.nodes) {
      if (n.kind != "CallNode") continue;
      std::string name;
      for (const AstField &f : n.fields)
        if (f.key == "name" && f.kind == AstField::Kind::String)
          name = std::get<std::string>(f.value);
      if (name != "send" && name != "__send__" && name != "public_send") continue;
      auto args = astNode.find(refOf(n, "arguments"));
      if (args == astNode.end() || args->second->kind != "ArgumentsNode") continue;
      int64_t first = -1;
      for (const AstField &f : args->second->fields)
        if (f.key == "arguments" && f.kind == AstField::Kind::Array &&
            !std::get<std::vector<int64_t>>(f.value).empty())
          first = std::get<std::vector<int64_t>>(f.value).front();
      auto fk = astKind.find(first);
      if (fk == astKind.end() || fk->second == "SymbolNode" || fk->second == "StringNode")
        continue;
      auto sc = nodesScopeOf.find(n.id);
      if (sc == nodesScopeOf.end()) continue;
      dynamicSends.push_back({rewrites.size(), sc->second, refOf(n, "receiver") == -1});
      rewrites.push_back({AnalysisRewrite::Kind::DynamicSend, n.id, n.kind,
                          n.kind, name, {}, {}});
    }

    int64_t ln = 1;
    // One position per rewrite, in the same order; the dead branches and the
    // dynamic sends recorded above have none.
    std::vector<std::pair<int64_t, int64_t>> rewritePositions(
        rewrites.size(), std::make_pair(int64_t(-1), int64_t(-1)));
    for (const NodeType &ty : t.nodeTypes) {
      ++ln;
      auto it = astKind.find(ty.id);
      if (it == astKind.end()) {
        // The same desugar also ADDS nodes the parse does not have: the
        // anonymous module's ModuleNode and its constant, at the position of
        // the call it replaced. Those two, at that position, belong to the
        // recognised rewrite; any other node the analysis added is still a
        // reference the ast cannot resolve.
        AnalysisRewrite *owner = nullptr;
        for (size_t r = 0; r < rewrites.size(); ++r)
          if (rewrites[r].rewrite == AnalysisRewrite::Kind::AnonymousModule &&
              rewritePositions[r] == std::make_pair(ty.line, ty.column) &&
              (ty.kind == "ModuleNode" ||
               (ty.kind == "ConstantReadNode" && ty.detail == rewrites[r].detail)))
            owner = &rewrites[r];
        if (!owner && ty.line == 0 && ty.column == 0)
          for (DynamicSend &d : dynamicSends) {
            if (d.scope != ty.scope) continue;
            if (ty.kind == "SelfNode" && d.receiverless && d.self == 0) ++d.self;
            else if (ty.kind == "CallNode" && symbolNames.count(ty.detail)) ++d.calls;
            else if (ty.kind == "ArgumentsNode") ++d.args;
            else continue;
            owner = &rewrites[d.rewrite];
            break;
          }
        if (owner) {
          owner->synthesized.push_back(ty.id);
          continue;
        }
        return vfail(diag, "nodes", ln, "dangling-reference",
                     "node id " + llvm::Twine(ty.id) + " is not in the ast");
      }
      if (it->second != ty.kind) {
        auto fold = foldAllowed.find(ty.id);
        if (fold != foldAllowed.end() && fold->second == ty.kind) continue;
      }
      if (it->second != ty.kind &&
          isAnonymousModuleRewrite(t, *astNode[ty.id], ty)) {
        rewrites.push_back({AnalysisRewrite::Kind::AnonymousModule, ty.id,
                            it->second.str(), ty.kind, ty.detail, {}, {}});
        // The position is the PARSED node's: the rewrite resets the analysed
        // one, which then reports 0:0.
        int64_t line = 0, col = 0;
        for (const AstField &f : astNode[ty.id]->fields) {
          if (f.kind != AstField::Kind::Integer) continue;
          if (f.key == "node_line") line = std::get<int64_t>(f.value);
          if (f.key == "node_col") col = std::get<int64_t>(f.value);
        }
        rewritePositions.push_back({line, col});
        continue;
      }
      if (it->second != ty.kind)
        return vfail(diag, "nodes", ln, "kind-mismatch",
                     "node " + llvm::Twine(ty.id) + " ast '" + it->second +
                         "' nodes '" + ty.kind + "'");
    }
    // A dynamic send's added rows must look like arms: more ArgumentsNodes
    // than candidate calls is not that lowering. A send the analysis added
    // nothing for is no rewrite at all.
    for (const DynamicSend &d : dynamicSends)
      if (d.args > d.calls)
        return vfail(diag, "nodes", 0, "dangling-reference",
                     "node " + llvm::Twine(rewrites[d.rewrite].id) +
                         ": the nodes added for this send are not the arms of "
                         "a dynamic dispatch");
    llvm::erase_if(rewrites, [](const AnalysisRewrite &rw) {
      return rw.rewrite == AnalysisRewrite::Kind::DynamicSend && rw.synthesized.empty();
    });
    // Reverse coverage: every ast node needs a nodes row, as observed in eight producer cases. A
    // missing row has no location; report face-wide nodes:0.
    std::set<int64_t> typedIds;
    for (const NodeType &ty : t.nodeTypes)
      typedIds.insert(ty.id);
    for (const Node &n : t.ast.nodes)
      if (!typedIds.count(n.id))
        return vfail(diag, "nodes", 0, "missing-node-type",
                     "node id " + llvm::Twine(n.id) + " has no nodes row");
  }

  // The nodes face owns scope identity, including a unique scope-to-scope_name mapping.
  // locals/methods must match it; the producer uses the same Scope for all three, observed in eight
  // cases.
  std::set<int64_t> scopes;
  std::map<int64_t, llvm::StringRef> scopeNames;
  {
    int64_t ln = 1;
    for (const NodeType &ty : t.nodeTypes) {
      ++ln;
      scopes.insert(ty.scope);
      auto ins = scopeNames.insert({ty.scope, ty.scopeName});
      if (!ins.second && ins.first->second != ty.scopeName)
        return vfail(diag, "nodes", ln, "scope-name-mismatch",
                     "scope " + llvm::Twine(ty.scope) + " is '" +
                         ins.first->second + "' but this row says '" +
                         ty.scopeName + "'");
    }
  }
  {
    int64_t ln = 1;
    for (const Local &l : t.locals) {
      ++ln;
      if (!scopes.count(l.scope))
        return vfail(diag, "locals", ln, "unknown-scope",
                     "scope " + llvm::Twine(l.scope));
      if (l.scopeName != scopeNames[l.scope])
        return vfail(diag, "locals", ln, "scope-name-mismatch",
                     "scope " + llvm::Twine(l.scope) + " is '" +
                         scopeNames[l.scope] + "' in the nodes face but '" +
                         l.scopeName + "' here");
    }
  }
  {
    int64_t ln = 1;
    for (const Method &m : t.methods) {
      ++ln;
      if (!scopes.count(m.scope))
        return vfail(diag, "methods", ln, "unknown-scope",
                     "scope " + llvm::Twine(m.scope));
      // Method scope names must match nodes scope_name; the producer names scopes after methods.
      if (m.name != scopeNames[m.scope])
        return vfail(diag, "methods", ln, "scope-name-mismatch",
                     "scope " + llvm::Twine(m.scope) + " is '" +
                         scopeNames[m.scope] + "' in the nodes face but "
                         "method name is '" + m.name + "'");
      // Match is_param locals in slot order one-to-one with method parameters: check
      // count, consecutive slots and names, not types. The producer spells untyped
      // parameters poly in methods but unknown in locals (observed in freestanding/
      // tensor contract comparisons; hosted integer types matched). Leave type-alias
      // normalization to the importer and retain both spellings in diagnostic detail.
      std::vector<const Local *> params;
      for (const Local &l : t.locals)
        if (l.scope == m.scope && l.isParam)
          params.push_back(&l);
      std::sort(params.begin(), params.end(),
                [](const Local *a, const Local *b) { return a->slot < b->slot; });
      if (params.size() != m.parameters.size())
        return vfail(diag, "methods", ln, "param-local-mismatch",
                     "scope " + llvm::Twine(m.scope) + " has " +
                         llvm::Twine((uint64_t)m.parameters.size()) +
                         " parameters but " +
                         llvm::Twine((uint64_t)params.size()) +
                         " param locals");
      for (size_t i = 0; i < params.size(); ++i) {
        if ((int64_t)i != params[i]->slot)
          return vfail(diag, "methods", ln, "param-local-mismatch",
                       "scope " + llvm::Twine(m.scope) + " param locals are " +
                           "not slots 0.." +
                           llvm::Twine((uint64_t)params.size() - 1));
        if (params[i]->name != m.parameters[i].name)
          return vfail(diag, "methods", ln, "param-local-mismatch",
                       "scope " + llvm::Twine(m.scope) + " parameter " +
                           llvm::Twine((uint64_t)i) + " is " +
                           m.parameters[i].name + ":" + m.parameters[i].type +
                           " but local slot " + llvm::Twine(params[i]->slot) +
                           " is " + params[i]->name + ":" + params[i]->type);
      }
    }
  }

  // Every is_param=1 local requires a matching method/parameter row. Method-led checks skip scopes
  // with no method; refuse orphan parameter locals as missing reference consistency. Method-side
  // count/slot/name checks already fix parameter-to-slot correspondence.
  {
    std::set<int64_t> methodScopes;
    for (const Method &m : t.methods)
      methodScopes.insert(m.scope);
    int64_t ln = 1;
    for (const Local &l : t.locals) {
      ++ln;
      if (l.isParam && !methodScopes.count(l.scope))
        return vfail(diag, "locals", ln, "orphan-param-local",
                     "scope " + llvm::Twine(l.scope) + " slot " +
                         llvm::Twine(l.slot) +
                         " is a param local but the scope has no method");
    }
  }
  return true;
}

} // namespace

std::unique_ptr<ContractModule>
ContractBuilder::seal(internal::ParsedContractTables &&t,
                      ContractDiagnosticFn diag) {
  std::vector<AnalysisRewrite> rewrites;
  if (!validateCrossTables(t, diag, rewrites))
    return nullptr;
  std::unique_ptr<ContractModule> m(new ContractModule());

  m->sourceFile_ = std::move(t.ast.sourceFile);
  m->root_ = t.ast.root;
  m->sources_ = std::move(t.ast.files);
  llvm::sort(m->sources_,
             [](const Source &a, const Source &b) { return a.id < b.id; });
  m->nodes_ = std::move(t.ast.nodes);
  llvm::sort(m->nodes_,
             [](const Node &a, const Node &b) { return a.id < b.id; });
  // Canonical field order remains lexical by key, preserving dump/seal/consumer bytes.
  // AstField::producerOrder retains the other ordering, read only by stage-1 fsSubtree traversal.
  for (Node &n : m->nodes_)
    llvm::sort(n.fields, [](const AstField &a, const AstField &b) {
      return a.key < b.key;
    });
  // The rows of nodes a recognised rewrite added name ids the ast does not
  // have; they are recorded on the rewrite and not carried as node types.
  std::set<int64_t> added;
  for (const AnalysisRewrite &rw : rewrites)
    added.insert(rw.synthesized.begin(), rw.synthesized.end());
  llvm::erase_if(t.nodeTypes,
                 [&](const NodeType &ty) { return added.count(ty.id) != 0; });
  m->nodeTypes_ = std::move(t.nodeTypes);
  llvm::sort(m->nodeTypes_,
             [](const NodeType &a, const NodeType &b) { return a.id < b.id; });
  m->locals_ = std::move(t.locals);
  llvm::sort(m->locals_, [](const Local &a, const Local &b) {
    return std::tie(a.scope, a.slot) < std::tie(b.scope, b.slot);
  });
  m->methods_ = std::move(t.methods);
  llvm::sort(m->methods_,
             [](const Method &a, const Method &b) { return a.scope < b.scope; });
  m->rewrites_ = std::move(rewrites);
  return m;
}

namespace {

int64_t integerField(const Node &n, llvm::StringRef key, int64_t fallback) {
  for (const AstField &f : n.fields)
    if (f.key == key && f.kind == AstField::Kind::Integer)
      return std::get<int64_t>(f.value);
  return fallback;
}

void setIntegerField(Node &n, llvm::StringRef key, int64_t value) {
  for (AstField &f : n.fields)
    if (f.key == key && f.kind == AstField::Kind::Integer) f.value = value;
}

int64_t referenceField(const Node &n, llvm::StringRef key) {
  for (const AstField &f : n.fields)
    if (f.key == key && f.kind == AstField::Kind::Reference)
      return std::get<int64_t>(f.value);
  return -1;
}

/// Decision 0042 stage 4: remove an inserted prelude (ContractInputs::
/// preludeLine and preludeLines). Its nodes are the entry file's on its
/// lines, but the program node and the program's statements node: those take
/// the position of the first statement, which the prelude's first definition
/// is in the copy. Its scopes are the ones its nodes' rows name. Every
/// entry-file node after it moves up by its line count, in both faces, as do
/// the rows the ast lacks (an anonymous module's added rows) at the position
/// of such a node. The entry file is the FILE row that SOURCE_FILE names: the
/// root node may carry another file's id when the entry requires one.
void dropPrelude(internal::ParsedContractTables &t, int64_t firstLine,
                 int64_t lineCount, int64_t firstColumns) {
  int64_t entryFile = -1;
  for (const Source &s : t.ast.files)
    if (s.path == t.ast.sourceFile) entryFile = s.id;
  if (entryFile < 0) return;
  const int64_t lastLine = firstLine + lineCount - 1;
  int64_t statements = -1;
  for (const Node &n : t.ast.nodes)
    if (n.id == t.ast.root) statements = referenceField(n, "statements");
  std::set<int64_t> dropped, moved;
  std::set<std::pair<int64_t, int64_t>> movedAt;
  for (const Node &n : t.ast.nodes) {
    if (integerField(n, "node_file", 0) != entryFile) continue;
    const int64_t line = integerField(n, "node_line", 0);
    if (line >= firstLine && line <= lastLine && n.id != t.ast.root &&
        n.id != statements)
      dropped.insert(n.id);
    if (line > lastLine) {
      moved.insert(n.id);
      movedAt.insert({line, integerField(n, "node_col", 0)});
    }
  }
  std::set<int64_t> inAst;
  for (const Node &n : t.ast.nodes) inAst.insert(n.id);
  // The line right after the prelude is the program's first; behind a byte
  // order mark on line 1 it gets the mark's columns back.
  const int64_t firstProgramLine = lastLine + 1;
  for (Node &n : t.ast.nodes)
    if (moved.count(n.id)) {
      const int64_t line = integerField(n, "node_line", 0);
      if (line == firstProgramLine && firstColumns > 0)
        setIntegerField(n, "node_col", integerField(n, "node_col", 0) + firstColumns);
      setIntegerField(n, "node_line", line - lineCount);
    }
  for (NodeType &ty : t.nodeTypes)
    if (moved.count(ty.id) ||
        (!inAst.count(ty.id) && ty.line > lastLine && movedAt.count({ty.line, ty.column}))) {
      if (ty.line == firstProgramLine && firstColumns > 0) ty.column += firstColumns;
      ty.line -= lineCount;
    }
  if (dropped.empty()) return;
  std::set<int64_t> scopes;
  for (const NodeType &ty : t.nodeTypes)
    if (dropped.count(ty.id) && ty.scope != 0) scopes.insert(ty.scope);
  llvm::erase_if(t.ast.nodes, [&](const Node &n) { return dropped.count(n.id) > 0; });
  for (Node &n : t.ast.nodes)
    for (AstField &f : n.fields)
      if (f.kind == AstField::Kind::Array)
        llvm::erase_if(std::get<std::vector<int64_t>>(f.value),
                       [&](int64_t id) { return dropped.count(id) > 0; });
  llvm::erase_if(t.ast.fieldLines, [&](const internal::ParsedAst::FieldLine &l) {
    return dropped.count(l.node) > 0;
  });
  llvm::erase_if(t.nodeTypes, [&](const NodeType &ty) {
    return dropped.count(ty.id) > 0 || scopes.count(ty.scope) > 0;
  });
  llvm::erase_if(t.locals, [&](const Local &l) { return scopes.count(l.scope) > 0; });
  llvm::erase_if(t.methods, [&](const Method &m) { return scopes.count(m.scope) > 0; });
  // The program node and its statements node, when the prelude held their
  // position: the first statement left gives it, as it does without one.
  const Node *first = nullptr;
  for (const Node &n : t.ast.nodes)
    if (n.id == statements)
      for (const AstField &f : n.fields)
        if (f.key == "body" && f.kind == AstField::Kind::Array &&
            !std::get<std::vector<int64_t>>(f.value).empty()) {
          const int64_t id = std::get<std::vector<int64_t>>(f.value).front();
          for (const Node &m : t.ast.nodes)
            if (m.id == id) first = &m;
        }
  if (!first) return;
  const int64_t line = integerField(*first, "node_line", 0);
  const int64_t col = integerField(*first, "node_col", 0);
  for (Node &n : t.ast.nodes) {
    if (n.id != t.ast.root && n.id != statements) continue;
    const int64_t at = integerField(n, "node_line", 0);
    if (at < firstLine || at > lastLine) continue;
    setIntegerField(n, "node_line", line);
    setIntegerField(n, "node_col", col);
    for (NodeType &ty : t.nodeTypes)
      if (ty.id == n.id) {
        ty.line = line;
        ty.column = col;
      }
  }
}

/// Decision 0045: move the entry file's nodes back over the text the buffer
/// rewrite inserted (ContractInputs::columnInserts), so every column is the
/// source's. A column in the copy maps back by the inserted lengths before
/// it on its line; one inside inserted text takes the insertion's column.
void unshiftColumns(internal::ParsedContractTables &t,
                    const std::vector<ColumnInsert> &inserts) {
  int64_t entryFile = -1;
  for (const Source &s : t.ast.files)
    if (s.path == t.ast.sourceFile) entryFile = s.id;
  if (entryFile < 0) return;
  auto back = [&](int64_t line, int64_t col) { return sourceColumn(inserts, line, col); };
  // As dropPrelude does: an entry-file node by its id, and a row the ast
  // lacks (an anonymous module's added rows) by the position of such a node.
  std::set<int64_t> moved, inAst;
  std::set<std::pair<int64_t, int64_t>> movedAt;  // (line, copy column)
  for (Node &n : t.ast.nodes) {
    inAst.insert(n.id);
    if (integerField(n, "node_file", 0) != entryFile) continue;
    const int64_t line = integerField(n, "node_line", 0);
    const int64_t col = integerField(n, "node_col", 0);
    moved.insert(n.id);
    movedAt.insert({line, col});
    setIntegerField(n, "node_col", back(line, col));
  }
  for (NodeType &ty : t.nodeTypes)
    if (moved.count(ty.id) || (!inAst.count(ty.id) && movedAt.count({ty.line, ty.column})))
      ty.column = back(ty.line, ty.column);
}

} // namespace

std::unique_ptr<ContractModule> readContract(const ContractInputs &inputs,
                                             ContractDiagnosticFn diag) {
  internal::ParsedContractTables t;
  if (!internal::parseAstFace(inputs.ast, t.ast, diag) ||
      !internal::parseNodesFace(inputs.nodes, t.nodeTypes, diag) ||
      !internal::parseLocalsFace(inputs.locals, t.locals, diag) ||
      !internal::parseMethodsFace(inputs.methods, t.methods, diag))
    return nullptr;
  if (inputs.preludeLine > 0 && inputs.preludeLines > 0)
    dropPrelude(t, inputs.preludeLine, inputs.preludeLines, inputs.preludeColumns);
  if (!inputs.columnInserts.empty()) unshiftColumns(t, inputs.columnInserts);
  return ContractBuilder::seal(std::move(t), diag);
}

} // namespace spinel_mlir::contract
