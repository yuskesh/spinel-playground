// Thin tensor-import CLI owns argv, typedump subprocesses, temporary/output file lifetimes only;
// lib/Tensor owns semantic decisions. Usage: spinel-tensor-import SOURCE -o OUT.mlir [--typedump
// PATH]. Exit 0 success, 1 input/tool failure, 2 usage. Success stdout is one line; refusal writes
// diagnostics only to stderr with no artifacts.
#include "Extern.h"
#include "Fuse.h"
#include "Body.h"
#include "Declaration.h"
#include "Emit.h"
#include "Generate.h"

#include "spinel-mlir/Contract/Reader.h"

#include "mlir/IR/MLIRContext.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <set>
#include <string>

using namespace llvm;
using namespace spinel_mlir;

namespace {

// --probe at argv[1] follows the same parse/typedump/validation/verification path as emission, returning before opening outputs: 0 generatable, 3 valid but outside subset, 1 infrastructure with diagnostics, 2 misuse. 0/3 write no stdout/stderr. --admit uses the same path and continues through the fuse/extern/tensor_def probe exits; post-admission failure is rc 1, never Python fallback.
enum class Mode { Normal, Probe, Admit };
static Mode gMode = Mode::Normal;

// Routing modes are probe/admit, historically the only modes requiring silent rc 3 to route to
// frozen Python.
static bool routing() { return gMode != Mode::Normal; }

int usage(const char *argv0) {
  // Unrecognized native argv also routes as rc 3; usage 2 on frozen-accepted syntax would break
  // staged cutover.
  if (routing())
    return 3;
  errs() << "usage: " << argv0 << " SOURCE -o OUT.mlir [--typedump PATH]\n"
         << "   or: " << argv0
         << " SOURCE --emit-table OUT.h --emit-ruby OUT.rb"
            " --extern-check NAME=MODULE.mlir"
            " [--extern-repair NAME=REPAIRED.mlir] [--typedump PATH]\n"
         << "   or: " << argv0
         << " PROGRAM.rb --fuse -o OUT.mlir --emit-fused OUT.fused.rb"
            " --emit-table OUT.h --emit-ruby OUT.gen.rb [--typedump PATH]\n"
         << "product spellings (SPINEL_MLIRGEN_IMPL=native):\n"
         << "       " << argv0 << " SOURCE --tensor -o OUT.mlir [--typedump PATH]\n"
         << "       " << argv0
         << " SOURCE --tensor --emit-table OUT.h --emit-ruby OUT.rb"
            " --extern-check NAME=MODULE.mlir"
            " [--extern-repair NAME=REPAIRED.mlir] [--typedump PATH]\n"
         << "       " << argv0
         << " SOURCE --tensor --fuse PROGRAM.rb -o OUT.mlir"
            " --emit-fused OUT.fused.rb --emit-table OUT.h"
            " --emit-ruby OUT.rb [--typedump PATH]\n";
  return 2;
}

// Split NAME=PATH at the first equals sign; empty name/path is usage.
bool splitNamed(StringRef spec, std::string &name, std::string &path) {
  size_t at = spec.find('=');
  if (at == StringRef::npos)
    return false;
  name = spec.take_front(at).str();
  path = spec.drop_front(at + 1).str();
  return !name.empty() && !path.empty();
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
    sys::path::append(model, "spinel-tensor-import");
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

// Search executable ancestors for <ancestor>/<parts...>. Return empty for explicit caller failure;
// never launch a subprocess with a guessed path.
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

namespace {

// Frozen Python options outside the initial native scope must not bypass checking in value
// positions.
bool isUnsupportedTensorToken(StringRef a) {
  return a == "--vmfb" || a == "--device" || a == "--iree-compile";
}

// Own-option spellings must not be swallowed as values: -o --tensor would erase a flag and succeed
// in another mode.
bool isOwnOptionToken(StringRef a) {
  return a == "-o" || a == "--typedump" || a == "--emit-table" ||
         a == "--emit-ruby" || a == "--emit-fused" || a == "--extern-check" ||
         a == "--extern-repair" || a == "--fuse" || a == "--tensor";
}

} // namespace

int main(int argc, char **argv) {
  // Mode flags --probe/--admit must be argv[1]. Strip before canonicalProduct detection so
  // remaining source/tensor positions stay fixed.
  if (argc >= 2 && (StringRef(argv[1]) == "--probe" ||
                    StringRef(argv[1]) == "--admit")) {
    StringRef flag = argv[1];
    gMode = flag == "--probe" ? Mode::Probe : Mode::Admit;
    ++argv;
    --argc;
    if (argc < 2) {
      errs() << "spinel-tensor-import: " << flag << " needs the product argv\n";
      return 2;
    }
    // Modes are mutually exclusive, so both spellings belong in the misuse set.
    for (StringRef bad : {StringRef("--probe"), StringRef("--admit"),
                          StringRef("-h"), StringRef("--help"),
                          StringRef("--version")})
      if (StringRef(argv[1]) == bad) {
        errs() << "spinel-tensor-import: " << flag << " cannot be combined with "
               << argv[1] << "\n";
        return 2;
      }
  }

  // Determine canonical product prefix once: nonoption SOURCE at argv[1], --tensor at argv[2].
  // Apply the next two rules only there; applying globally would break old direct dashed-path
  // values such as -o --vmfb or -o --tensor.
  bool canonicalProduct = argc >= 3 && argv[1][0] != '-' &&
                          StringRef(argv[2]) == "--tensor";

  // Three tokens are semantic refusals in normal or value positions. Prescan product argv, or
  // parsing -o --vmfb as a value bypasses the branch.
  if (canonicalProduct)
    for (int i = 1; i < argc; ++i)
      if (isUnsupportedTensorToken(argv[i])) {
        if (routing())
          return 3; // Valid input outside the native subset.
        errs() << "spinel-tensor-import: unsupported-tensor-option: " << argv[i]
               << " is not owned by the CP4 tensor PoC\n";
        return 1;
      }
  std::string sourcePath, outputPath, typedumpPath;
  std::string tablePath, rubyPath;
  // --extern-check/--extern-repair are repeatable, matching append behavior; mnist reads two real modules.
  std::vector<std::pair<std::string, std::string>> checks, repairs;
  std::string checkName, checkPath, repairName, repairPath;
  std::string fusedPath, fuseProgramPath;
  // --emit-kernel-mlir DIR is meaningful only for tensor_def mode.
  std::string kernelDir;
  bool fuseMode = false;
  bool tensorProductMode = false;
  int tensorArgIndex = -1;
  for (int i = 1; i < argc; ++i) {
    StringRef arg = argv[i];
    auto take = [&](std::string &dst) {
      // Never swallow our own options as values, which can erase flags and change mode. Other
      // dash-leading paths remain valid values.
      if (i + 1 >= argc || !dst.empty() ||
          (canonicalProduct && isOwnOptionToken(argv[i + 1])))
        return false;
      dst = argv[++i];
      return true;
    };
    // Repeatable --extern-check/--extern-repair have no second-use usage guard; callers process
    // checks/repairs collections.
    auto takeNamed = [&](std::string &n, std::string &p) {
      if (i + 1 >= argc)
        return false;
      n.clear();
      p.clear();
      return splitNamed(argv[++i], n, p);
    };
    if (arg == "-o") {
      if (!take(outputPath))
        return usage(argv[0]);
    } else if (arg == "--typedump") {
      if (!take(typedumpPath))
        return usage(argv[0]);
    } else if (arg == "--emit-table") {
      if (!take(tablePath))
        return usage(argv[0]);
    } else if (arg == "--emit-ruby") {
      if (!take(rubyPath))
        return usage(argv[0]);
    } else if (arg == "--extern-check") {
      if (!takeNamed(checkName, checkPath))
        return usage(argv[0]);
      checks.emplace_back(checkName, checkPath);
    } else if (arg == "--tensor") {
      // Product mode selector, not an artifact argument.
      if (tensorProductMode)
        return usage(argv[0]);
      tensorProductMode = true;
      tensorArgIndex = i;
    } else if (arg == "--fuse") {
      if (fuseMode)
        return usage(argv[0]);
      fuseMode = true;
      // Product --fuse takes a value, as frozen Python does; direct --fuse keeps its valueless
      // form.
      if (tensorProductMode && !take(fuseProgramPath))
        return usage(argv[0]);
    } else if (arg == "--emit-fused") {
      if (!take(fusedPath))
        return usage(argv[0]);
    } else if (arg == "--extern-repair") {
      if (!takeNamed(repairName, repairPath))
        return usage(argv[0]);
      repairs.emplace_back(repairName, repairPath);
    } else if (arg == "--emit-kernel-mlir") {
      // Write standalone declaration modules to DIR/name.mlir, matching gen.single. The initial
      // one-declaration subset wrote exactly one file.
      if (!take(kernelDir))
        return usage(argv[0]);
    } else if (arg.starts_with("-")) {
      return usage(argv[0]);
    } else if (sourcePath.empty()) {
      sourcePath = std::string(arg);
    } else {
      return usage(argv[0]);
    }
  }
  if (sourcePath.empty())
    return usage(argv[0]);

  // Canonical product syntax is SOURCE --tensor ... . Require --tensor at argument two, as the
  // wrapper does, avoiding native acceptance of spellings the wrapper routes to Python.
  if (tensorProductMode && tensorArgIndex != 2)
    return usage(argv[0]);

  // Product boundary before semantics or output creation.
  auto rejectTensorOption = [&](StringRef detail) {
    if (routing())
      return 3; // Outside subset, not infrastructure failure.
    errs() << "spinel-tensor-import: unsupported-tensor-option: " << detail
           << "\n";
    return 1;
  };
  if (tensorProductMode && fuseMode) {
    // SOURCE and PROGRAM may differ. Check readability before opening outputs.
    SmallString<128> sourceReal, programReal;
    if (sys::fs::real_path(sourcePath, sourceReal) ||
        sys::fs::real_path(fuseProgramPath, programReal))
      return rejectTensorOption("SOURCE and --fuse PROGRAM must be readable");
  }

  // Mode exclusivity was relaxed: initial output-table/Ruby flags implied extern mode and
  // conflicted with -o, but frozen callers generate module/table/dispatch/standalone kernels
  // together. Only extern-check/repair selects extern mode.
  bool externMode = !checkName.empty() || !repairName.empty();
  if (fuseMode) {
    // Historical fuse required all four outputs and forbade extern/kernel options. Later behavior
    // permits emit-kernel-mlir when SOURCE supplies declarations, since frozen gen.funcs is
    // independent of fusion. emit-fused/table/Ruby are all optional, written only when requested.
    if (!checkName.empty() || !repairName.empty() || outputPath.empty())
      return usage(argv[0]);
  } else if (!fusedPath.empty()) {
    return usage(argv[0]); // emit-fused requires fuse.
  } else if (externMode) {
    if (!outputPath.empty())
      return usage(argv[0]); // -o is tensor_def-only.
    if (!kernelDir.empty())
      // Refuse emit-kernel-mlir in extern mode: the foreign .vmfb has no owned module to split.
      // Never silently ignore it.
      return usage(argv[0]);
    if (tablePath.empty() || rubyPath.empty() || checkName.empty())
      return usage(argv[0]); // Extern mode requires all three items.
    // Each extern-repair needs a same-name extern-check; compare sets because both flags repeat.
    for (const auto &r : repairs) {
      bool paired = false;
      for (const auto &c : checks)
        if (c.first == r.first) { paired = true; break; }
      if (!paired)
        return usage(argv[0]);
    }
  } else if (outputPath.empty()) {
    // -o is optional, default tensors.mlir. With no tensor_def, no MLIR is written at all, as for extern-only input.
    outputPath = "tensors.mlir";
  }

  // Resolve typedump from explicit option then executable ancestors, never guessed paths.
  if (typedumpPath.empty())
    typedumpPath = ancestorPath(
        argv[0], {"tools", "contract", "build", "spinel-typedump"});
  if (typedumpPath.empty() || !sys::fs::can_execute(typedumpPath)) {
    errs() << "spinel-tensor-import: typedump-failed: no usable spinel-typedump"
              " (pass --typedump PATH)\n";
    return 1;
  }

  // Create absent emit-ruby output empty before reading inputs: fused programs require their
  // generated dispatch during frontend parsing, so clean trees otherwise fail. This is the sole
  // exception to no-output-before-semantic-validation, because parsing itself needs the file;
  // frozen tensor_main does the same.
  if (!rubyPath.empty() && !sys::fs::exists(rubyPath)) {
    std::error_code rec;
    raw_fd_ostream touch(rubyPath, rec);
    if (rec) {
      errs() << "spinel-tensor-import: output-unreadable: " << rubyPath << ": "
             << rec.message() << "\n";
      return 1;
    }
    touch.close();
  }

  ScopedTempDir tmp;
  if (std::error_code ec = tmp.create()) {
    errs() << "spinel-tensor-import: typedump-failed: mktemp: " << ec.message()
           << "\n";
    return 1;
  }

  static const StringRef kFaces[4] = {"ast", "nodes", "locals", "methods"};
  std::unique_ptr<MemoryBuffer> faces[4];
  // Collect four faces per file. When fuse PROGRAM differs from SOURCE, its statements live in
  // PROGRAM AST, matching ContractTypes(...,context="fuse").
  std::string facePrefix;
  std::string facePath = sourcePath;
  auto runTypedump = [&]() -> bool {
  for (int f = 0; f < 4; ++f) {
    std::string out = tmp.file((facePrefix + kFaces[f] + ".txt").str());
    std::string err = tmp.file((facePrefix + kFaces[f] + ".err").str());
    StringRef args[] = {typedumpPath, facePath, kFaces[f]};
    std::optional<StringRef> redirects[] = {std::nullopt, StringRef(out),
                                            StringRef(err)};
    std::string msg;
    int rc = sys::ExecuteAndWait(typedumpPath, args, std::nullopt, redirects,
                                 0, 0, &msg);
    if (rc != 0) {
      errs() << "spinel-tensor-import: typedump-failed: " << kFaces[f] << ": "
             << (msg.empty() ? "non-zero exit" : msg) << "\n";
      if (auto eb = MemoryBuffer::getFile(err))
        errs() << (*eb)->getBuffer();
      return false;
    }
    auto buf = MemoryBuffer::getFile(out);
    if (!buf) {
      errs() << "spinel-tensor-import: typedump-failed: unreadable " << out
             << ": " << buf.getError().message() << "\n";
      return false;
    }
    faces[f] = std::move(*buf);
  }
  return true;
  };
  if (!runTypedump())
    return 1;

  bool sealFailed = false;
  auto contractDiag = [&](StringRef line) {
    if (sealFailed)
      return;
    sealFailed = true;
    errs() << "spinel-tensor-import: typedump-failed: " << line << "\n";
  };
  contract::ContractInputs inputs{faces[0]->getBuffer(), faces[1]->getBuffer(),
                                  faces[2]->getBuffer(), faces[3]->getBuffer()};
  auto sealed = contract::readContract(inputs, contractDiag);
  if (!sealed)
    return 1;
  sealed->setSourceFile(sourcePath);

  // Collect a separate contract for distinct --fuse PROGRAM. Frozen tensor_def comes from SOURCE
  // and sites from PROGRAM; the initial one-contract prototype unnecessarily required equal files.
  std::optional<contract::ContractModule> fuseSealed;
  const bool twoFile = fuseMode && !fuseProgramPath.empty() &&
                       fuseProgramPath != sourcePath;
  if (twoFile) {
    facePrefix = "fuse-";
    facePath = fuseProgramPath;
    if (!runTypedump())
      return 1;
    contract::ContractInputs fin{faces[0]->getBuffer(), faces[1]->getBuffer(),
                                 faces[2]->getBuffer(), faces[3]->getBuffer()};
    auto fs = contract::readContract(fin, contractDiag);
    if (!fs)
      return 1;
    fs->setSourceFile(fuseProgramPath);
    fuseSealed = std::move(*fs);
  }

  // Read declarations/bodies once for Emit.
  std::vector<tensor::TensorExtern> gExterns;
  std::vector<tensor::TensorDecl> gDecls;
  std::vector<tensor::TensorBody> gBodies;

  // Read declarations first under frozen collect_tensor_decls rules/order. Refuse with its verbatim
  // unsupported diagnostic, naming the product wrapper spinel-mlirgen rather than this tool; frozen
  // likewise uses fixed PROG, not argv[0].
  {
    bool declFailed = false;
    auto declDiag = [&](llvm::StringRef detail) {
      declFailed = true;
      if (!routing() || true)
        errs() << "spinel-mlirgen: unsupported: " << detail << "\n";
    };
    auto decls = tensor::collectTensorDecls(*sealed, declDiag);
    if (!decls) {
      // Declaration failure is also rejected by frozen Python, so report rc 1 in routing, not
      // silent 3.
      return 1;
    }
    // Read externs after declarations, as TensorGenerator.__init__ does, ensuring bad declarations
    // fail first.
    {
      auto externs = tensor::collectTensorExterns(*sealed, declDiag);
      if (!externs)
        return 1;
      gExterns = std::move(*externs);
    }
    // Match def/body per declaration in frozen order: duplicate declaration, missing def,
    // arguments, body. First cause is the answer.
    {
      auto defs = tensor::topLevelDefs(*sealed);
      std::set<std::string> seen;
      for (const tensor::TensorDecl &d : *decls) {
        if (!seen.insert(d.name).second) {
          declDiag(d.where() + ": declared twice");
          return 1;
        }
        auto it = defs.find(d.name);
        if (it == defs.end()) {
          declDiag(d.where() + ": no top-level `def " + d.name +
                   "` to go with the declaration");
          return 1;
        }
        auto b = tensor::readTensorBody(*sealed, d, it->second, declDiag);
        if (!b)
          return 1;
        gDecls.push_back(d);
        gBodies.push_back(*b);
      }
    }
    (void)declFailed;
  }

  // Share validators rather than creating routing predicates. Buffer diagnostics and decide whether
  // frozen Python would accept before returning the routing verdict.
  std::string captured;
  auto tensorDiag = [&](StringRef category, StringRef detail) {
    if (!routing()) {
      errs() << "spinel-tensor-import: " << category << ": " << detail << "\n";
      return;
    }
    if (!captured.empty())
      captured += "; ";
    captured += (category + ": " + detail).str();
  };

  // Refusal rule: when both implementations refuse, report diagnostic/rc 1; if only Python supports
  // the case, silent rc 3. Native generation gaps, not common validator failures, use fallback.
  // Routing prints the same line as explicit native, preserving wrapper/explicit stderr
  // comparisons.
  std::string capturedLine;
  auto rejected = [&]() {
    if (!routing())
      return 1;
    if (!capturedLine.empty()) {
      errs() << capturedLine << "\n";
      return 1;
    }
    errs() << "spinel-tensor-import: "
           << (captured.empty() ? "outside the tensor subset" : captured)
           << "\n";
    return 1;
  };

  // Standalone kernels: rebuild one-declaration modules like gen.single. Use a lambda shared by
  // fuse mode; select the first device profile, or none when auto is absent.
  auto writeKernelDir = [&]() -> bool {
    if (std::error_code dec = sys::fs::create_directories(kernelDir)) {
      errs() << "spinel-tensor-import: output-unreadable: " << kernelDir << ": "
             << dec.message() << "\n";
      return false;
    }
    for (size_t ki = 0; ki < gDecls.size(); ++ki) {
      const std::string &name = gDecls[ki].name;
      SmallString<128> path(kernelDir);
      sys::path::append(path, name + ".mlir");
      // Rebuild a module containing only this declaration.
      mlir::MLIRContext one;
      std::string oneWhy;
      std::vector<tensor::PadChoice> onePad;
      auto single = tensor::generateTensorModule(
          *sealed, {gDecls[ki]}, {gBodies[ki]}, one, tensor::tensorHasAutoPadVia(gDecls) ? llvm::StringRef("cpu")
                                             : llvm::StringRef(""), onePad,
          [&](llvm::StringRef w) { oneWhy = w.str(); });
      if (!single) {
        errs() << "spinel-tensor-import: not-yet-generated: " << oneWhy << "\n";
        return false;
      }
      std::error_code kec;
      raw_fd_ostream kos(path, kec);
      if (kec) {
        errs() << "spinel-tensor-import: output-unreadable: " << path << ": "
               << kec.message() << "\n";
        return false;
      }
      single->print(kos);
      kos << "\n";
      kos.close();
      if (kos.has_error()) {
        std::error_code wec = kos.error();
        kos.clear_error();
        errs() << "spinel-tensor-import: output-failure: " << path << ": "
               << wec.message() << "\n";
        return false;
      }
      // Frozen generation says nothing about standalone kernel outputs. Remove the earlier extra
      // stdout line; requesting emit-kernel-mlir already tells the caller what was asked.
    }
    return true;
  };

  if (fuseMode) {
    // Rewrite PROGRAM text, which contains the fused sites.
    const std::string fuseSrcPath =
        fuseProgramPath.empty() ? sourcePath : fuseProgramPath;
    auto fuseSrcBuf = MemoryBuffer::getFile(fuseSrcPath);
    if (!fuseSrcBuf) {
      errs() << "spinel-tensor-import: malformed-fuse-site: unreadable "
             << fuseSrcPath << ": " << fuseSrcBuf.getError().message() << "\n";
      return 1;
    }
    mlir::MLIRContext fuseContext;
    // Use PROGRAM AST for fusion, sharing SOURCE only in the one-file form.
    const contract::ContractModule &fuseModule =
        fuseSealed ? *fuseSealed : *sealed;
    const std::string fuseName = std::string(sys::path::filename(
        fuseProgramPath.empty() ? sourcePath : fuseProgramPath));
    // Open outputs only after all semantic validation. Fuse refusals use frozen spinel-mlirgen:
    // unsupported: fused statement at line N: detail. Keep the three native categories internally,
    // not on stderr (2026-09-07 decision).
    auto fuseDiag = [&](StringRef category, StringRef detail) {
      (void)category;
      if (!routing()) {
        errs() << "spinel-mlirgen: unsupported: " << detail << "\n";
        return;
      }
      if (capturedLine.empty())
        capturedLine = ("spinel-mlirgen: unsupported: " + detail).str();
    };
    auto art = tensor::compileFuse(fuseModule, fuseName,
                                      (*fuseSrcBuf)->getBuffer(), fuseContext,
                                      fuseDiag);
    if (!art)
      return rejected();
    // Combine declared and fused kernels into one module/table/dispatch, as gen.entries does. With
    // declarations in SOURCE this is the two-file path. With no declarations, keep Fuse.cpp exact
    // text because FNV identity cannot depend on printer spelling.
    mlir::OwningOpRef<mlir::ModuleOp> merged;
    std::vector<std::vector<tensor::Entry>> fusePerDecl;
    if (!gDecls.empty()) {
      std::string mWhy;
      std::vector<tensor::PadChoice> mPad;
      merged = tensor::generateTensorModule(*sealed, gDecls, gBodies, fuseContext,
                                            "", mPad,
                                            [&](StringRef w) { mWhy = w.str(); });
      if (!merged) {
        errs() << "spinel-tensor-import: not-yet-generated: " << mWhy << "\n";
        return 1;
      }
      // Declared entries first, fused entries afterward.
      for (mlir::Operation &op :
           llvm::make_early_inc_range(art->module->getBody()->getOperations()))
        op.moveBefore(merged->getBody(), merged->getBody()->end());
      for (size_t i = 0; i < gDecls.size(); ++i)
        fusePerDecl.push_back(tensor::buildEntries(gDecls[i], gBodies[i]));
    }
    // Probe exits after validation/verification and before output creation; admit continues into
    // generation.
    if (gMode == Mode::Probe)
      return 0;
    auto write = [&](StringRef path, StringRef text) {
      std::error_code ec;
      raw_fd_ostream os(path, ec);
      if (ec) {
        errs() << "spinel-tensor-import: output-unreadable: " << path << ": "
               << ec.message() << "\n";
        return false;
      }
      os << text;
      os.close();
      // Check deferred raw_fd_ostream errors after close, before claiming output. Otherwise writes
      // could fail yet say wrote, then emit a generic fatal destructor error. clear_error prevents
      // report_fatal_error on destruction.
      if (os.has_error()) {
        std::error_code wec = os.error();
        os.clear_error();
        errs() << "spinel-tensor-import: output-failure: " << path << ": "
               << wec.message() << "\n";
        return false;
      }
      return true;
    };
    // Emit owns the frozen twelve-line Ruby header and complete table header; Fuse.cpp supplies
    // body/entry values. Do not reconstruct fused identity from declarations: it hashes exact MLIR
    // text.
    std::vector<tensor::Entry> fuseEntryRows;
    for (const auto &fe : art->tableRows) {
      tensor::Entry e;
      e.name = fe.name;
      e.fq = "module." + fe.name;
      for (unsigned i = 0; i < fe.nscalar; ++i) e.params.push_back("scalar");
      for (char c : fe.ranks)
        e.params.push_back(c == '1'   ? "vec"
                           : c == '2' ? "mat"
                           : c == '3' ? "ten3"
                                      : "ten4");
      e.dest = static_cast<int64_t>(e.params.size()) - 1;
      e.retScalar = 0;
      e.constraints = fe.shape;
      e.explicitSig = fe.sig;
      fuseEntryRows.push_back(std::move(e));
    }
    // Table order: declarations then fusion.
    {
      std::vector<tensor::Entry> declRows;
      for (const auto &v : fusePerDecl)
        for (const tensor::Entry &e : v) declRows.push_back(e);
      // Refuse fused kernel names colliding with declarations, using frozen duplicate-entry
      // wording.
      std::set<std::string> names;
      for (const tensor::Entry &e : declRows) names.insert(e.name);
      for (const tensor::Entry &e : fuseEntryRows)
        if (!names.insert(e.name).second) {
          errs() << "spinel-mlirgen: duplicate entry name between the fused "
                    "kernels and the declared ones\n";
          return 1;
        }
      fuseEntryRows.insert(fuseEntryRows.begin(), declRows.begin(),
                           declRows.end());
    }
    const std::string fuseTable = tensor::tableHeader(
        std::string(sys::path::filename(sourcePath)), fuseEntryRows);
    const std::string fuseRuby = tensor::generatedRuby(
        std::string(sys::path::filename(sourcePath)), gDecls, gBodies,
        fusePerDecl,
        // Direct --fuse has no PROGRAM value, so use SOURCE when empty. Notes identify the
        // fuse-program basename, matching frozen output.
        std::string(sys::path::filename(
            fuseProgramPath.empty() ? sourcePath : fuseProgramPath)),
        art->rubyDispatch);
    // With declarations print the merged module (comparisons normalize roundtrip); without them
    // retain exact Fuse.cpp text.
    std::string moduleText = art->mlirText;
    if (merged) {
      moduleText.clear();
      llvm::raw_string_ostream ms(moduleText);
      merged->print(ms);
      ms << "\n";
    }
    if (!write(outputPath, moduleText) ||
        !write(fusedPath, art->rewrittenSource))
      return 1;
    if (!tablePath.empty() && !write(tablePath, fuseTable))
      return 1;
    if (!rubyPath.empty() && !write(rubyPath, fuseRuby))
      return 1;
    // Align reports to frozen output: two stderr lines plus stdout declaration-name list (empty for
    // fuse-only), not the prototype single stdout wrote line. Both output streams participate in
    // golden comparison.
    std::string fuseEntries;
    for (const std::string &n : art->entryNames) {
      if (!fuseEntries.empty()) fuseEntries += ", ";
      fuseEntries += n;
    }
    errs() << "spinel-mlirgen: wrote " << fusedPath << " (" << art->sites
           << " fused statement(s) -> " << art->kernels << " kernel(s))\n";
    {
      // Reported entries are declarations plus fusion.
      std::string all;
      for (const auto &v : fusePerDecl)
        for (const tensor::Entry &e : v) {
          if (!all.empty()) all += ", ";
          all += e.name;
        }
      if (!all.empty() && !fuseEntries.empty()) all += ", ";
      fuseEntries = all + fuseEntries;
    }
    size_t nEntries = fuseEntryRows.size();
    errs() << "spinel-mlirgen: wrote " << outputPath
           << " (" << gDecls.size() << " tensor_def + 0 tensor_extern + "
           << art->sites
           << " fused statement(s) -> " << nEntries
           << " entries: " << fuseEntries << ")\n";
    // Stdout lists declaration names; fuse-only sources produce an empty line.
    {
      std::string names;
      for (const tensor::TensorDecl &d : gDecls) {
        if (!names.empty()) names += ",";
        names += d.name;
      }
      outs() << names << "\n";
    }
    // emit-kernel-mlir applies only to declarations, not fused kernels without declarations.
    if (!kernelDir.empty() && !writeKernelDir())
      return 1;
    return 0;
  }

  if (externMode) {
    // Match every named extern separately, like append-style extern-check. Emit writes all extern
    // table/dispatch entries together. Refusal uses spinel-mlirgen: extern check failed: detail;
    // keep the three categories internal.
    auto externDiag = [&](StringRef category, StringRef detail) {
      const bool repair = category == "extern-repair-failed";
      if (!routing()) {
        errs() << "spinel-mlirgen: extern "
               << (repair ? "repair" : "check") << " failed: " << detail << "\n";
        return;
      }
      if (capturedLine.empty())
        capturedLine = ("spinel-mlirgen: extern " +
                        llvm::Twine(repair ? "repair" : "check") +
                        " failed: " + detail).str();
    };
    std::map<std::string, std::string> repairOf;
    for (const auto &r : repairs) repairOf[r.first] = r.second;
    std::vector<std::pair<std::string, tensor::ExternArtifacts>> results;
    std::map<std::string, tensor::ExternArtifacts> repaired;
    for (const auto &c : checks) {
      const tensor::TensorExtern *x = nullptr;
      for (const tensor::TensorExtern &e : gExterns)
        if (e.name == c.first) { x = &e; break; }
      if (!x) {
        errs() << "spinel-tensor-import: extern-check-failed: --extern-check "
               << c.first << " names no tensor_extern in "
               << sys::path::filename(sourcePath) << "\n";
        return 1;
      }
      auto foreign = MemoryBuffer::getFile(c.second);
      if (!foreign) {
        errs() << "spinel-tensor-import: extern-check-failed: unreadable "
               << c.second << ": " << foreign.getError().message() << "\n";
        return 1;
      }
      // Repair before matching, giving checks and downstream consumers identical repaired text.
      // With no changes, pass text through byte-identically.
      std::string text = (*foreign)->getBuffer().str();
      std::string checkedPath = c.second;
      auto it = repairOf.find(c.first);
      if (it != repairOf.end()) {
        auto rep = tensor::repairExternModule(text, x->where() + ": ", externDiag);
        if (!rep)
          return rejected();
        text = rep->repairedModule;
        checkedPath = it->second;
        repaired[c.first] = *rep;
      }
      auto art = tensor::checkExtern(*x, text, checkedPath, externDiag);
      if (!art)
        return rejected();
      results.emplace_back(c.first, std::move(*art));
    }
    // Extern probe exits after all matches before opening outputs.
    if (gMode == Mode::Probe)
      return 0;
    auto write = [&](StringRef path, StringRef text) {
      std::error_code ec;
      raw_fd_ostream os(path, ec);
      if (ec) {
        errs() << "spinel-tensor-import: output-unreadable: " << path << ": "
               << ec.message() << "\n";
        return false;
      }
      os << text;
      os.close();
      if (os.has_error()) {
        std::error_code wec = os.error();
        os.clear_error();
        errs() << "spinel-tensor-import: output-failure: " << path << ": "
               << wec.message() << "\n";
        return false;
      }
      return true;
    };
    // Table/dispatch contains declarations plus externs, matching entries().
    std::vector<tensor::Entry> rows;
    std::vector<std::vector<tensor::Entry>> perDecl;
    for (size_t i = 0; i < gDecls.size(); ++i) {
      perDecl.push_back(tensor::buildEntries(gDecls[i], gBodies[i]));
      for (const tensor::Entry &e : perDecl.back()) rows.push_back(e);
    }
    for (const tensor::TensorExtern &x : gExterns)
      rows.push_back(tensor::buildExternEntry(x));
    const std::string srcName = std::string(sys::path::filename(sourcePath));
    if (!tablePath.empty() &&
        !write(tablePath, tensor::tableHeader(srcName, rows)))
      return 1;
    if (!rubyPath.empty() &&
        !write(rubyPath, tensor::generatedRuby(srcName, gDecls, gBodies, perDecl,
                                               {}, {}) +
                             tensor::externDispatch(gExterns)))
      return 1;
    for (const auto &kv : repaired)
      if (!write(repairOf[kv.first], kv.second.repairedModule))
        return 1;
    // Report one extern-check matches line per comparison.
    for (const auto &r : results) {
      auto rp = repaired.find(r.first);
      if (rp != repaired.end()) {
        const unsigned cw = rp->second.convWindowRepairs;
        const unsigned dr = rp->second.dynamicReshapeRepairs;
        errs() << "spinel-mlirgen: extern-repair " << r.first << ": wrote "
               << repairOf[r.first] << " (";
        if (cw || dr) {
          std::string counts;
          if (cw) counts += "conv-window x" + std::to_string(cw);
          if (dr) {
            if (!counts.empty()) counts += "; ";
            counts += "dynamic-reshape x" + std::to_string(dr);
          }
          errs() << counts;
        } else {
          errs() << "nothing to repair -- the module already spells out "
                    "everything E060 knows how to write back";
        }
        errs() << ")\n";
      }
      errs() << "spinel-mlirgen: extern-check " << r.second.summary << "\n";
    }
    errs() << "spinel-mlirgen: no tensor_def in " << sourcePath
           << " -- extern-only, so no .mlir is written (the .vmfb comes from "
              "elsewhere)\n";
    {
      std::string names, entryNames;
      for (const tensor::Entry &e : rows) {
        if (!entryNames.empty()) entryNames += ", ";
        entryNames += e.name;
      }
      for (const tensor::TensorDecl &d : gDecls) {
        if (!names.empty()) names += ",";
        names += d.name;
      }
      for (const tensor::TensorExtern &x : gExterns) {
        if (!names.empty()) names += ",";
        names += x.name;
      }
      errs() << "spinel-mlirgen: no .mlir (" << gDecls.size()
             << " tensor_def + " << gExterns.size()
             << " tensor_extern + 0 fused statement(s) -> " << rows.size()
             << " entries: " << entryNames << ")\n";
      outs() << names << "\n";
    }
    return 0;
  }

  // profContexts owns each module MLIRContext.
  std::vector<std::string> kernelNames;
  // Try general generation first; refuse unimplemented forms without constructing invalid modules,
  // recording pending cases. The initial prototype covered SAXPY only. Also refuse sources with no
  // tensor_def, extern or fusion: extern-only/fuse-only have no owned module but are valid, while
  // no declarations/sites means not input for this tool.
  if (gDecls.empty() && gExterns.empty()) {
    errs() << "spinel-mlirgen: unsupported: no tensor_def or tensor_extern "
              "declaration in "
           << sys::path::filename(sourcePath) << "\n";
    return 1;
  }

  std::string genWhy;
  // auto+zero padding produces one module per device profile, matching the preexisting vmfb device
  // axis rather than inventing one. Native admits no --device, so this is always the
  // unspecified-device branch.
  llvm::SmallVector<llvm::StringRef, 2> profiles;
  if (tensor::tensorHasAutoPadVia(gDecls))
    for (llvm::StringRef p : tensor::tensorPadDeviceProfiles()) profiles.push_back(p);
  else
    profiles.push_back("");
  std::vector<std::unique_ptr<mlir::MLIRContext>> profContexts;
  std::vector<mlir::OwningOpRef<mlir::ModuleOp>> profModules;
  std::vector<tensor::PadChoice> padChoice;
  for (llvm::StringRef dev : profiles) {
    profContexts.push_back(std::make_unique<mlir::MLIRContext>());
    padChoice.clear();
    auto m = tensor::generateTensorModule(
        *sealed, gDecls, gBodies, *profContexts.back(), dev, padChoice,
        [&](llvm::StringRef w) { genWhy = w.str(); });
    if (!m) {
      errs() << "spinel-tensor-import: not-yet-generated: " << genWhy << "\n";
      return 1;
    }
    profModules.push_back(std::move(m));
  }
  // Write per-profile modules; Emit sees declarations only, not device, so table/dispatch ABI
  // invariance is structural. Two profiles turn -o X.mlir into X.cpu.mlir/X.metal.mlir.
  auto profPath = [&](llvm::StringRef path, llvm::StringRef dev) -> std::string {
    if (profiles.size() == 1) return path.str();
    llvm::StringRef ext = sys::path::extension(path);
    return (path.drop_back(ext.size()) + "." + dev + ext).str();
  };
  std::string outPaths;
  for (size_t i = 0; i < profiles.size(); ++i) {
    if (!outPaths.empty()) outPaths += ", ";
    outPaths += profPath(outputPath, profiles[i]);
  }
  for (const tensor::TensorDecl &d : gDecls)
    kernelNames.push_back(d.name);
  // tensor_def probe exit; admit continues.
  if (gMode == Mode::Probe)
    return 0;

  // Without tensor_def, write no MLIR: extern-only input points to foreign .vmfb and has no owned
  // module. Frozen reports one line and ignores -o, including default tensors.mlir.
  for (size_t pi = 0; gDecls.empty() ? false : pi < profiles.size(); ++pi) {
    const std::string path = profPath(outputPath, profiles[pi]);
    std::error_code ec;
    raw_fd_ostream os(path, ec);
    if (ec) {
      errs() << "spinel-tensor-import: output-unreadable: " << path << ": "
             << ec.message() << "\n";
      return 1;
    }
    profModules[pi]->print(os);
    os << "\n";
    os.close();
    // Check deferred write errors before reporting wrote.
    if (os.has_error()) {
      std::error_code wec = os.error();
      os.clear_error();
      errs() << "spinel-tensor-import: output-failure: " << path << ": "
             << wec.message() << "\n";
      return 1;
    }
  }
  // Generate module/table/dispatch/standalone kernels together, with byte-exact table/dispatch
  // owned only by lib/Tensor/Emit.cpp.
  if (!tablePath.empty() || !rubyPath.empty()) {
    // Store entry lists per declaration: fixed_tree produces two entries.
    std::vector<std::vector<tensor::Entry>> perDecl;
    std::vector<tensor::Entry> entries;
    for (size_t i = 0; i < gDecls.size(); ++i) {
      perDecl.push_back(tensor::buildEntries(gDecls[i], gBodies[i]));
      for (const tensor::Entry &e : perDecl.back()) entries.push_back(e);
    }
    const std::string srcName = std::string(sys::path::filename(sourcePath));
    auto writeText = [&](const std::string &path, const std::string &text) {
      std::error_code ec;
      raw_fd_ostream os(path, ec);
      if (ec) {
        errs() << "spinel-tensor-import: output-unreadable: " << path << ": "
               << ec.message() << "\n";
        return false;
      }
      os << text;
      os.close();
      if (os.has_error()) {
        std::error_code wec = os.error();
        os.clear_error();
        errs() << "spinel-tensor-import: output-failure: " << path << ": "
               << wec.message() << "\n";
        return false;
      }
      return true;
    };
    if (!tablePath.empty() &&
        !writeText(tablePath, tensor::tableHeader(srcName, entries)))
      return 1;
    if (!rubyPath.empty() &&
        !writeText(rubyPath, tensor::generatedRuby(srcName, gDecls, gBodies, perDecl)))
      return 1;
  }

  // Success output matches frozen: stderr says wrote path (N tensor_def + M tensor_extern + K fused
  // statements -> E entries: comma names), stdout lists declaration names. This closes the
  // prototype stdout-only wrote divergence, since both streams are compared.
  {
    // Stdout names declarations; stderr entries names actual entries, including fixed_tree
    // __ft_pre/__ft_step.
    std::string names, entryNames;
    size_t entryCount = 0;
    for (size_t i = 0; i < gDecls.size(); ++i) {
      if (!names.empty()) names += ",";
      names += gDecls[i].name;
      for (const tensor::Entry &e : tensor::buildEntries(gDecls[i], gBodies[i])) {
        if (!entryNames.empty()) entryNames += ", ";
        entryNames += e.name;
        ++entryCount;
      }
    }
    // entries() order is declarations, externs, fusion. Each extern uses its declaration name for
    // one entry.
    for (const tensor::TensorExtern &x : gExterns) {
      if (!names.empty()) names += ",";
      names += x.name;
      if (!entryNames.empty()) entryNames += ", ";
      entryNames += x.name;
      ++entryCount;
    }
    // Without extern-check, tensor_extern shapes remain unverified claims. Never accept silently.
    if (!gExterns.empty()) {
      std::string unchecked;
      for (const tensor::TensorExtern &x : gExterns) {
        if (!unchecked.empty()) unchecked += ", ";
        unchecked += x.name;
      }
      errs() << "spinel-mlirgen: WARNING: tensor_extern " << unchecked
             << " emitted WITHOUT --extern-check -- its shapes: is an unverified "
                "claim about a foreign module\n";
    }
    // Preserve frozen report order: warning, extern-only note, summary.
    if (gDecls.empty())
      errs() << "spinel-mlirgen: no tensor_def in " << sourcePath
             << " -- extern-only, so no .mlir is written (the .vmfb comes from "
                "elsewhere)\n";
    if (profiles.size() > 1)
      errs() << "spinel-mlirgen: wrote " << profiles.size()
             << " device-profile modules (" << outPaths << ") -- pad_via: :auto\n";
    if (gDecls.empty())
      errs() << "spinel-mlirgen: no .mlir (";
    else
      errs() << "spinel-mlirgen: wrote " << outPaths << " (";
    errs() << gDecls.size() << " tensor_def + " << gExterns.size()
           << " tensor_extern + 0 fused statement(s) -> " << entryCount
           << " entries: " << entryNames << ")\n";
    outs() << names << "\n";
  }
  // Standalone kernels must rebuild a module per declaration, like gen.single. The original
  // one-declaration subset could dump the whole module; after supporting multiple declarations,
  // that would mix other kernels into later files, as observed.
  if (!kernelDir.empty() && !writeKernelDir())
    return 1;
  return 0;
}
