//===- Boundary.cpp - version-1 CORE boundary contract ---------*- C++ -*-===//
//
// Decision 0007.  See Boundary.h for what this face is and is not.
//
// Two rules shape the whole file.
//
//   Nothing defaults.  Every unrecognised key, repeated key, missing field,
//   duplicate name, unknown type and unresolved name is a diagnostic.  A
//   contract that was partly understood is not published: the caller gets
//   nullopt, never a half-filled model it might use.
//
//   Every binding is checked from both ends.  A buffer names its count and the
//   count is checked to exist, to be a scalar, to be u64 and to belong to no
//   other buffer; and every parameter declared as a count is checked to have a
//   buffer pointing back at it.  The predecessor's positional `:len` bound to
//   whichever parameter happened to precede it, so two buffers could quietly
//   share one length; naming it only helps if both directions are verified.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Support/Int64Allow.h"
#include "spinel-mlir/Support/IntegerWidth.h"

#include "spinel-mlir/Core/Input.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Triple.h"

#include <algorithm>

using namespace llvm;

namespace spinel_mlir::core {

StringRef scalarDomainName(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "i32";
  case ScalarDomain::U32: return "u32";
  case ScalarDomain::I64: return "i64";
  case ScalarDomain::U64: return "u64";
  }
  return "?";
}

StringRef elementTypeName(ElementType e) {
  switch (e) {
  case ElementType::U8:  return "u8";
  case ElementType::I32: return "i32";
  case ElementType::U32: return "u32";
  case ElementType::I64: return "i64";
  case ElementType::I8:  return "i8";
  case ElementType::U16: return "u16";
  case ElementType::I16: return "i16";
  }
  return "?";
}

StringRef accessModeName(AccessMode m) {
  return m == AccessMode::In ? "in" : "inout";
}

StringRef scalarCType(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "int32_t";
  case ScalarDomain::U32: return "uint32_t";
  case ScalarDomain::I64: return "int64_t";
  case ScalarDomain::U64: return "uint64_t";
  }
  return "?";
}

StringRef elementCType(ElementType e) {
  switch (e) {
  case ElementType::U8:  return "uint8_t";
  case ElementType::I32: return "int32_t";
  case ElementType::U32: return "uint32_t";
  case ElementType::I64: return "int64_t";
  case ElementType::I8:  return "int8_t";
  case ElementType::U16: return "uint16_t";
  case ElementType::I16: return "int16_t";
  }
  return "?";
}

const ScalarParam *BoundaryContract::findScalar(StringRef name) const {
  for (const auto &s : scalars)
    if (s.name == name) return &s;
  return nullptr;
}

const BufferParam *BoundaryContract::findBuffer(StringRef name) const {
  for (const auto &b : buffers)
    if (b.name == name) return &b;
  return nullptr;
}

const ExternDecl *BoundaryContract::findExtern(StringRef module, StringRef fn) const {
  for (const auto &e : externs)
    if (e.module == module && e.fn == fn) return &e;
  return nullptr;
}

