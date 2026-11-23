// Native static half of freestanding ABI checking, replacing product abi-check.py rather than an
// oracle. Preserve CLI/output/exit: --abi kern.ll header.h triple [--symbol NAME]... [cflags...];
// stdout header verdict/symbol/from_c_header/from_kernel_ir plus rows; mismatch returns 1. Recorded
// differential checks establish byte identity. Compile a C translation unit containing header
// prototypes with the same clang/target flags as kernel generation; compare resulting LLVM
// signatures with kernel IR. Width/arity/signext/zeroext/byval/sret/align mismatches would silently
// miscompile at link time.
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using llvm::StringRef;

namespace {

// Keep ABI attributes: signext/zeroext determine upper register bits; byval/sret/inreg/align
// determine argument placement. Drop optimizer-only noundef/nonnull/nocapture/readonly facts:
// differing in these alone does not prevent ABI-compatible linking.
bool isAbiAttr(StringRef t) {
  return t == "signext" || t == "zeroext" || t == "byval" || t == "sret" ||
         t == "inreg" || t == "inalloca" || t == "preallocated" ||
         t == "nest" || t == "returned";
}

// Keep payload with tags such as align 4, byval(%struct.x), sret(...).
bool isAbiPattern(StringRef t) {
  if (t.starts_with("byval(") && t.ends_with(")")) return true;
  if (t.starts_with("sret(") && t.ends_with(")")) return true;
  return false;
}

std::vector<std::string> splitWs(StringRef s) {
  std::vector<std::string> out;
  llvm::SmallVector<StringRef, 16> parts;
  s.split(parts, ' ', -1, false);
  for (StringRef p : parts)
    if (!p.trim().empty())
      out.push_back(p.trim().str());
  return out;
}

// Preserve frozen _attrs selection and ordering.
std::vector<std::string> abiAttrs(const std::vector<std::string> &toks) {
  std::vector<std::string> out;
  for (size_t i = 0; i < toks.size();) {
    StringRef t = toks[i];
    if (isAbiAttr(t)) {
      if (t == "align" && i + 1 < toks.size()) {
        out.push_back(("align " + toks[i + 1]));
        i += 2;
        continue;
      }
      out.push_back(t.str());
    } else if (t == "align" && i + 1 < toks.size()) {
      out.push_back(("align " + toks[i + 1]));
      i += 2;
      continue;
    } else if (isAbiPattern(t)) {
      out.push_back(t.str());
    }
    ++i;
  }
  return out;
}

std::string join(const std::vector<std::string> &v, StringRef sep) {
  std::string s;
  for (size_t i = 0; i < v.size(); ++i) {
    if (i) s += sep.str();
    s += v[i];
  }
  return s;
}

// Frozen sigs(text,kinds): inspect define/declare lines only, normalizing return attributes and
// parameter list.
std::map<std::string, std::string> sigsOf(StringRef text,
                                          llvm::ArrayRef<StringRef> kinds) {
  std::map<std::string, std::string> out;
  llvm::SmallVector<StringRef, 256> lines;
  text.split(lines, '\n');
  for (StringRef line : lines) {
    bool kindOk = false;
    for (StringRef k : kinds)
      if (line.starts_with(k)) kindOk = true;
    if (!kindOk) continue;
    // Manually parse define/declare, head, symbol and parenthesized arguments.
    size_t at = line.find('@');
    if (at == StringRef::npos) continue;
    size_t open = line.find('(', at);
    if (open == StringRef::npos) continue;
    size_t close = line.find(')', open);
    if (close == StringRef::npos) continue;
    StringRef name = line.slice(at + 1, open);
    if (name.empty()) continue;
    if (!(isalpha(static_cast<unsigned char>(name[0])) || name[0] == '_'))
      continue;
    bool ident = true;
    for (char c : name)
      if (!(isalnum(static_cast<unsigned char>(c)) || c == '_')) ident = false;
    if (!ident) continue;
    // head spans from immediately after the kind to before @.
    size_t headStart = line.find(' ');
    if (headStart == StringRef::npos || headStart >= at) continue;
    StringRef head = line.slice(headStart + 1, at);
    StringRef params = line.slice(open + 1, close);

    std::vector<std::string> htoks = splitWs(head);
    if (htoks.empty()) continue;
    std::vector<std::string> retParts = abiAttrs(htoks);
    retParts.push_back(htoks.back());
    std::string ret = join(retParts, " ");

    std::vector<std::string> ps;
    llvm::SmallVector<StringRef, 16> rawParams;
    params.split(rawParams, ',');
    for (StringRef p : rawParams) {
      p = p.trim();
      if (p.empty()) continue;
      std::vector<std::string> toks = splitWs(p);
      if (toks.empty()) continue;
      std::vector<std::string> one{toks[0]};
      std::vector<std::string> rest(toks.begin() + 1, toks.end());
      for (auto &a : abiAttrs(rest)) one.push_back(a);
      ps.push_back(join(one, " "));
    }
    out[name.str()] = ret + " (" + join(ps, ", ") + ")";
  }
  return out;
}

bool isCIdentifier(StringRef s) {
  if (s.empty()) return false;
  if (!(isalpha(static_cast<unsigned char>(s[0])) || s[0] == '_')) return false;
  for (char c : s)
    if (!(isalnum(static_cast<unsigned char>(c)) || c == '_')) return false;
  return true;
}

// Find a NAME followed by an opening parenthesis in the header.
bool headerDeclares(StringRef text, StringRef name) {
  size_t pos = 0;
  while ((pos = text.find(name, pos)) != StringRef::npos) {
    bool leftOk = pos == 0 ||
                  !(isalnum(static_cast<unsigned char>(text[pos - 1])) ||
                    text[pos - 1] == '_');
    size_t after = pos + name.size();
    size_t q = after;
    while (q < text.size() && (text[q] == ' ' || text[q] == '\t')) ++q;
    if (leftOk && q < text.size() && text[q] == '(') return true;
    pos = after;
  }
  return false;
}

// Frozen SystemExit(message) means rc 1, not 2. Equal wording with different status changes caller
// branching; comparison exposed this.
int fail(StringRef msg) {
  llvm::errs() << "abi-check: " << msg << "\n";
  return 1;
}

} // namespace

