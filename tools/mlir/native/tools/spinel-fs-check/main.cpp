// Freestanding admission-only CLI: profile YAML P1/P2, four typedump faces and readContract seal,
// declarations D1/D2, then bodies B/C. Exit 0 accepted, 1 refused, 2 usage. Refusal is one stderr
// line spinel-fs:<stage>: <category>: <subject|->: [arg=n ]detail. No objects: this stage checks
// categories, not generation. Missing profile/typedump/faces fail by name without fallback or
// guessed subprocess paths.
#include "spinel-mlir/Contract/Reader.h"
#include "spinel-mlir/Freestanding/Declaration.h"
#include "spinel-mlir/Freestanding/PlatformLedger.h"
#include "spinel-mlir/Freestanding/Profile.h"
#include "spinel-mlir/Freestanding/UndefGate.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

using namespace llvm;
using namespace spinel_mlir;

namespace {

int usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " --profile <profile.yaml> --source <kernel.rb>"
            " [--typedump <path>] [--menus <menus.yaml>]\n"
         << "   or: " << argv0
         << " --abi <kern.ll> <header.h> <triple> [--symbol NAME]... [cflags...]\n"
         << "   or: " << argv0
         << " --extern --profile <profile.yaml> <wrapper.c>+\n"
         << "   or: " << argv0
         << " --undef [--profile <profile.yaml>]"
            " [--libc none|zephyr-minimal|picolibc]\n"
            "        [--libm none|picolibc] [--compiler-rt allow|deny]"
            " [--triple <triple>]\n"
            "        [--platform-extern <SYM>]* [--quiet] <obj>+\n";
  return 2;
}

void fail(StringRef category, const Twine &detail) {
  errs() << "spinel-fs-check: " << category << ": " << detail << "\n";
}

class ScopedTempDir {
public:
  ~ScopedTempDir() {
    if (!path_.empty())
      sys::fs::remove_directories(path_);
  }
  std::error_code create() {
    SmallString<128> model;
    sys::path::system_temp_directory(/*ErasedOnReboot=*/true, model);
    sys::path::append(model, "spinel-fs-check");
    return sys::fs::createUniqueDirectory(model, path_);
  }
  std::string file(StringRef name) const {
    SmallString<128> p(path_);
    sys::path::append(p, name);
    return std::string(p);
  }

private:
  SmallString<128> path_;
};

// Find typedump by walking ancestors of the executable real path to the first existing
// tools/contract/build/spinel-typedump. Return empty for caller refusal rather than launching a
// guessed path.
std::string defaultTypedumpPath(const char *argv0) {
  std::string exe = sys::fs::getMainExecutable(
      argv0, reinterpret_cast<void *>(&defaultTypedumpPath));
  if (exe.empty())
    return {};
  SmallString<128> dir(sys::path::parent_path(exe));
  while (!dir.empty()) {
    SmallString<128> candidate(dir);
    sys::path::append(candidate, "tools", "contract", "build",
                      "spinel-typedump");
    if (sys::fs::exists(candidate))
      return std::string(candidate);
    StringRef parent = sys::path::parent_path(dir);
    if (parent == dir)
      break;
    dir = parent;
  }
  return {};
}

bool runTypedump(StringRef tool, StringRef source, StringRef mode,
                 StringRef outPath, StringRef errPath) {
  StringRef args[] = {tool, source, mode};
  std::optional<StringRef> redirects[] = {StringRef(""), outPath, errPath};
  std::string execError;
  int rc = sys::ExecuteAndWait(tool, args, /*Env=*/std::nullopt, redirects,
                               /*SecondsToWait=*/0, /*MemoryLimit=*/0,
                               &execError);
  if (rc == 0)
    return true;
  if (!execError.empty())
    fail("typedump-failed", "cannot run " + tool + ": " + execError);
  else
    fail("typedump-failed",
         "spinel-typedump " + source + " " + mode + " exited with " + Twine(rc));
  if (auto buf = MemoryBuffer::getFile(errPath))
    errs() << (*buf)->getBuffer();
  return false;
}