namespace {

std::optional<ScalarDomain> parseDomain(StringRef s) {
  if (s == "i32") return ScalarDomain::I32;
  if (s == "u32") return ScalarDomain::U32;
  if (s == "i64") return ScalarDomain::I64;
  if (s == "u64") return ScalarDomain::U64;
  return std::nullopt;
}

std::optional<ElementType> parseElement(StringRef s) {
  if (s == "u8")  return ElementType::U8;
  if (s == "i32") return ElementType::I32;
  if (s == "u32") return ElementType::U32;
  if (s == "i64") return ElementType::I64;
  if (s == "i8")  return ElementType::I8;
  if (s == "u16") return ElementType::U16;
  if (s == "i16") return ElementType::I16;
  return std::nullopt;
}

/// A name the generated C signature can carry unchanged.
///
/// Refusing is deliberate where mangling would be possible: a mangled name
/// makes the generated signature depend on a rule nobody reads, and a contract
/// whose parameter cannot be spelled in C is better renamed at the source.
///
/// Three separate reasons to refuse, reported apart so the diagnostic says
/// which one applies.
enum class NameVerdict { Ok, NotIdentifier, CKeyword, Generated };

NameVerdict checkName(StringRef s) {
  if (s.empty() || s.size() > 64) return NameVerdict::NotIdentifier;
  if (!(llvm::isAlpha(s[0]) || s[0] == '_')) return NameVerdict::NotIdentifier;
  for (char c : s)
    if (!(llvm::isAlnum(c) || c == '_')) return NameVerdict::NotIdentifier;

  // C11 keywords, plus the ones C++ adds, since a header may be included from
  // either.  A parameter named `int` or `class` would not compile, and the
  // failure would appear in the consumer rather than in the contract.
  static const char *kKeywords[] = {
      "alignas", "alignof", "auto", "bool", "break", "case", "catch", "char",
      "class", "const", "constexpr", "continue", "default", "delete", "do",
      "double", "else", "enum", "extern", "false", "float", "for", "goto",
      "if", "inline", "int", "long", "namespace", "new", "nullptr", "operator",
      "private", "protected", "public", "register", "restrict", "return",
      "short", "signed", "sizeof", "static", "struct", "switch", "template",
      "this", "throw", "true", "try", "typedef", "typename", "union",
      "unsigned", "using", "virtual", "void", "volatile", "while",
      "_Bool", "_Complex", "_Imaginary", "_Atomic", "_Generic", "_Noreturn"};
  for (const char *k : kKeywords)
    if (s == k) return NameVerdict::CKeyword;

  // Names the generator itself produces in the same signature.  `result` is
  // the result pointer, so a parameter of that name would collide with it; the
  // prefix is reserved for the entry and its macros.
  if (s == "result") return NameVerdict::Generated;
  if (s.starts_with("spinel_core_") || s.starts_with("SPINEL_CORE_"))
    return NameVerdict::Generated;
  return NameVerdict::Ok;
}

bool plainIdentifier(StringRef s) { return checkName(s) == NameVerdict::Ok; }

/// A condition operand as decision 0014's plan spells it: a parameter name,
/// an integer literal, or `len(<name>)`.
bool conditionOperand(StringRef s) {
  if (s.consume_front("len(")) return s.consume_back(")") && plainIdentifier(s);
  int64_t v;
  if (!s.getAsInteger(10, v)) return true;
  return plainIdentifier(s);
}
bool conditionOperator(StringRef s) {
  return s == "<" || s == "<=" || s == ">" || s == ">=" || s == "==" || s == "!=";
}

/// Version 2 (decision 0014): one `extern` line.
///
///   extern <Module>.<fn> symbol <c_symbol> [arg <name> <domain>]...
///          [arg <name> buffer <elem> <in|inout>]... [returns <domain>] [isr_ok]
///          [guard <lhs> <op> <rhs> else <argument|bounds>]...
///          [static <lhs> <op> <rhs> else <diagnostic>]...
///          bound iterations <expr> evidence <path>
///
/// `bound iterations unknown "<reason>"` (decision 0021, owner 2026-10-20)
/// declares an extern whose work has no derived bound; the reason is quoted,
/// may span fields, and may be neither empty nor hold `"` or `*/` (it is
/// written into the extern header's comment).
///
/// Every clause is keyword-led, so the line is read clause by clause; a clause
/// with the wrong number of fields, an unknown keyword, a repeated singular
/// clause and a missing required one are each a diagnostic.
template <typename Say>
void parseExtern(const SmallVectorImpl<StringRef> &f, unsigned lineNo,
                 BoundaryContract &c, Say &say) {
  if (f.size() < 4 || f[2] != "symbol") {
    say(lineNo, "bad-field", "an extern is `extern <Module>.<fn> symbol <c_symbol> ...`");
    return;
  }
  ExternDecl e;
  auto dot = f[1].split('.');
  if (dot.second.empty() || !plainIdentifier(dot.second) ||
      dot.first.empty() || !llvm::isUpper(dot.first[0]) || !plainIdentifier(dot.first)) {
    say(lineNo, "bad-name", "an extern is named <Module>.<fn>, with a capitalised module, not " + f[1]);
    return;
  }
  e.module = dot.first.str();
  e.fn = dot.second.str();
  if (checkName(f[3]) != NameVerdict::Ok) {
    say(lineNo, "bad-name", "extern symbol is not a C identifier: " + f[3]);
    return;
  }
  e.symbol = f[3].str();
  StringSet<> argNames;
  bool sawReturns = false, sawBound = false, sawEvidence = false;
  size_t i = 4;
  auto take = [&](size_t n) -> bool { // n fields after the keyword at f[i]
    if (i + n >= f.size()) {
      say(lineNo, "bad-field", "extern clause `" + f[i] + "` is incomplete");
      return false;
    }
    return true;
  };
  while (i < f.size()) {
    StringRef kw = f[i];
    if (kw == "arg") {
      if (!take(2)) return;
      ExternArg a;
      if (!plainIdentifier(f[i + 1]) || !argNames.insert(f[i + 1]).second) {
        say(lineNo, "bad-name", "extern argument name is not a plain, unique identifier: " + f[i + 1]);
        return;
      }
      a.name = f[i + 1].str();
      if (f[i + 2] == "buffer") {
        if (!take(4)) return;
        auto el = parseElement(f[i + 3]);
        if (!el) { say(lineNo, "bad-type", "not a buffer element type: " + f[i + 3]); return; }
        if (f[i + 4] != "in" && f[i + 4] != "inout") {
          say(lineNo, "unsupported-mode", "an extern buffer argument is `in` or `inout`, not " + f[i + 4]);
          return;
        }
        a.kind = Param::Kind::Buffer;
        a.element = *el;
        a.mode = f[i + 4] == "in" ? AccessMode::In : AccessMode::InOut;
        i += 5;
      } else {
        auto d = parseDomain(f[i + 2]);
        if (!d || *d == ScalarDomain::U64) {
          say(lineNo, "bad-type", "an extern scalar argument is i32, u32 or i64, not " + f[i + 2]);
          return;
        }
        a.kind = Param::Kind::Scalar;
        a.scalar = *d;
        i += 3;
      }
      e.args.push_back(a);
      continue;
    }
    if (kw == "returns") {
      if (!take(1)) return;
      if (sawReturns) { say(lineNo, "duplicate-field", "extern `returns` appears twice"); return; }
      sawReturns = true;
      auto d = parseDomain(f[i + 1]);
      if (!d || *d == ScalarDomain::U64) {
        say(lineNo, "bad-type", "an extern returns i32, u32 or i64, not " + f[i + 1]);
        return;
      }
      e.returns = d;
      i += 2;
      continue;
    }
    if (kw == "isr_ok") { e.isrOk = true; ++i; continue; }
    if (kw == "guard" || kw == "static") {
      if (!take(5)) return;
      if (!conditionOperand(f[i + 1]) || !conditionOperator(f[i + 2]) ||
          !conditionOperand(f[i + 3]) || f[i + 4] != "else") {
        say(lineNo, "bad-condition",
            "a " + kw + " is `" + kw + " <operand> <op> <operand> else <...>`, with operands a "
            "name, an integer or len(<name>)");
        return;
      }
      if (kw == "guard") {
        if (f[i + 5] != "argument" && f[i + 5] != "bounds") {
          say(lineNo, "bad-condition", "a guard fails with `argument` or `bounds`, not " + f[i + 5]);
          return;
        }
        e.guards.push_back({f[i + 1].str(), f[i + 2].str(), f[i + 3].str(), f[i + 5].str()});
      } else {
        if (f[i + 5].empty() || !llvm::isLower(f[i + 5][0]) ||
            f[i + 5].find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") != StringRef::npos) {
          say(lineNo, "bad-condition", "a static's diagnostic is a kebab-case code, not " + f[i + 5]);
          return;
        }
        e.statics.push_back({f[i + 1].str(), f[i + 2].str(), f[i + 3].str(), f[i + 5].str()});
      }
      i += 6;
      continue;
    }
    if (kw == "bound") {
      if (!take(2)) return;
      if (sawBound) { say(lineNo, "duplicate-field", "extern `bound` appears twice"); return; }
      sawBound = true;
      if (f[i + 1] != "iterations") {
        say(lineNo, "bad-field", "an extern bound is `bound iterations <expr>`");
        return;
      }
      if (f[i + 2] == "unknown") {
        // the reason: one quoted run of fields, `"` at its start and end
        size_t j = i + 3;
        if (j >= f.size() || !f[j].starts_with("\"")) {
          say(lineNo, "bad-field", "an unknown bound names its reason: `bound iterations unknown \"<reason>\"`");
          return;
        }
        std::string reason = f[j].drop_front().str();
        bool closed = false;
        if (StringRef(reason).ends_with("\"")) {
          reason.pop_back();
          closed = true;
        }
        while (!closed && ++j < f.size()) {
          reason += " ";
          reason += f[j].str();
          if (StringRef(reason).ends_with("\"")) {
            reason.pop_back();
            closed = true;
          }
        }
        if (!closed) {
          say(lineNo, "bad-field", "an unknown bound's reason is not closed by `\"`");
          return;
        }
        if (StringRef(reason).trim().empty()) {
          say(lineNo, "bad-field", "an unknown bound names its reason: the quotes are empty");
          return;
        }
        if (reason.find('"') != std::string::npos || reason.find("*/") != std::string::npos) {
          say(lineNo, "bad-field", "an unknown bound's reason holds `\"` or `*/`");
          return;
        }
        e.boundUnknown = true;
        e.boundReason = reason;
        e.bound = "iterations unknown \"" + reason + "\"";
        i = j + 1;
        continue;
      }
      e.bound = ("iterations " + f[i + 2]).str();
      i += 3;
      continue;
    }
    if (kw == "evidence") {
      if (!take(1)) return;
      if (sawEvidence) { say(lineNo, "duplicate-field", "extern `evidence` appears twice"); return; }
      sawEvidence = true;
      e.evidencePath = f[i + 1].str();
      i += 2;
      continue;
    }
    say(lineNo, "bad-field", "unknown extern clause `" + kw + "`");
    return;
  }
  if (!sawBound) { say(lineNo, "missing-field", "extern " + f[1] + " declares no `bound`"); return; }
  if (!sawEvidence) { say(lineNo, "missing-field", "extern " + f[1] + " names no `evidence`"); return; }
  // Every operand that is a name must be an argument of this extern, and
  // `len()` must name a buffer argument: a condition over a name the call
  // cannot supply would be a condition nothing could evaluate.
  auto checkOperand = [&](StringRef s, StringRef what) -> bool {
    int64_t v;
    if (!s.getAsInteger(10, v)) return true;
    bool len = s.consume_front("len(");
    if (len) s.consume_back(")");
    for (const ExternArg &a : e.args)
      if (a.name == s) {
        if (len && a.kind != Param::Kind::Buffer) {
          say(lineNo, "bad-condition", what + " takes len() of " + s + ", which is not a buffer argument");
          return false;
        }
        return true;
      }
    say(lineNo, "bad-condition", what + " names " + s + ", which is not an argument of this extern");
    return false;
  };
  for (const Guard &g : e.guards)
    if (!checkOperand(g.lhs, "a guard") || !checkOperand(g.rhs, "a guard")) return;
  for (const StaticRequirement &s : e.statics)
    if (!checkOperand(s.lhs, "a static") || !checkOperand(s.rhs, "a static")) return;
  c.externs.push_back(std::move(e));
}

} // namespace