int runAbiCli(int argc, char **argv) {
  // argv[0]=prog, argv[1]=--abi, argv[2]=kern.ll, argv[3]=header, argv[4]=triple
  if (argc < 5)
    return fail("usage: spinel-fs-check --abi <kern.ll> <header.h> <triple> "
                "[--symbol NAME]... [cflags...]");
  std::string kernLl = argv[2], header = argv[3], triple = argv[4];
  std::vector<std::string> wanted, cflags;
  for (int i = 5; i < argc; ++i) {
    StringRef a = argv[i];
    if (a == "--symbol") {
      if (i + 1 >= argc) return fail("--symbol needs a NAME");
      wanted.push_back(argv[++i]);
      continue;
    }
    if (a.starts_with("--symbol=")) {
      wanted.push_back(a.drop_front(strlen("--symbol=")).str());
      continue;
    }
    cflags.push_back(a.str());
  }

  auto headerBuf = llvm::MemoryBuffer::getFile(header);
  if (!headerBuf) return fail("cannot read the header: " + header);
  std::string text = headerBuf->get()->getBuffer().str();

  std::vector<std::string> names;
  if (!wanted.empty()) {
    // Require requested names to be C identifiers here, preserving a named refusal before compiler
    // invocation.
    for (auto &n : wanted)
      if (!isCIdentifier(n))
        return fail("--symbol '" + n + "' is not a C identifier");
    // Deduplicate requested symbols so repeated flags do not inflate the table.
    for (auto &n : wanted)
      if (!llvm::is_contained(names, n)) names.push_back(n);
    if (names.empty()) return fail("--symbol given but the request is empty");
  } else {
    // Legacy discovery: all spinel_* prototypes except the trap hook. Scope is exactly that prefix.
    StringRef t(text);
    size_t pos = 0;
    while ((pos = t.find("spinel_", pos)) != StringRef::npos) {
      bool leftOk = pos == 0 ||
                    !(isalnum(static_cast<unsigned char>(t[pos - 1])) ||
                      t[pos - 1] == '_');
      size_t e = pos;
      while (e < t.size() &&
             (isalnum(static_cast<unsigned char>(t[e])) || t[e] == '_')) ++e;
      size_t q = e;
      while (q < t.size() && (t[q] == ' ' || t[q] == '\t')) ++q;
      if (leftOk && q < t.size() && t[q] == '(') {
        std::string n = t.slice(pos, e).str();
        if (!llvm::is_contained(names, n)) names.push_back(n);
      }
      pos = e;
    }
    // Exclude the void name(int32_t code,...) trap hook.
    std::string hook = "spinel_trap";
    size_t hp = text.find("(int32_t code,");
    if (hp != std::string::npos) {
      size_t open = text.rfind('(', hp + 1);
      if (open != std::string::npos) {
        size_t s = open;
        while (s > 0 && (isalnum(static_cast<unsigned char>(text[s - 1])) ||
                         text[s - 1] == '_')) --s;
        if (s < open) hook = text.substr(s, open - s);
      }
    }
    names.erase(std::remove(names.begin(), names.end(), hook), names.end());
  }

  // Header-missing names cannot enter the probe TU or compilation would fail generically without
  // naming them. Set them aside and report MISSING.
  std::vector<std::string> probe;
  for (auto &n : names)
    if (headerDeclares(text, n)) probe.push_back(n);

  llvm::SmallString<128> td;
  if (llvm::sys::fs::createUniqueDirectory("spinel-abi", td))
    return fail("cannot create a temporary directory");
  auto cleanup = llvm::make_scope_exit([&] { llvm::sys::fs::remove_directories(td); });

  llvm::SmallString<128> cPath(td), llPath(td);
  llvm::sys::path::append(cPath, "caller.c");
  llvm::sys::path::append(llPath, "caller.ll");
  {
    std::error_code ec;
    llvm::raw_fd_ostream os(cPath, ec);
    if (ec) return fail("cannot write the probe TU");
    llvm::SmallString<128> abs(header);
    llvm::sys::fs::make_absolute(abs);
    os << "#include \"" << abs << "\"\n";
    os << "void spinel_abi_use(void) {\n";
    for (auto &n : probe) os << "  (void)" << n << ";\n";
    os << "}\n";
  }

  std::string clang = getenv("SPINEL_ABI_CLANG") ? getenv("SPINEL_ABI_CLANG") : "";
  if (clang.empty()) {
    const char *llvmDir = getenv("LLVM");
    if (!llvmDir) llvmDir = getenv("LLVM_PREFIX");
    clang = llvmDir ? (std::string(llvmDir) + "/bin/clang") : std::string("clang");
  }
  std::vector<StringRef> args{clang};
  std::string tgt = "--target=" + triple;
  args.push_back(tgt);
  for (auto &f : cflags) args.push_back(f);
  args.push_back("-ffreestanding");
  args.push_back("-fno-builtin");
  args.push_back("-O0");
  args.push_back("-S");
  args.push_back("-emit-llvm");
  args.push_back("-o");
  args.push_back(llPath);
  args.push_back(cPath);
  std::string err;
  int rc = llvm::sys::ExecuteAndWait(clang, args, std::nullopt, {}, 0, 0, &err);
  if (rc != 0)
    return fail("the generated header does not compile for " + triple);

  auto callerBuf = llvm::MemoryBuffer::getFile(llPath);
  if (!callerBuf) return fail("cannot read the probe's IR");
  StringRef declareKind[] = {"declare"};
  StringRef defineKind[] = {"define"};
  auto want = sigsOf(callerBuf->get()->getBuffer(), declareKind);

  auto kernBuf = llvm::MemoryBuffer::getFile(kernLl);
  if (!kernBuf) return fail("cannot read the kernel's IR: " + kernLl);
  StringRef kernText = kernBuf->get()->getBuffer();
  auto got = sigsOf(kernText, defineKind);
  // Callable platform externs are declarations in kernel IR: platform defines them, kernel calls
  // them. Compare the caller assumed LLVM declaration with the C-header prototype.
  auto gotDecl = sigsOf(kernText, declareKind);

  int bad = 0;
  llvm::outs() << "verdict\tsymbol\tfrom_c_header\tfrom_kernel_ir\n";
  for (auto &n : names) {
    auto wi = want.find(n);
    auto gi = got.find(n);
    const std::string *w = wi == want.end() ? nullptr : &wi->second;
    const std::string *g = gi == got.end() ? nullptr : &gi->second;
    if (!g) {
      auto di = gotDecl.find(n);
      if (di != gotDecl.end()) g = &di->second;
    }
    auto show = [](const std::string *p) { return p ? StringRef(*p) : StringRef("None"); };
    if (!w || !g) {
      llvm::outs() << "MISSING\t" << n << "\t" << show(w) << "\t" << show(g) << "\n";
      ++bad;
    } else if (*w != *g) {
      llvm::outs() << "MISMATCH\t" << n << "\t" << *w << "\t" << *g << "\n";
      ++bad;
    } else {
      llvm::outs() << "MATCH\t" << n << "\t" << *w << "\t" << *g << "\n";
    }
  }
  if (bad)
    llvm::errs() << "abi-check: " << bad << " signature(s) disagree\n";
  return bad ? 1 : 0;
}
