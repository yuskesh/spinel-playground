// Thin freestanding emission CLI: argv/files/subprocesses only; lib/Freestanding/Emit owns
// semantics and pipelines. Direct syntax: --profile P --source K -o O --emit-llvm L --emit-header
// H, optional emit-mlir/typedump/codegen/menus. Product syntax fixes SOURCE then --freestanding,
// accepts profile/output/header/typedump/undef options and repeatable method/-m plus types-from
// contract. Preserve direct acceptance; product LLVM IR uses a temp path. Debug --emit-mlir exposes
// normalized source identity through locations.
#include "spinel-mlir/Freestanding/Emit.h"

#include "llvm/Support/MemoryBuffer.h"
#include "spinel-mlir/Freestanding/PlatformLedger.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

using namespace llvm;
using namespace spinel_mlir;

namespace {

// Mode flag probe/admit must be argv[1]. rc 3 routing is silent, rc 1/2 diagnostic. admit shares
// probe path but continues through acceptance into generation.
enum class Mode { Normal, Probe, Admit };
Mode gMode = Mode::Normal;

// Routing mode means probe/admit.
bool routing() { return gMode != Mode::Normal; }

int usage(const char *argv0) {
  // Mode-flag misuse is rc 2 here; rc 3 admission does not pass through usage.
  errs() << "usage: " << argv0
         << " --profile <profile.yaml> --source <kernel.rb> -o <out.o>"
            " --emit-llvm <out.ll> --emit-header <out.h>"
            " [--emit-mlir <out.mlir>] [--typedump <path>] [--codegen <path>]"
            " [--menus <menus.yaml>] [--int64-allow <table.tsv>]\n"
         << "   or: " << argv0
         << " <kernel.rb> --freestanding --profile <profile.yaml> -o <out.o>"
            " --emit-header <out.h> [--typedump <path>] [--int64-allow <table.tsv>]\n";
  return 2;
}

// Historically rc 3 routing was silent. Keep diagnostic spelling identical across modes:
// suppressing it only under routing made explicit/unset invocation stderr differ. Only true Python
// fallback may be silent, decided before this function by argvReject/InputRejected.
void fsDiag(const llvm::Twine &line) { errs() << line << "\n"; }

// Separate out-of-subset argv from mode misuse. Routing originally used silent rc 3 for
// frozen-Python forms; nonrouting retains direct usage 2. Detect six native-only spellings
// anywhere: source/emit-llvm/emit-mlir/clang/menus/codegen. Frozen argparse rejects all, even as
// abbreviations, so native refusal must also name them with rc 2 rather than fallback. clang is no
// longer accepted because codegen owns objects, but stays here for that refusal. codegen/menus are
// direct-only. Product-only forms such as types-from emit-types, lto and -- remain Python routes
// with silent 3.
static bool gNativeOnlySpelling = false;

int argvReject(const char *argv0) {
  if (routing() && !gNativeOnlySpelling)
    return 3;
  return usage(argv0);
}

// Semantic input refused by frozen Python too: name it and return rc 1 even in routing. Preserve
// diagnostic needles read by gates.
int fsSubsetError(const llvm::Twine &detail) {
  errs() << "spinel-fs-emit: " << detail << "\n";
  return 1;
}

class ScopedTempDir {
public:
  ~ScopedTempDir() {
    if (!path_.empty())
      sys::fs::remove_directories(path_);
  }
  std::error_code create() {
    SmallString<128> model;
    sys::path::system_temp_directory(true, model);
    sys::path::append(model, "spinel-fs-emit");
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

// Search executable ancestors for an existing requested path; empty lets the caller refuse by name.
// Never spawn guessed paths.
std::string ancestorPath(const char *argv0, ArrayRef<StringRef> parts) {
  std::string exe =
      sys::fs::getMainExecutable(argv0, reinterpret_cast<void *>(&usage));
  if (exe.empty())
    return {};
  SmallString<128> dir(sys::path::parent_path(exe));
  while (!dir.empty()) {
    SmallString<128> c(dir);
    for (StringRef p : parts)
      sys::path::append(c, p);
    if (sys::fs::exists(c))
      return std::string(c);
    StringRef parent = sys::path::parent_path(dir);
    if (parent == dir)
      break;
    dir = parent;
  }
  return {};
}

} // namespace

int main(int argc, char **argv) {
  freestanding::EmitRequest req;

  // Strip the argv[1] mode before other syntax checks to preserve product positions. Duplicate,
  // lone or misplaced modes are usage 2.
  std::vector<const char *> args(argv, argv + argc);
  if (args.size() >= 2 && (StringRef(args[1]) == "--probe" ||
                           StringRef(args[1]) == "--admit")) {
    gMode = StringRef(args[1]) == "--probe" ? Mode::Probe : Mode::Admit;
    // Probe returns at admission; admit continues, so only probe sets the Probed-return flag.
    req.probe = gMode == Mode::Probe;
    // admit shares silent InputRejected routing behavior without returning at admission.
    req.admit = gMode == Mode::Admit;
    args.erase(args.begin() + 1);
    if (args.size() < 2)
      return usage(argv[0]); // Mode flag alone.
  }
  for (size_t i = 1; i < args.size(); ++i) {
    StringRef a = args[i];
    // Both modes are invalid outside argv[1], including attempts to combine them.
    if (a == "--probe" || a == "--admit")
      return usage(argv[0]);
    // Combining mode with help/version is mode misuse (rc 2 with diagnostics). Neither syntax
    // existed in ordinary fs-emit, so nonrouting usage remains unchanged.
    if (routing() && (a == "--help" || a == "-h" || a == "--version"))
      return usage(argv[0]);
  }
  argc = static_cast<int>(args.size());
  argv = const_cast<char **>(args.data());

  // Detect native-only tokens in all argv before parsing, not by position: even --source consumed
  // as an -o value means native-only argv.
  for (int i = 1; i < argc; ++i)
    for (const char *only :
         {"--source", "--emit-llvm", "--emit-mlir", "--clang", "--menus",
          "--codegen"})
      if (StringRef(argv[i]) == only)
        gNativeOnlySpelling = true;

  // Product syntax depends only on the first two tokens: nondashed source, then --freestanding.
  // Other direct behavior stays unchanged.
  bool productMode = argc >= 3 && argv[1][0] != '-' &&
                     StringRef(argv[2]) == "--freestanding";
  int first = productMode ? 3 : 1;
  if (productMode)
    req.sourcePath = argv[1];

  for (int i = first; i < argc; ++i) {
    StringRef arg = argv[i];
    auto take = [&](std::string &dst) {
      if (i + 1 >= argc || !dst.empty())
        return false;
      // Own-option tokens cannot be values: prevent -o --emit-header from writing a file literally
      // named --emit-header.
      StringRef v = argv[i + 1];
      if (productMode && (v == "--freestanding" || v == "--profile" ||
                          v == "-o" || v == "--emit-header" ||
                          v == "--typedump" || v == "--int64-allow"))
        return false;
      dst = argv[++i];
      return true;
    };
    if (productMode) {
      // Product syntax admits only the selected native option set. types-from emit-types, lto, --
      // and no-type-check remain Python-only and go to argvReject.
      if (arg == "--profile") { if (!take(req.profilePath)) return argvReject(argv[0]); }
      else if (arg == "-o") { if (!take(req.objPath)) return argvReject(argv[0]); }
      else if (arg == "--emit-header") { if (!take(req.headerPath)) return argvReject(argv[0]); }
      else if (arg == "--typedump") { if (!take(req.typedumpPath)) return argvReject(argv[0]); }
      else if (arg == "--emit-undef-tsv") { if (!take(req.undefTsvPath)) return argvReject(argv[0]); }
      // decision 0019's table (tools/core/int64-allow.tsv by default)
      else if (arg == "--int64-allow") { if (!take(req.int64AllowPath)) return argvReject(argv[0]); }
      else if (arg == "--no-undef-check") {
        if (req.noUndefCheck) return argvReject(argv[0]); // Duplicate is usage.
        req.noUndefCheck = true;
      }
      else if (arg == "--method" || arg == "-m") {
        // Repeatable option; do not use the single-use take helper.
        if (i + 1 >= argc) return argvReject(argv[0]);
        llvm::StringRef v = argv[i + 1];
        if (v.starts_with("-")) return argvReject(argv[0]);
        req.methods.push_back(argv[++i]);
      }
      else if (arg == "--types-from") {
        if (i + 1 >= argc) return argvReject(argv[0]);
        // Only contract is admitted here; emit-types stays Python-only.
        if (llvm::StringRef(argv[i + 1]) != "contract") return argvReject(argv[0]);
        ++i;
      }
      else return argvReject(argv[0]);
      continue;
    }
    if (arg == "--profile") { if (!take(req.profilePath)) return argvReject(argv[0]); }
    else if (arg == "--source") { if (!take(req.sourcePath)) return argvReject(argv[0]); }
    else if (arg == "-o") { if (!take(req.objPath)) return argvReject(argv[0]); }
    else if (arg == "--emit-llvm") { if (!take(req.llPath)) return argvReject(argv[0]); }
    else if (arg == "--emit-header") { if (!take(req.headerPath)) return argvReject(argv[0]); }
    else if (arg == "--emit-mlir") { if (!take(req.mlirPath)) return argvReject(argv[0]); }
    else if (arg == "--typedump") { if (!take(req.typedumpPath)) return argvReject(argv[0]); }
    else if (arg == "--codegen") { if (!take(req.codegenPath)) return argvReject(argv[0]); }
    // menus is direct-only, keeping the canonical wrapper form closed. Product menus follows
    // existing misuse handling (rc 2, historically routing rc 3).
    else if (arg == "--menus") { if (!take(req.menusPath)) return argvReject(argv[0]); }
    else if (arg == "--int64-allow") { if (!take(req.int64AllowPath)) return argvReject(argv[0]); }
    // Direct syntax also admits the three product-era options, but its -o stays object-only;
    // extension-based selection is product-only.
    else if (arg == "--emit-undef-tsv") { if (!take(req.undefTsvPath)) return argvReject(argv[0]); }
    else if (arg == "--no-undef-check") {
      if (req.noUndefCheck) return argvReject(argv[0]);
      req.noUndefCheck = true;
    }
    else if (arg == "--method" || arg == "-m") {
      if (i + 1 >= argc) return argvReject(argv[0]);
      llvm::StringRef v = argv[i + 1];
      if (v.starts_with("-")) return argvReject(argv[0]);
      req.methods.push_back(argv[++i]);
    }
    else return argvReject(argv[0]);
  }
  if (req.profilePath.empty() || req.sourcePath.empty() || req.objPath.empty())
    return argvReject(argv[0]);
  // Product emit-header is optional, as frozen Python writes it only when requested. Requiring it
  // routed otherwise accepted SOURCE --freestanding --profile P -o X.o forms back to Python (seven
  // recorded cases). Direct retains its separate five-required-item contract, including emit-llvm.
  if (!productMode && req.headerPath.empty())
    return argvReject(argv[0]);
  // Direct requires emit-llvm; product uses a temp directory so ordinary callers need not manage
  // .ll.
  if (!productMode && req.llPath.empty())
    return argvReject(argv[0]);
  // Product -o extension selects the same three artifact kinds as frozen code; unknown extensions
  // go to argvReject.
  if (productMode) {
    StringRef o = req.objPath;
    if (o.ends_with(".o"))
      req.emitKind = freestanding::EmitRequest::EmitKind::Obj;
    else if (o.ends_with(".ll"))
      req.emitKind = freestanding::EmitRequest::EmitKind::Ll;
    else if (o.ends_with(".mlir"))
      req.emitKind = freestanding::EmitRequest::EmitKind::Mlir;
    else
      // Unknown extensions are also frozen rc-1 cannot-infer-emit failures. Native reports the same
      // needle rather than delaying it through fallback.
      return fsSubsetError("cannot infer --emit from '" + o +
                           "' (use .mlir/.ll/.o)");
  }

  // Removed obsolete routing-only checks for output extension, product options and core tier:
  // native already admitted them, so fallback only postponed default activation. Routing now
  // depends on acceptance; only argvReject or library InputRejected return 3.

  // Resolve ledger path in CLI, which knows executable location, not library. Do not fail here if
  // absent: only platform-first profiles read it, and legacy profiles need no ledger.
  if (req.menusPath.empty())
    req.menusPath = freestanding::locateDefaultLedger(argv[0]);

  if (req.typedumpPath.empty())
    req.typedumpPath =
        ancestorPath(argv[0], {"tools", "contract", "build", "spinel-typedump"});
  if (req.typedumpPath.empty()) {
    fsDiag("spinel-fs-emit: typedump-missing: cannot locate spinel-typedump "
           "(pass --typedump <path>)");
    return 1;
  }
  // spinel-fs-codegen writes the object. By default it is the one beside this
  // executable, where the build directory places it.
  if (req.codegenPath.empty())
    req.codegenPath = ancestorPath(argv[0], {"spinel-fs-codegen"});
  if (req.codegenPath.empty()) {
    fsDiag("spinel-fs-emit: codegen-missing: cannot locate spinel-fs-codegen "
           "(pass --codegen <path>)");
    return 1;
  }
  ScopedTempDir tmp;
  if (std::error_code ec = tmp.create()) {
    fsDiag("spinel-fs-emit: temp-dir-failed: " + Twine(ec.message()));
    return 1;
  }
  // Product emit-llvm points into the temp directory; probe never opens it.
  if (req.llPath.empty())
    req.llPath = tmp.file("product.ll");

  // Report one first refusal only.
  bool rejected = false;
  auto diag = [&](const freestanding::Rejection &r) {
    if (rejected)
      return;
    rejected = true;
    fsDiag(freestanding::formatRejectionMlirgen(r));
  };
  // CLI owns spawning; the library supplies a closed argv list.
  auto runTool = [](StringRef tool, ArrayRef<StringRef> args, StringRef out,
                    StringRef err) {
    std::optional<StringRef> redirects[] = {StringRef(""), out, err};
    std::string execError;
    int rc = sys::ExecuteAndWait(tool, args, std::nullopt, redirects, 0, 0,
                                 &execError);
    if (!execError.empty()) {
      // Subprocess launch failure is Infrastructure, reported even for probe.
      errs() << "spinel-fs-emit: subprocess-failed: cannot run " << tool << ": "
             << execError << "\n";
      return -1;
    }
    return rc;
  };
  auto tempPath = [&](StringRef name) { return tmp.file(name); };

  switch (freestanding::compileFreestanding(req, runTool, tempPath, diag,
                                            errs())) {
  case freestanding::EmitStatus::Emitted:
    outs() << "spinel-fs-emit: wrote " << req.objPath << "\n";
    return 0;
  case freestanding::EmitStatus::Probed:
    return 0; // Probe accepted without output; admit does not stop here.
  case freestanding::EmitStatus::InputRejected:
    // Freestanding InputRejected now reports rc 1 even when routing. Recorded parity showed native
    // refusals were frozen refusals; the explicitly accepted divergence is duplicate-key profiles
    // (Python last-wins, native refuses). Thus no silent fallback is justified here.
    return 1;
  case freestanding::EmitStatus::Infrastructure:
    return 1; // Report diagnostic and rc 1 in routing too.
  }
  return 1;
}