std::optional<BoundaryContract> parseBoundaryContract(StringRef text,
                                                      StringRef fileName,
                                                      StringRef sourceRoot,
                                                      BoundaryDiagnosticFn diag) {
  BoundaryContract c;
  bool bad = false;
  unsigned lineNo = 0;
  bool sawVersion = false, sawRoot = false, sawEntry = false, sawResult = false, sawContext = false;
  StringSet<> names;

  auto say = [&](unsigned ln, StringRef category, const Twine &detail) {
    diag((fileName + ":" + Twine(ln) + ": " + category + ": " + detail).str());
    bad = true;
  };

  for (StringRef rest = text; !rest.empty();) {
    auto split = rest.split('\n');
    StringRef line = split.first;
    rest = split.second;
    ++lineNo;

    line = line.rtrim();
    if (line.empty() || line.starts_with("#")) continue;

    SmallVector<StringRef, 8> f;
    line.split(f, ' ', -1, /*KeepEmpty=*/false);
    StringRef key = f[0];

    if (key == "core-contract") {
      if (sawVersion) { say(lineNo, "duplicate-field", "core-contract appears twice"); continue; }
      if (lineNo != 1 && (sawRoot || sawEntry || sawResult || !c.order.empty())) {
        say(lineNo, "field-order", "core-contract must come before every other field");
        continue;
      }
      sawVersion = true;
      if (f.size() != 2) { say(lineNo, "bad-field", "core-contract takes exactly one version number"); continue; }
      unsigned v = 0;
      if (f[1].getAsInteger(10, v)) { say(lineNo, "bad-version", "version is not a number: " + f[1]); continue; }
      if (v != 1 && v != 2) { say(lineNo, "unsupported-version", "version " + Twine(v) + " is not supported; this reader accepts 1 and 2"); continue; }
      c.version = v;
      continue;
    }

    if (!sawVersion) {
      say(lineNo, "missing-version", "the first field must be `core-contract 1` or `core-contract 2`; found " + key);
      // keep going so every other defect is reported too
    }
    const bool v2 = c.version == 2;

    // Version 2 (decision 0014): the entry's context, thread or interrupt.
    if (key == "context") {
      if (!v2) { say(lineNo, "version-mismatch", "`context` is a version 2 field; a version 1 contract has no context"); continue; }
      if (sawContext) { say(lineNo, "duplicate-field", "context appears twice"); continue; }
      sawContext = true;
      if (f.size() != 2 || (f[1] != "thread" && f[1] != "interrupt")) {
        say(lineNo, "bad-field", "context is `thread` or `interrupt`");
        continue;
      }
      c.context = f[1].str();
      continue;
    }

    // Decision 0041 stage 2: the context's data stack, in bytes.
    if (key == "scratch") {
      if (!v2) { say(lineNo, "version-mismatch", "`scratch` is a version 2 field; a version 1 contract has no data stack"); continue; }
      if (c.scratchBytes) { say(lineNo, "duplicate-field", "scratch appears twice"); continue; }
      uint64_t bytes = 0;
      if (f.size() != 2 || f[1].getAsInteger(10, bytes) || bytes < 16 || bytes > 0x7fffffffu) {
        say(lineNo, "bad-field", "scratch takes one size in bytes, from 16 to 2147483647");
        continue;
      }
      c.scratchBytes = bytes;
      continue;
    }

    if (key == "extern") {
      if (!v2) { say(lineNo, "version-mismatch", "`extern` is a version 2 field; a version 1 contract declares no externs"); continue; }
      parseExtern(f, lineNo, c, say);
      continue;
    }

    if (key == "root") {
      if (sawRoot) { say(lineNo, "duplicate-field", "root appears twice"); continue; }
      sawRoot = true;
      if (f.size() != 2) { say(lineNo, "bad-field", "root takes exactly one path"); continue; }
      // Path arithmetic only.  The file is NOT opened here: the caller opens
      // it exactly once, copies the bytes into a snapshot it owns, and every
      // later step -- digest, analysis, ledger -- names that copy.  Probing
      // readability here would be an extra read of a path that may hold
      // different bytes by the time the real one happens.
      SmallString<256> path;
      if (sys::path::is_absolute(f[1])) path = f[1];
      else { path = sourceRoot; sys::path::append(path, f[1]); }
      c.rootPath = f[1].str();
      c.rootResolved = std::string(path);
      continue;
    }

    if (key == "entry") {
      if (sawEntry) { say(lineNo, "duplicate-field", "entry appears twice"); continue; }
      sawEntry = true;
      if (f.size() != 2) { say(lineNo, "bad-field", "entry takes exactly one method name"); continue; }
      switch (checkName(f[1])) {
      case NameVerdict::NotIdentifier:
        say(lineNo, "bad-name", "entry is not a plain identifier: " + f[1]); continue;
      case NameVerdict::CKeyword:
        say(lineNo, "reserved-name", "entry " + f[1] + " is a C keyword and cannot be a generated symbol"); continue;
      case NameVerdict::Generated:
        say(lineNo, "reserved-name", "entry " + f[1] + " collides with a name the generator produces"); continue;
      case NameVerdict::Ok: break;
      }
      c.entry = f[1].str();
      continue;
    }

    if (key == "result") {
      if (sawResult) { say(lineNo, "duplicate-field", "result appears twice"); continue; }
      sawResult = true;
      if (f.size() != 2) { say(lineNo, "bad-field", "result takes exactly one type"); continue; }
      // Version 2 entries return the 0007 status and nothing else: an
      // application entry writes its state, it does not compute a value.
      if (f[1] == "none") {
        if (!v2) say(lineNo, "bad-type", "`result none` is a version 2 form; a version 1 entry computes a scalar result");
        continue;
      }
      if (v2) { say(lineNo, "bad-type", "a version 2 entry declares `result none`; it returns only its status"); continue; }
      auto d = parseDomain(f[1]);
      if (!d) { say(lineNo, "bad-type", "not a scalar domain: " + f[1]); continue; }
      if (*d == ScalarDomain::U64) {
        say(lineNo, "bad-type", "u64 is a buffer count type, not a result type");
        continue;
      }
      c.result = d;
      continue;
    }

    if (key == "param") {
      if (f.size() < 3) { say(lineNo, "bad-field", "param needs at least a name and a kind"); continue; }
      StringRef name = f[1];
      switch (checkName(name)) {
      case NameVerdict::NotIdentifier:
        say(lineNo, "bad-name", "parameter name is not a plain identifier: " + name); continue;
      case NameVerdict::CKeyword:
        say(lineNo, "reserved-name", "parameter " + name + " is a C keyword; the generated signature could not be compiled"); continue;
      case NameVerdict::Generated:
        say(lineNo, "reserved-name", "parameter " + name +
            " collides with a name the generated signature produces (the result pointer is `result`)"); continue;
      case NameVerdict::Ok: break;
      }
      if (!names.insert(name).second) { say(lineNo, "duplicate-parameter", "parameter " + name + " is declared twice"); continue; }

      if (f[2] == "scalar") {
        if (v2) { say(lineNo, "bad-field", "a version 2 entry has no scalar parameters; each parameter is a declared state buffer"); continue; }
        if (f.size() != 4) { say(lineNo, "bad-field", "a scalar parameter is `param <name> scalar <domain>`"); continue; }
        auto d = parseDomain(f[3]);
        if (!d) { say(lineNo, "bad-type", "not a scalar domain: " + f[3]); continue; }
        c.order.push_back({Param::Kind::Scalar, c.scalars.size()});
        c.scalars.push_back({name.str(), *d, ""});
        continue;
      }
      if (f[2] == "buffer" && v2) {
        // `param <name> buffer <elem> inout count const <N> [cross]`: a state
        // buffer, always inout (it is the application's own storage), with a
        // constant count and no count parameter.
        const bool cross = f.size() == 9 && f[8] == "cross";
        if ((f.size() != 8 && !cross) || f[4] != "inout" || f[5] != "count" || f[6] != "const") {
          say(lineNo, "bad-field",
              "a version 2 buffer parameter is `param <name> buffer <element> inout count const <N> [cross]`");
          continue;
        }
        auto e = parseElement(f[3]);
        if (!e) { say(lineNo, "bad-type", "not a buffer element type: " + f[3]); continue; }
        uint64_t count = 0;
        if (f[7].getAsInteger(10, count) || count == 0) {
          say(lineNo, "bad-count", "a constant count is a positive integer, not " + f[7]);
          continue;
        }
        c.order.push_back({Param::Kind::Buffer, c.buffers.size()});
        BufferParam b{name.str(), *e, AccessMode::InOut, "", count, cross};
        c.buffers.push_back(b);
        continue;
      }
      if (f[2] == "buffer") {
        if (f.size() != 7 || f[5] != "count") {
          say(lineNo, "bad-field",
              "a buffer parameter is `param <name> buffer <element> <in|inout> count <count-name>`");
          continue;
        }
        auto e = parseElement(f[3]);
        if (!e) { say(lineNo, "bad-type", "not a buffer element type: " + f[3]); continue; }
        std::optional<AccessMode> m;
        if (f[4] == "in") m = AccessMode::In;
        else if (f[4] == "inout") m = AccessMode::InOut;
        else if (f[4] == "out") {
          say(lineNo, "unsupported-mode",
              "`out` is not in version 1: a failure may leave a partial prefix, so a "
              "written buffer must also be initialised by the caller and declared `inout`");
          continue;
        } else { say(lineNo, "unsupported-mode", "not an access mode: " + f[4]); continue; }
        if (!plainIdentifier(f[6])) { say(lineNo, "bad-name", "count name is not a plain identifier: " + f[6]); continue; }
        c.order.push_back({Param::Kind::Buffer, c.buffers.size()});
        c.buffers.push_back({name.str(), *e, *m, f[6].str(), std::nullopt, false});
        continue;
      }
      say(lineNo, "bad-field", "a parameter is `scalar` or `buffer`, not " + f[2]);
      continue;
    }

    say(lineNo, "unknown-field", "unrecognised key " + key);
  }

  if (!sawVersion) say(0, "missing-version", "no `core-contract` version line");
  if (!sawRoot) say(0, "missing-field", "no `root` source snapshot");
  if (!sawEntry) say(0, "missing-field", "no `entry` method");
  if (!sawResult) say(0, "missing-field", c.version == 2 ? "no `result none` line" : "no `result` type");
  if (c.version == 2 && !sawContext)
    say(0, "missing-field", "a version 2 contract names its `context`, thread or interrupt");
  // Extern names are unique per contract, and the C symbols too: two externs
  // on one symbol would be two declarations for one provider function.
  {
    StringSet<> seenFn, seenSym;
    for (const auto &e : c.externs) {
      if (!seenFn.insert(e.module + "." + e.fn).second)
        say(0, "duplicate-extern", e.module + "." + e.fn + " is declared twice");
      if (!seenSym.insert(e.symbol).second)
        say(0, "duplicate-extern", "symbol " + e.symbol + " is bound to two externs");
    }
  }

  // ---- count bindings, both directions ------------------------------------
  StringMap<std::string> countOwner; // count parameter -> buffer that claims it
  for (const auto &b : c.buffers) {
    if (b.constCount) continue;  // version 2: the count is the contract's constant
    const ScalarParam *s = c.findScalar(b.countParam);
    if (!s) {
      if (c.findBuffer(b.countParam))
        say(0, "bad-count", "buffer " + b.name + " names " + b.countParam +
                                ", which is a buffer, not a scalar count");
      else
        say(0, "bad-count", "buffer " + b.name + " names count " + b.countParam +
                                ", which is not a declared parameter");
      continue;
    }
    if (s->domain != ScalarDomain::U64)
      say(0, "bad-count", "count " + b.countParam + " for buffer " + b.name +
                              " is declared " + scalarDomainName(s->domain) +
                              "; an element count is u64");
    auto it = countOwner.find(b.countParam);
    if (it != countOwner.end())
      say(0, "shared-count", "buffers " + it->second + " and " + b.name +
                                 " both name " + b.countParam +
                                 "; each buffer carries its own count");
    else
      countOwner[b.countParam] = b.name;
  }
  // The other direction.  Filling countsFor is bookkeeping; the CHECK is that a
  // u64 parameter no buffer claims is refused.  Without it `u64` quietly becomes
  // a general scalar domain at this boundary, which is not what it is for -- it
  // exists to carry an element count.  An earlier version of this file did only
  // the bookkeeping and was reported as having a two-directional check it did
  // not have.
  for (auto &s : c.scalars) {
    auto it = countOwner.find(s.name);
    if (it != countOwner.end()) {
      s.countsFor = it->second;
      continue;
    }
    if (s.domain == ScalarDomain::U64)
      say(0, "unbound-count",
          "parameter " + s.name + " is declared u64 but is not any buffer's count; "
          "u64 is an element count type at this boundary, not a general domain");
  }

  if (bad) return std::nullopt;
  return c;
}