// Standalone undefined-symbol gate preserves frozen CLI/TSV/status, extending previously checked
// generation behavior to direct object input used by five existing lanes.
int runUndefCli(int argc, char **argv) {
  std::string profilePath, libc, libm, compilerRt, triple;
  std::vector<std::string> platformExterns, objs;
  bool quiet = false, haveTriple = false;
  for (int i = 2; i < argc; ++i) {
    StringRef arg = argv[i];
    auto take = [&](std::string &dst) {
      if (i + 1 >= argc) return false;
      dst = argv[++i];
      return true;
    };
    if (arg == "--profile") {
      if (!take(profilePath)) return usage(argv[0]);
    } else if (arg == "--libc") {
      if (!take(libc)) return usage(argv[0]);
      if (libc != "none" && libc != "zephyr-minimal" && libc != "picolibc")
        return usage(argv[0]);
    } else if (arg == "--libm") {
      if (!take(libm)) return usage(argv[0]);
      if (libm != "none" && libm != "picolibc") return usage(argv[0]);
    } else if (arg == "--compiler-rt") {
      if (!take(compilerRt)) return usage(argv[0]);
      if (compilerRt != "allow" && compilerRt != "deny") return usage(argv[0]);
    } else if (arg == "--triple") {
      if (!take(triple)) return usage(argv[0]);
      haveTriple = true;
    } else if (arg == "--platform-extern") {
      std::string sym;
      if (!take(sym)) return usage(argv[0]);
      platformExterns.push_back(sym);
    } else if (arg == "--quiet") {
      quiet = true;
    } else if (arg.starts_with("-")) {
      return usage(argv[0]);
    } else {
      objs.push_back(arg.str());
    }
  }
  if (objs.empty())
    return usage(argv[0]);

  // Without profile, use frozen defaults: libc/libm none, compiler_rt allow, empty triple and no
  // platform externs.
  freestanding::UndefPolicy policy;
  if (!profilePath.empty()) {
    auto yamlBuf = MemoryBuffer::getFile(profilePath);
    if (!yamlBuf) {
      fail("profile-unreadable",
           profilePath + ": " + yamlBuf.getError().message());
      return 2;
    }
    bool bad = false;
    // Use the shared single-line formatRejection spelling.
    auto diag = [&](const freestanding::Rejection &r) {
      if (!bad) { bad = true; errs() << freestanding::formatRejection(r) << "\n"; }
    };
    // Use the same ledger-aware resolver as other paths, including platform-first.
    std::string ledgerInfra;
    const std::string menus = freestanding::locateDefaultLedger(argv[0]);
    auto profile = freestanding::resolveFreestandingProfile(
        profilePath, (*yamlBuf)->getBuffer(), menus, diag, &ledgerInfra);
    if (!ledgerInfra.empty()) {
      fail("ledger", ledgerInfra);
      return 2;
    }
    if (!profile) return 2;
    policy = freestanding::undefPolicyOf(*profile);
  }
  // Flags override profile values, enabling doctored-profile controls that change one object
  // verdict under another profile.
  if (!libc.empty()) policy.libc = libc;
  if (!libm.empty()) policy.libm = libm;
  if (!compilerRt.empty()) policy.compilerRt = compilerRt;
  // Empty --triple retains the profile triple, matching a.triple or prof[...].
  if (haveTriple && !triple.empty()) policy.triple = triple;
  for (const std::string &sym : platformExterns)
    if (!llvm::is_contained(policy.allowed, sym)) policy.allowed.push_back(sym);

  std::vector<freestanding::UndefRow> rows;
  for (const std::string &obj : objs) {
    std::string infra;
    std::vector<freestanding::UndefRow> got;
    if (!freestanding::runUndefGate(obj, policy, got, &infra) && !infra.empty()) {
      fail("object-unreadable", infra);
      return 2;
    }
    rows.insert(rows.end(), got.begin(), got.end());
  }
  unsigned bad = 0;
  for (const freestanding::UndefRow &r : rows)
    if (r.verdict == "DENY") ++bad;
  std::vector<freestanding::UndefRow> shown;
  for (const freestanding::UndefRow &r : rows)
    if (!quiet || r.verdict == "DENY") shown.push_back(r);
  outs() << freestanding::formatUndefTsv(shown);
  if (bad)
    errs() << "undef-check: " << bad << " of " << rows.size()
           << " undefined symbol(s) are not allowed by this profile\n";
  return bad ? 1 : 0;
}

} // namespace

// AbiCli.cpp declarations must be outside the anonymous namespace to link to another translation
// unit; the earlier placement caused undefined references.
int runAbiCli(int argc, char **argv);
int runExternCli(int argc, char **argv);   // ExternCli.cpp

