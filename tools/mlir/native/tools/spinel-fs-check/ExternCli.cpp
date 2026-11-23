// Check platform-wrapper signatures against profile extern declarations, replacing product
// extern-check.py. Preserve verdict/symbol/declared/wrapper/reason TSV and rc 1 if any row is not
// MATCH. Usage: --extern --profile profile.yaml wrapper.c+. Scope: signatures only, not bodies;
// behavior requires an oracle. Ignore undeclared symbols owned by the platform. Strip
// comments/preprocessor lines but do not expand macros, so macro-built signatures are outside
// scope. Historical limitation: platform-first profiles need the ledger and this initial path
// handled legacy corpus profiles only.
#include "spinel-mlir/Freestanding/Diagnostics.h"
#include "spinel-mlir/Freestanding/Profile.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <map>
#include <string>
#include <vector>

using llvm::StringRef;
namespace fs = spinel_mlir::freestanding;

namespace {

// Accept only generated-header C spellings, not aliases such as ABI-equivalent long long. This is
// not a C frontend; generated headers have exactly one spelling.
StringRef cToBoundary(StringRef t) {
  if (t == "int32_t") return "i32";
  if (t == "uint32_t") return "u32";
  if (t == "int64_t") return "i64";
  if (t == "float") return "f32";
  if (t == "double") return "f64";
  return {};
}
const char *kSpellings = "double float int32_t int64_t uint32_t";

// Strip comments/preprocessor lines and blank strings so printk format symbols do not resemble
// definitions.
std::string stripC(StringRef in) {
  std::string s;
  s.reserve(in.size());
  for (size_t i = 0; i < in.size();) {
    if (in.substr(i).starts_with("/*")) {
      size_t e = in.find("*/", i + 2);
      s += ' ';
      i = e == StringRef::npos ? in.size() : e + 2;
      continue;
    }
    if (in.substr(i).starts_with("//")) {
      size_t e = in.find('\n', i);
      s += ' ';
      i = e == StringRef::npos ? in.size() : e;
      continue;
    }
    if (in[i] == '"') {
      s += "\"\"";
      ++i;
      while (i < in.size() && in[i] != '"') {
        if (in[i] == '\\' && i + 1 < in.size()) ++i;
        ++i;
      }
      if (i < in.size()) ++i;
      continue;
    }
    s += in[i];
    ++i;
  }
  // Drop lines starting with # after optional leading whitespace.
  std::string out;
  size_t pos = 0;
  while (pos <= s.size()) {
    size_t e = s.find('\n', pos);
    StringRef line(s.data() + pos, (e == std::string::npos ? s.size() : e) - pos);
    out += line.ltrim().starts_with("#") ? " " : line.str();
    out += '\n';
    if (e == std::string::npos) break;
    pos = e + 1;
  }
  return out;
}

std::vector<std::string> tokens(StringRef s) {
  std::vector<std::string> out;
  std::string cur;
  for (char c : s) {
    if (isspace(static_cast<unsigned char>(c))) {
      if (!cur.empty()) { out.push_back(cur); cur.clear(); }
    } else if (c == '*') {
      if (!cur.empty()) { out.push_back(cur); cur.clear(); }
      out.push_back("*");
    } else {
      cur += c;
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

std::string join(const std::vector<std::string> &v, const char *sep) {
  std::string s;
  for (size_t i = 0; i < v.size(); ++i) { if (i) s += sep; s += v[i]; }
  return s;
}

// Tokens to boundary type/reason; empty type means failure.
std::pair<std::string, std::string> parseType(std::vector<std::string> toks,
                                              const std::string &what) {
  std::vector<std::string> t;
  for (auto &x : toks)
    if (x != "const" && x != "volatile") t.push_back(x);
  for (auto &x : t)
    if (x == "static")
      return {"", what + " is declared `static` -- the kernel cannot link to it"};
  std::vector<std::string> u;
  for (auto &x : t)
    if (x != "extern" && x != "inline") u.push_back(x);
  if (u.size() != 1)
    return {"", what + " spells `" + (u.empty() ? "<nothing>" : join(u, " ")) +
                    "`, which is not one of the stdint spellings the generated "
                    "header uses (" + kSpellings + ")"};
  StringRef b = cToBoundary(u[0]);
  if (b.empty())
    return {"", what + " spells `" + u[0] +
                    "`, which is not one of the stdint spellings the generated "
                    "header uses (" + kSpellings + ")"};
  return {b.str(), ""};
}

struct Hit {
  std::string params;
  std::vector<std::string> ret;
  bool isDef = false;
  bool found = false;
};

// Find a definition, falling back to prototype. Definitions win because wrapper TUs may include the
// generated prototype too.
Hit findDefinition(StringRef text, StringRef sym) {
  Hit best;
  size_t pos = 0;
  while ((pos = text.find(sym, pos)) != StringRef::npos) {
    size_t before = pos;
    bool leftOk = pos == 0 || !(isalnum(static_cast<unsigned char>(text[pos - 1])) ||
                                text[pos - 1] == '_');
    size_t after = pos + sym.size();
    size_t q = after;
    while (q < text.size() && isspace(static_cast<unsigned char>(text[q]))) ++q;
    if (!leftOk || q >= text.size() || text[q] != '(') { pos = after; continue; }
    size_t close = text.find(')', q);
    if (close == StringRef::npos) { pos = after; continue; }
    // Nested parentheses in arguments (e.g. function pointers) are outside scope.
    if (text.slice(q + 1, close).contains('(')) { pos = after; continue; }
    size_t t = close + 1;
    while (t < text.size() && isspace(static_cast<unsigned char>(text[t]))) ++t;
    if (t >= text.size() || (text[t] != ';' && text[t] != '{')) { pos = after; continue; }
    // Return type begins after the preceding semicolon or brace and ends at the symbol.
    size_t s = text.find_last_of(";}{", before ? before - 1 : 0);
    s = (s == StringRef::npos) ? 0 : s + 1;
    Hit h;
    h.params = text.slice(q + 1, close).str();
    h.ret = tokens(text.slice(s, before));
    h.isDef = text[t] == '{';
    h.found = true;
    if (h.isDef) return h;
    if (!best.found) best = h;
    pos = after;
  }
  return best;
}

// Canonical wrapper direction: :in requires const pointer, letting the C compiler independently
// enforce readonly; :out/:inout require mutable pointers. C need not distinguish the latter two; it
// must not promise const that it cannot honor.
std::string expectedWrapper(const fs::FsParam &p) {
  if (p.kind == fs::FsParam::Kind::Buffer)
    return p.type + "_buf:" + (p.direction == "in" ? "const" : "mut");
  if (p.kind == fs::FsParam::Kind::Len) return "i32";
  return p.type;
}

} // namespace

int runExternCli(int argc, char **argv) {
  std::string profilePath;
  std::vector<std::string> sources;
  for (int i = 2; i < argc; ++i) {
    StringRef a = argv[i];
    if (a == "--profile") {
      if (i + 1 >= argc) { llvm::errs() << "extern-check: --profile needs PATH\n"; return 2; }
      profilePath = argv[++i];
      continue;
    }
    sources.push_back(a.str());
  }
  if (profilePath.empty() || sources.empty()) {
    llvm::errs() << "usage: spinel-fs-check --extern --profile <profile.yaml> "
                    "<wrapper.c>+\n";
    return 2;
  }

  auto yaml = llvm::MemoryBuffer::getFile(profilePath);
  if (!yaml) {
    llvm::errs() << "extern-check: cannot read the profile: " << profilePath << "\n";
    return 2;
  }
  std::string diagText;
  auto profile = fs::readFreestandingProfile(
      profilePath, yaml->get()->getBuffer(),
      [&](const fs::Rejection &r) { diagText += fs::formatRejection(r); diagText += "\n"; });
  if (!profile) {
    llvm::errs() << diagText;
    return 2;
  }

  std::string text;
  for (auto &s : sources) {
    auto buf = llvm::MemoryBuffer::getFile(s);
    if (!buf) {
      llvm::errs() << "extern-check: cannot read the wrapper: " << s << "\n";
      return 2;
    }
    text += stripC(buf->get()->getBuffer());
    text += "\n";
  }

  // Ascending symbol order, matching sorted(decls).
  std::map<std::string, const fs::FsExtern *> decls;
  for (const auto &e : profile->externs()) decls[e.symbol] = &e;

  llvm::outs() << "verdict\tsymbol\tdeclared\twrapper\treason\n";
  if (decls.empty()) {
    llvm::outs() << "INFO\t-\t-\t-\tthe profile declares no callable platform "
                    "externs (nothing to check)\n";
    return 0;
  }

  int bad = 0;
  for (auto &kv : decls) {
    const std::string &sym = kv.first;
    const fs::FsExtern &d = *kv.second;
    std::vector<std::string> dparams;
    for (const auto &p : d.params) {
      if (p.kind == fs::FsParam::Kind::Buffer) dparams.push_back(p.type + "_buf:" + p.direction);
      else if (p.kind == fs::FsParam::Kind::Len) dparams.push_back("len");
      else dparams.push_back(p.type);
    }
    std::string declared =
        sym + "(" + (dparams.empty() ? "void" : join(dparams, ",")) + ") -> " + d.returns;
    auto emit = [&](StringRef verdict, StringRef wrapper, const std::string &reason) {
      if (verdict != "MATCH") ++bad;
      llvm::outs() << verdict << "\t" << sym << "\t" << declared << "\t"
                   << wrapper << "\t" << reason << "\n";
    };

    Hit hit = findDefinition(text, sym);
    if (!hit.found) {
      emit("MISSING", "-",
           "no definition of " + sym + " in the given wrapper source(s)");
      continue;
    }
    if (join(hit.ret, " ").find('*') != std::string::npos) {
      emit("MISMATCH", "-",
           "pointer RETURN in the signature of " + sym +
               " -- a buffer cannot be returned across this boundary (E077/E083)");
      continue;
    }
    if (!hit.isDef) {
      emit("MISSING", "-",
           sym + " is only a prototype here; the wrapper TU must DEFINE it");
      continue;
    }
    auto [ret, why] = parseType(hit.ret, "the return type of " + sym);
    if (ret.empty()) { emit("MISMATCH", "-", why); continue; }

    std::vector<std::string> wparams;
    StringRef ptext = StringRef(hit.params).trim();
    bool bailed = false;
    if (!ptext.empty() && ptext != "void") {
      llvm::SmallVector<StringRef, 8> raw;
      ptext.split(raw, ',');
      for (size_t i = 0; i < raw.size(); ++i) {
        std::vector<std::string> toks = tokens(raw[i]);
        // Drop trailing argument names from int32_t pin; leave unnamed one-token prototypes
        // unchanged.
        if (toks.size() >= 2) {
          const std::string &last = toks.back();
          if (cToBoundary(last).empty() && last != "const" && last != "volatile" &&
              last != "*")
            toks.pop_back();
        }
        bool hasPtr = false;
        for (auto &t : toks) if (t == "*") hasPtr = true;
        std::string what = "parameter " + std::to_string(i + 1) + " of " + sym;
        if (hasPtr) {
          bool isConst = false;
          std::vector<std::string> base;
          for (auto &t : toks) {
            if (t == "const") { isConst = true; continue; }
            if (t == "*" || t == "volatile" || t == "extern" || t == "inline") continue;
            base.push_back(t);
          }
          for (auto &t : base)
            if (t == "static") {
              emit("MISMATCH", "-", what + " is declared `static`");
              bailed = true;
              break;
            }
          if (bailed) break;
          if (base.size() != 1 || cToBoundary(base[0]).empty()) {
            emit("MISMATCH", "-",
                 what + " spells `" + StringRef(raw[i]).trim().str() +
                     "`, whose base type is not one of the stdint spellings the "
                     "generated header uses (" + kSpellings + ")");
            bailed = true;
            break;
          }
          wparams.push_back(cToBoundary(base[0]).str() + "_buf:" +
                            (isConst ? "const" : "mut"));
          continue;
        }
        auto [t, w] = parseType(toks, what);
        if (t.empty()) { emit("MISMATCH", "-", w); bailed = true; break; }
        wparams.push_back(t);
      }
    }
    if (bailed) continue;

    std::string wrapper =
        sym + "(" + (wparams.empty() ? "void" : join(wparams, ",")) + ") -> " + ret;
    std::vector<std::string> expect;
    for (const auto &p : d.params) expect.push_back(expectedWrapper(p));
    if (wparams != expect || ret != d.returns)
      emit("MISMATCH", wrapper, "the wrapper's signature does not spell the declaration");
    else
      emit("MATCH", wrapper, "declaration and wrapper agree");
  }
  if (bad)
    llvm::errs() << "extern-check: " << bad << " of " << decls.size()
                 << " declared extern(s) do not agree with the wrapper\n";
  return bad ? 1 : 0;
}