bool resolveBoundaryEntry(BoundaryContract &c,
                          const contract::ContractModule &module,
                          StringRef digest, BoundaryDiagnosticFn diag) {
  bool bad = false;
  auto say = [&](StringRef category, const Twine &detail) {
    diag((c.rootPath + ":0: " + category + ": " + detail).str());
    bad = true;
  };
  c.rootDigest = digest.str();

  // Index the nodes, then walk the PROGRAM'S OWN statement list.  That is what
  // makes a definition unconditional and top level: a `def` inside `if false`
  // is a child of the IfNode and never appears here however it is indented,
  // and a `def` inside a heredoc is part of a string literal and is not a
  // DefNode at all.  Both are accepted by a scan for lines starting `def `.
  llvm::DenseMap<int64_t, const contract::Node *> byId;
  for (const auto &n : module.nodes()) byId[n.id] = &n;
  auto node = [&](int64_t id) -> const contract::Node * {
    auto it = byId.find(id);
    return it == byId.end() ? nullptr : it->second;
  };
  auto field = [&](const contract::Node &n,
                   StringRef key) -> const contract::AstField * {
    for (const auto &f : n.fields)
      if (f.key == key) return &f;
    return nullptr;
  };
  auto refOf = [&](const contract::Node &n, StringRef key) -> int64_t {
    const auto *f = field(n, key);
    return f && f->kind == contract::AstField::Kind::Reference
               ? std::get<int64_t>(f->value) : -1;
  };
  auto strOf = [&](const contract::Node &n, StringRef key) -> std::string {
    const auto *f = field(n, key);
    return f && f->kind == contract::AstField::Kind::String
               ? std::get<std::string>(f->value) : std::string();
  };
  auto arrayOf = [&](const contract::Node &n, StringRef key) -> std::vector<int64_t> {
    const auto *f = field(n, key);
    return f && f->kind == contract::AstField::Kind::Array
               ? std::get<std::vector<int64_t>>(f->value) : std::vector<int64_t>{};
  };

  const contract::Node *program = nullptr;
  for (const auto &n : module.nodes())
    if (n.kind == "ProgramNode") { program = &n; break; }
  if (!program) { say("unresolved-entry", "the analysed source has no program node"); return false; }
  const contract::Node *statements = node(refOf(*program, "statements"));
  if (!statements) { say("unresolved-entry", "the program has no statement list"); return false; }

  const contract::Node *found = nullptr;
  unsigned count = 0;
  for (int64_t id : arrayOf(*statements, "body")) {
    const contract::Node *n = node(id);
    if (!n || n->kind != "DefNode") continue;
    if (refOf(*n, "receiver") != -1) continue;        // `def self.x` is not this
    if (strOf(*n, "name") != c.entry) continue;
    ++count;
    if (!found) found = n;
  }

  if (count == 0) {
    say("unresolved-entry",
        "the snapshot has no unconditional top-level `def " + c.entry + "`");
    return false;
  }
  if (count > 1) {
    say("ambiguous-entry",
        "the snapshot defines " + c.entry + " " + Twine(count) +
            " times at top level; exactly one unconditional definition is required");
    return false;
  }

  // Parameter names, in order, from the AST rather than from the def line's text.
  SmallVector<std::string, 8> params;
  if (const contract::Node *pl = node(refOf(*found, "parameters"))) {
    for (int64_t id : arrayOf(*pl, "requireds"))
      if (const contract::Node *p = node(id)) params.push_back(strOf(*p, "name"));
    // Anything other than plain required parameters is refused rather than
    // ignored: an optional, splat or block parameter has no place in a fixed C
    // signature, and dropping it silently would bind the remaining names to the
    // wrong positions.
    for (const char *other : {"optionals", "rest", "posts", "keywords",
                              "keyword_rest", "block"}) {
      const auto *f = field(*pl, other);
      if (!f) continue;
      bool present =
          (f->kind == contract::AstField::Kind::Array &&
           !std::get<std::vector<int64_t>>(f->value).empty()) ||
          (f->kind == contract::AstField::Kind::Reference &&
           std::get<int64_t>(f->value) != -1);
      if (present)
        say("parameter-form", Twine("`def ") + c.entry + "` has a " + other +
                                  " parameter; only plain required parameters are admitted");
    }
  }

  if (params.size() != c.order.size()) {
    say("parameter-arity",
        "`def " + c.entry + "` takes " + Twine(params.size()) +
            " parameter(s); the contract declares " + Twine(c.order.size()));
    return !bad;
  }
  for (size_t i = 0; i < params.size(); ++i) {
    const auto &o = c.order[i];
    StringRef want = o.kind == Param::Kind::Scalar ? StringRef(c.scalars[o.index].name)
                                                   : StringRef(c.buffers[o.index].name);
    if (StringRef(params[i]) != want)
      say("parameter-name", "parameter " + Twine(i + 1) + " is `" + params[i] +
                                "` in the source and `" + want + "` in the contract");
  }
  return !bad;
}