int main(int argc, char **argv) {
  // --undef selects a mode only as the first argument, avoiding other argv forms.
  if (argc > 1 && StringRef(argv[1]) == "--undef")
    return runUndefCli(argc, argv);
  // --abi likewise must be the first argument; preserve frozen abi-check CLI/output/status.
  if (argc > 1 && StringRef(argv[1]) == "--abi")
    return runAbiCli(argc, argv);
  if (argc > 1 && StringRef(argv[1]) == "--extern")
    return runExternCli(argc, argv);
  std::string profilePath, sourcePath, typedumpPath, menusPath;
  for (int i = 1; i < argc; ++i) {
    StringRef arg = argv[i];
    auto take = [&](std::string &dst) {
      if (i + 1 >= argc || !dst.empty())
        return false;
      dst = argv[++i];
      return true;
    };
    if (arg == "--profile") {
      if (!take(profilePath)) return usage(argv[0]);
    } else if (arg == "--source") {
      if (!take(sourcePath)) return usage(argv[0]);
    } else if (arg == "--typedump") {
      if (!take(typedumpPath)) return usage(argv[0]);
    } else if (arg == "--menus") {
      if (!take(menusPath)) return usage(argv[0]);
    } else {
      return usage(argv[0]);
    }
  }
  if (profilePath.empty() || sourcePath.empty())
    return usage(argv[0]);

  // Report only the first refusal as one line for unambiguous attribution.
  bool rejected = false;
  auto diag = [&](const freestanding::Rejection &r) {
    if (rejected)
      return;
    rejected = true;
    errs() << freestanding::formatRejection(r) << "\n";
  };

  // ---- Stages P1 / P2 ----------------------------------------------------------
  auto yamlBuf = MemoryBuffer::getFile(profilePath);
  if (!yamlBuf) {
    fail("profile-unreadable", profilePath + ": " + yamlBuf.getError().message());
    return 1;
  }
  // Resolve platform-first through the ledger and legacy through its unchanged reader. A broken
  // ledger is a repository bug, not Rejection: report spinel-fs-check: ledger: ... rather than a
  // classified input line.
  if (menusPath.empty())
    menusPath = freestanding::locateDefaultLedger(argv[0]);
  std::string ledgerInfra;
  auto profile = freestanding::resolveFreestandingProfile(
      profilePath, (*yamlBuf)->getBuffer(), menusPath, diag, &ledgerInfra);
  if (!ledgerInfra.empty()) {
    fail("ledger", ledgerInfra);
    return 1;
  }
  if (!profile)
    return 1;

  // ---- Four faces ----------------------------------------------------------------
  if (typedumpPath.empty())
    typedumpPath = defaultTypedumpPath(argv[0]);
  if (typedumpPath.empty()) {
    fail("typedump-missing",
         "cannot locate spinel-typedump (pass --typedump <path>)");
    return 1;
  }
  ScopedTempDir tmp;
  if (std::error_code ec = tmp.create()) {
    fail("temp-dir-failed", ec.message());
    return 1;
  }
  static const StringRef kFaces[4] = {"ast", "nodes", "locals", "methods"};
  std::unique_ptr<MemoryBuffer> faces[4];
  for (int f = 0; f < 4; ++f) {
    std::string out = tmp.file((kFaces[f] + ".txt").str());
    std::string err = tmp.file((kFaces[f] + ".err").str());
    if (!runTypedump(typedumpPath, sourcePath, kFaces[f], out, err))
      return 1;
    auto buf = MemoryBuffer::getFile(out);
    if (!buf) {
      fail("typedump-unreadable", out + ": " + buf.getError().message());
      return 1;
    }
    faces[f] = std::move(*buf);
  }
  contract::ContractInputs inputs{faces[0]->getBuffer(), faces[1]->getBuffer(),
                                  faces[2]->getBuffer(), faces[3]->getBuffer()};
  bool contractBad = false;
  auto contractDiag = [&](StringRef line) {
    if (contractBad)
      return;
    contractBad = true;
    fail("contract-rejected", line);
  };
  auto module = contract::readContract(inputs, contractDiag);
  if (!module)
    return 1;

  // ---- Stages D1 / D2 ----------------------------------------------------------
  auto decls =
      freestanding::readFreestandingDeclarations(*module, *profile, diag);
  if (!decls)
    return 1;

  // ---- Stages B / C ------------------------------------------------------------
  if (!freestanding::checkFreestandingBodies(*module, *profile, *decls, diag))
    return 1;

  // Accepted: stdout summarizes boundaries only; no artifacts.
  for (const freestanding::FsDecl &d : *decls)
    outs() << "spinel-fs: accept " << d.exportSymbol << " (" << d.params.size()
           << " param(s)) -> " << d.returns << "\n";
  return 0;
}