std::optional<PreparedBoundary> prepareBoundary(StringRef contractPath,
                                                StringRef sourceRoot,
                                                StringRef reader,
                                                BoundaryDiagnosticFn diag,
                                                unsigned targetBits, unsigned profileBits,
                                                StringRef int64Allow) {
  auto buf = MemoryBuffer::getFile(contractPath);
  if (!buf) {
    diag((contractPath + ":0: unresolved-contract: cannot read it").str());
    return std::nullopt;
  }
  auto c = parseBoundaryContract((*buf)->getBuffer(), contractPath, sourceRoot, diag);
  if (!c)
    return std::nullopt;
  {
    SHA256 h;
    h.update((*buf)->getBuffer());
    c->contractDigest = toHex(h.final(), /*LowerCase=*/true);
  }

  // ---- the owned snapshot ------------------------------------------------
  //
  // The bytes are read from the declared path ONCE, copied into a directory
  // this process created, and from then on nothing looks at the declared path
  // again: the digest, the four reader faces and the input ledger all name the
  // copy.
  //
  // Reading the original before and after and comparing does not do this. A
  // file changed to B and back to A between the two reads agrees with itself,
  // and the bytes that were analysed in between were B.  Both reads can also
  // disagree with what the reader opened even when they agree with each other,
  // because the reader is a separate process making its own reads.  Comparing
  // a path to itself authenticates the path, not the analysis.
  //
  // The copy is under `createUniqueDirectory`, so it is a fresh 0700 directory
  // with a name no other process was told; the original may be edited freely
  // from here on and this run is unaffected.
  SmallString<256> srcPath(c->rootResolved);

  // Not memory-mapped: a mapping of the original can change under a read, so
  // even taking the copy could tear.  IsVolatile forces a plain read().
  auto srcBuf = MemoryBuffer::getFile(srcPath, /*IsText=*/false,
                                      /*RequiresNullTerminator=*/false,
                                      /*IsVolatile=*/true);
  if (!srcBuf) {
    diag((contractPath + ":0: unresolved-root: cannot read " + srcPath + ": " +
          srcBuf.getError().message())
             .str());
    return std::nullopt;
  }
  const std::string bytes = (*srcBuf)->getBuffer().str();
  if (!profileBits) profileBits = targetBits;
  const bool declaredInt64 = declaresInt64(bytes);
  // Decision 0019, revised 2026-10-21: a 32-bit target has no 64-bit body
  // unless tools/core/int64-allow.tsv lists the source.
  if (targetBits == 32 && declaredInt64) {
    const Int64Allow allow = int64Allowed(bytes, int64Allow);
    if (!allow.error.empty()) {
      diag((StringRef(srcPath) + ":1: int64-allow-table: " + allow.error).str());
      return std::nullopt;
    }
    if (!allow.listed) {
      diag((StringRef(srcPath) + ":1: int-width-int64-refused: `# spinel: int64` declares a "
                      "64-bit body, the target's pointers are 32 bits, and " + allow.table +
                      " does not list this source; remove the declaration and compute at "
                      "32 bits, or build for a 64-bit target")
               .str());
      return std::nullopt;
    }
  }
  if ((targetBits != 32 && targetBits != 64) ||
      (profileBits != 32 && profileBits != 64) ||
      (profileBits != targetBits && !declaredInt64)) {
    diag((contractPath + ":0: int-width-mismatch: profile and target width disagree").str());
    return std::nullopt;
  }
  const unsigned integerBits = declaredInt64 ? 64 : profileBits;
  if (integerBits == 32) {
    bool wide = c->result && *c->result == ScalarDomain::I64;
    for (const auto &p : c->scalars) if (p.domain == ScalarDomain::I64) wide = true;
    for (const auto &e : c->externs) {
      if (e.returns && *e.returns == ScalarDomain::I64) wide = true;
      for (const auto &a : e.args)
        if (a.kind == Param::Kind::Scalar && a.scalar == ScalarDomain::I64) wide = true;
    }
    if (wide) {
      diag((contractPath + ":0: int-width-boundary: an i64 boundary is refused when Integer is 32 bits; use i32").str());
      return std::nullopt;
    }
  }


  SmallString<256> snapDir;
  if (auto ec = sys::fs::createUniqueDirectory("spinel-core-boundary", snapDir)) {
    diag((contractPath + ":0: snapshot-failed: cannot create a snapshot "
                         "directory: " + ec.message())
             .str());
    return std::nullopt;
  }
  struct DirCleanup {
    StringRef path;
    ~DirCleanup() { sys::fs::remove_directories(path); }
  } cleanup{snapDir};

  // The basename is kept so the reader's diagnostics name a file the reader of
  // those diagnostics recognises.
  SmallString<256> snapPath(snapDir);
  {
    StringRef base = sys::path::filename(srcPath);
    sys::path::append(snapPath, base.empty() ? StringRef("input.rb") : base);
  }
  {
    std::error_code ec;
    raw_fd_ostream out(snapPath, ec, sys::fs::OF_None);
    if (ec) {
      diag((contractPath + ":0: snapshot-failed: cannot write " + snapPath +
            ": " + ec.message())
               .str());
      return std::nullopt;
    }
    out << bytes;
    out.close();
    if (out.has_error()) {
      diag((contractPath + ":0: snapshot-failed: cannot write " + snapPath +
            ": " + out.error().message())
               .str());
      return std::nullopt;
    }
  }
  // Read the snapshot back and compare: a short write would otherwise produce
  // a digest of bytes the reader never saw.  This IS a second read, but of the
  // private copy, and it is checked against the bytes in hand rather than
  // against another read of a path someone else can write to.
  {
    auto back = MemoryBuffer::getFile(snapPath, /*IsText=*/false,
                                      /*RequiresNullTerminator=*/false,
                                      /*IsVolatile=*/true);
    if (!back || (*back)->getBuffer() != bytes) {
      diag((contractPath + ":0: snapshot-failed: the copy of " + srcPath +
            " does not match the bytes that were read")
               .str());
      return std::nullopt;
    }
  }

  // The digest is of the bytes in hand, which are the snapshot's bytes.
  std::string digest;
  {
    SHA256 h;
    h.update(StringRef(bytes));
    digest = toHex(h.final(), /*LowerCase=*/true);
  }

  // Every face, and the input ledger checked against every face, sees the
  // snapshot path.  The ledger constraint is therefore about the same bytes
  // the digest names: a reader that opened anything else -- a required
  // sibling, say, which is not in the snapshot -- is refused rather than
  // quietly contributing to the analysis.
  auto module = loadContract(snapPath, reader, diag, {}, integerBits, /*withPrelude=*/false,
                             {c->entry});
  if (!module) {
    diag((contractPath + ":0: unanalysable-root: the analysis of " + c->rootPath +
          " was refused; see the diagnostics above")
             .str());
    return std::nullopt;
  }

  if (!resolveBoundaryEntry(*c, *module, digest, diag))
    return std::nullopt;

  PreparedBoundary out;
  out.integerBits = integerBits;
  out.contract = std::move(*c);
  out.module = std::move(module);
  return out;
}

std::string boundaryIdentity(const BoundaryContract &c) {
  std::string s;
  raw_string_ostream os(s);
  os << "core-contract/" << c.version << ' ' << c.entry << " -> "
     << (c.result ? scalarDomainName(*c.result) : StringRef("none"));
  if (!c.context.empty()) os << " @" << c.context;
  if (c.scratchBytes) os << " | scratch " << *c.scratchBytes;
  for (const auto &o : c.order) {
    if (o.kind == Param::Kind::Scalar) {
      const auto &p = c.scalars[o.index];
      os << " | " << p.name << ':' << scalarDomainName(p.domain);
      if (!p.countsFor.empty()) os << "=count(" << p.countsFor << ')';
    } else {
      const auto &b = c.buffers[o.index];
      os << " | " << b.name << ':' << elementTypeName(b.element) << '/'
         << accessModeName(b.mode) << '/';
      if (b.constCount) os << "const(" << *b.constCount << ')';
      else os << "count(" << b.countParam << ')';
      if (b.cross) os << "/cross";
    }
  }
  // Version 2: the externs are part of what a header binds to. A provider
  // compiled against one set of prototypes must not link against an object
  // that declared another.
  for (const ExternDecl &e : c.externs) {
    os << " | extern " << e.module << '.' << e.fn << '=' << e.symbol << '(';
    for (size_t i = 0; i < e.args.size(); ++i) {
      if (i) os << ',';
      const ExternArg &a = e.args[i];
      if (a.kind == Param::Kind::Buffer)
        os << elementTypeName(a.element) << '*' << accessModeName(a.mode);
      else
        os << scalarDomainName(a.scalar);
    }
    os << ')' << (e.returns ? scalarDomainName(*e.returns) : StringRef("void"));
  }
  return s;
}

std::string hostTargetLayout() {
  std::string s;
  raw_string_ostream os(s);
  os << "ptr" << (sizeof(void *) * 8) << "-i64-" << (sizeof(long) * 8) << "long";
  return s;
}

unsigned targetPointerBits(StringRef tripleText) {
  return targetIntegerPointerBits(tripleText);
}

std::string targetLayoutFor(StringRef tripleText) {
  const Triple t(tripleText);
  const unsigned ptrBits = targetPointerBits(tripleText);
  // `long` is 64 bits on every 64-bit target except LLP64 Windows, and 32 bits
  // on every 32-bit target, Thumb included.
  const unsigned longBits = ptrBits == 64 && !t.isOSWindows() ? 64 : 32;
  std::string s;
  raw_string_ostream os(s);
  os << "ptr" << ptrBits << "-i64-" << longBits << "long";
  return s;
}

void emitBoundaryHeader(const BoundaryContract &c, StringRef contractPath,
                        StringRef targetLayout, raw_ostream &os) {
  std::string guard;
  for (char ch : c.entry) guard += static_cast<char>(llvm::toUpper(ch));

  os << "/* Generated from " << contractPath << " -- do not edit.\n"
     << " *\n"
     << " * contract identity: " << boundaryIdentity(c) << "\n"
     << " * source snapshot:   " << c.rootPath << "\n"
     << " * snapshot sha256:   " << c.rootDigest << "\n"
     << " * target layout:     " << targetLayout << "\n"
     << " *\n"
     << " * This header DESCRIBES a boundary.  It does not implement one: the\n"
     << " * kernel object is produced separately and must carry the same\n"
     << " * identity and layout, or the two must not be linked.\n"
     << " */\n"
     << "#ifndef SPINEL_CORE_BOUNDARY_" << guard << "_H\n"
     << "#define SPINEL_CORE_BOUNDARY_" << guard << "_H\n\n"
     << "#include <stdint.h>\n\n"
     << "#define SPINEL_CORE_CONTRACT_VERSION " << c.version << "\n"
     << "#define SPINEL_CORE_ENTRY_" << guard << "_IDENTITY \""
     << boundaryIdentity(c) << "\"\n"
     << "#define SPINEL_CORE_ENTRY_" << guard << "_SNAPSHOT \"" << c.rootDigest << "\"\n"
     << "#define SPINEL_CORE_ENTRY_" << guard << "_LAYOUT \"" << targetLayout << "\"\n\n"
     << "/* status values; see decision 0007.  These are this ABI's own numbers\n"
     << " * and are never a predecessor trap code forwarded through.\n"
     << " *\n"
     << " * Guarded separately from this header's own guard: two entries'\n"
     << " * headers can be included in one translation unit, and an enum\n"
     << " * defined twice there is a redefinition error. */\n"
     << "#ifndef SPINEL_CORE_STATUS_DEFINED\n"
     << "#define SPINEL_CORE_STATUS_DEFINED 1\n"
     << "enum {\n"
     << "  SPINEL_CORE_OK = 0,\n"
     << "  SPINEL_CORE_ARGUMENT = 1,\n"
     << "  SPINEL_CORE_ARITHMETIC = 2,\n"
     << "  SPINEL_CORE_BOUNDS = 3,\n"
     << "  SPINEL_CORE_CAPACITY = 4\n"
     << "};\n"
     << "#endif\n\n";

  // The prototype's parameter identifiers are GENERATED and positional; the
  // contract's own names appear beside them in comments.
  //
  // A parameter name is documentation in a C prototype -- it has no ABI and no
  // meaning at a call site -- but it is a declaration, so it shadows anything
  // of that name for the rest of the parameter list.  A contract parameter
  // named `int32_t` or `size_t` therefore turns the NEXT parameter that uses
  // that typedef into a syntax error, and the header simply does not compile.
  //
  // This is not fixed by refusing such names, because the names that break it
  // are the consumer's typedefs, and a generator cannot enumerate the typedefs
  // of translation units that do not exist yet.  Not emitting a contract name
  // into C's namespace at all is the only rule that holds for every consumer.
  std::vector<std::string> decls;
  std::vector<std::string> notes;
  for (const auto &o : c.order) {
    std::string d, n;
    raw_string_ostream ds(d), ns(n);
    const size_t slot = decls.size();
    if (o.kind == Param::Kind::Scalar) {
      const auto &p = c.scalars[o.index];
      ds << scalarCType(p.domain) << " sp_arg" << slot;
      ns << p.name << " (" << scalarDomainName(p.domain);
      if (!p.countsFor.empty()) ns << ", element count of " << p.countsFor;
      ns << ')';
    } else {
      const auto &b = c.buffers[o.index];
      if (b.mode == AccessMode::In) ds << "const ";
      ds << elementCType(b.element) << " *sp_arg" << slot;
      ns << b.name << " (" << elementTypeName(b.element) << ' '
         << accessModeName(b.mode) << ", count "
         << (b.constCount ? "const " + std::to_string(*b.constCount) + (b.cross ? ", cross" : "")
                          : b.countParam)
         << ')';
    }
    decls.push_back(d);
    notes.push_back(n);
  }
  if (c.scratchBytes) {
    decls.push_back("void *sp_arg" + std::to_string(decls.size()));
    notes.push_back("scratch (" + std::to_string(*c.scratchBytes) +
                    " bytes, the context's data stack; first word the bump offset)");
  }
  if (c.result) {
    decls.push_back((Twine(scalarCType(*c.result)) + " *sp_result").str());
    notes.push_back((Twine("result (") + scalarDomainName(*c.result) + ")").str());
  }

  os << "/* Each buffer carries its own element count; no count is shared.\n"
     << " * A zero count permits a NULL pointer; a nonzero count requires a\n"
     << " * non-NULL, suitably aligned one.  The result is written only on\n"
     << " * SPINEL_CORE_OK and must not alias any buffer.\n"
     << " *\n"
     << " * Parameter identifiers below are generated and positional.  The\n"
     << " * contract's names are in the comments: a declared name that happens\n"
     << " * to be one of the including unit's typedefs would shadow it for the\n"
     << " * rest of this parameter list, and a generator cannot know which\n"
     << " * names those are.  Parameter names carry no ABI. */\n"
     << "int32_t spinel_core_" << c.entry << "(";
  if (decls.empty()) {
    os << "void);\n\n#endif\n";
    return;
  }
  size_t widest = 0;
  for (const auto &d : decls) widest = std::max(widest, d.size());
  const std::string indent(21 + c.entry.size(), ' ');
  for (size_t i = 0; i < decls.size(); ++i) {
    const bool last = i + 1 == decls.size();
    const std::string tail = last ? ");" : ",";
    if (i) os << indent;
    os << decls[i] << tail
       << std::string(widest - decls[i].size() + (last ? 1 : 2), ' ')
       << "/* " << notes[i] << " */\n";
  }
  os << "\n#endif\n";
}

} // namespace spinel_mlir::core

namespace spinel_mlir::core {

void emitExternHeader(const BoundaryContract &c, StringRef contractPath, raw_ostream &os) {
  std::string guard;
  for (char ch : c.entry) guard += static_cast<char>(llvm::toUpper(ch));
  os << "/* Generated by spinel-core-kernel from " << sys::path::filename(contractPath)
     << " (decision 0014).\n"
     << " * The externs the entry `" << c.entry << "` calls, with the C ABI of the\n"
     << " * 0014 plan: a scalar is int32_t, uint32_t or int64_t by its domain; a\n"
     << " * buffer is a pointer followed by its element count as uint32_t, and an\n"
     << " * `in` buffer is const.  A provider includes this header and defines\n"
     << " * these functions; a definition that disagrees with a prototype does not\n"
     << " * compile, which is the signature check.  Do not edit. */\n"
     << "#ifndef SPINEL_CORE_EXTERNS_" << guard << "_H\n"
     << "#define SPINEL_CORE_EXTERNS_" << guard << "_H\n\n"
     << "#include <stdint.h>\n\n"
     << "#define SPINEL_CORE_EXTERNS_" << guard << "_IDENTITY \"" << boundaryIdentity(c) << "\"\n\n";
  for (const ExternDecl &e : c.externs) {
    os << "/* " << e.module << '.' << e.fn;
    if (e.isrOk) os << ", isr_ok";
    os << "; " << e.bound;
    for (const Guard &g : e.guards)
      os << "; guard " << g.lhs << ' ' << g.op << ' ' << g.rhs << " else " << g.onFalse;
    os << " */\n";
    os << (e.returns ? scalarCType(*e.returns) : StringRef("void")) << ' ' << e.symbol << '(';
    if (e.args.empty()) os << "void";
    for (size_t i = 0; i < e.args.size(); ++i) {
      const ExternArg &a = e.args[i];
      if (i) os << ", ";
      if (a.kind == Param::Kind::Buffer) {
        if (a.mode == AccessMode::In) os << "const ";
        os << elementCType(a.element) << " *" << a.name << ", uint32_t " << a.name << "_len";
      } else {
        os << scalarCType(a.scalar) << ' ' << a.name;
      }
    }
    os << ");\n";
  }
  os << "\n#endif\n";
}

} // namespace spinel_mlir::core
