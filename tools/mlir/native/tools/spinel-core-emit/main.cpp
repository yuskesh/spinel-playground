//===- spinel-core-emit - lower a checked core closure to an object -------===//
//
// Decision 0005 task 4.  The CLI half: argument parsing, temporary paths and
// subprocess launching, which the library deliberately does not do.
//
// The mapping is READ, never derived.  --core-map is the file the hosted
// compiler wrote for the same snapshot; the identities and symbols in it are
// what this tool emits, and a request naming anything else is refused.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Input.h"
#include "spinel-mlir/Core/Emit.h"
#include "spinel-mlir/Core/Prelude.h"

#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

using namespace spinel_mlir;

namespace {

void usage(const char *argv0) {
  llvm::errs()
      << "usage: " << argv0
      << " --source <kernel.rb> --core-map <map.tsv> -o <out.o>\n"
         "       [--method <identity>] [--typedump <path>] [--clang <path>]\n"
         "       [--emit-mlir <out.mlir>] [--inputs-out <ledger>]\n"
         "       [--header-out <spinel_core_fail.h>] [--shim-out <shim.c>]\n"
         "       [-- <clang args>]\n"
         "       " << argv0 << " --print-prelude [--for <source.rb>]\n";
}

/// Decision 0042 stage 4: the embedded hosted prelude, whole, or the
/// definitions a copy of SOURCE gets. tools/core/spinel-core-build compares
/// the whole with the file it snapshotted, and appends the second to the
/// copy the hosted compiler reads.
int printPrelude(int argc, char **argv) {
  if (argc == 2) {
    llvm::outs() << core::hostedPrelude();
    return 0;
  }
  if (argc == 4 && llvm::StringRef(argv[2]) == "--for") {
    auto buf = llvm::MemoryBuffer::getFile(argv[3]);
    if (!buf) {
      llvm::errs() << "spinel-core-emit: cannot read " << argv[3] << "\n";
      return 2;
    }
    llvm::outs() << core::preludeFor((*buf)->getBuffer());
    return 0;
  }
  usage(argv[0]);
  return 2;
}

/// The mapping the hosted compiler wrote: identity, symbol, signature.
/// Parsed strictly -- a row this tool cannot read is a refusal, not a row to
/// skip, because skipping one would silently emit fewer symbols than the hosted
/// side declared.
bool readMapping(llvm::StringRef path, std::vector<core::CoreRootRequest> &out,
                 std::string &error) {
  auto buf = llvm::MemoryBuffer::getFile(path);
  if (!buf) { error = ("cannot read " + path).str(); return false; }
  llvm::StringRef text = (*buf)->getBuffer();
  size_t lineno = 0;
  while (!text.empty()) {
    auto split = text.split('\n');
    llvm::StringRef row = split.first;
    text = split.second;
    ++lineno;
    if (row.empty() || row.starts_with("#")) continue;
    auto a = row.split('\t');
    auto b = a.second.split('\t');
    if (a.first.empty() || b.first.empty()) {
      error = ("malformed mapping row " + std::to_string(lineno) + " in " + path).str();
      return false;
    }
    // The third column is the hosted prototype. A row without one is malformed:
    // the boundary check below has nothing to compare against, and silently
    // skipping it would make an unchecked boundary look like a checked one.
    if (b.second.empty()) {
      error = ("mapping row " + std::to_string(lineno) + " in " + path +
               " has no signature column").str();
      return false;
    }
    out.push_back({a.first.str(), b.first.str(), b.second.str()});
  }
  if (out.empty()) { error = ("no rows in " + path).str(); return false; }
  return true;
}

} // namespace

int main(int argc, char **argv) {
  std::string source, mapPath, output, typedump, clangPath, emitMlir, method, inputsOut,
      headerOut, shimOut;
  std::vector<std::string> clangArgs;
  if (argc >= 2 && llvm::StringRef(argv[1]) == "--print-prelude")
    return printPrelude(argc, argv);
  for (int i = 1; i < argc; ++i) {
    llvm::StringRef a = argv[i];
    auto next = [&](std::string &dst) {
      if (i + 1 >= argc) { usage(argv[0]); exit(2); }
      dst = argv[++i];
    };
    if (a == "--source") next(source);
    else if (a == "--core-map") next(mapPath);
    else if (a == "-o") next(output);
    else if (a == "--typedump") next(typedump);
    else if (a == "--clang") next(clangPath);
    else if (a == "--emit-mlir") next(emitMlir);
    else if (a == "--method") next(method);
    else if (a == "--inputs-out") next(inputsOut);
    else if (a == "--header-out") next(headerOut);
    else if (a == "--shim-out") next(shimOut);
    else if (a == "--") { for (int j = i + 1; j < argc; ++j) clangArgs.push_back(argv[j]); break; }
    else { usage(argv[0]); return 2; }
  }
  if (source.empty() || mapPath.empty() || output.empty()) { usage(argv[0]); return 2; }
  if (clangPath.empty()) {
    llvm::errs() << "spinel-core-emit: --clang is required; the caller resolves "
                    "the toolchain, this tool does not search for one\n";
    return 2;
  }

  std::vector<core::CoreRootRequest> roots;
  std::string error;
  if (!readMapping(mapPath, roots, error)) {
    llvm::errs() << "spinel-core-emit: " << error << "\n";
    return 2;
  }
  // --method narrows the mapping to one row rather than adding a root: a root
  // that is not in the mapping has no symbol, and inventing one here is the
  // thing the mapping exists to prevent.
  if (!method.empty()) {
    std::vector<core::CoreRootRequest> one;
    for (const auto &r : roots) if (r.identity == method) one.push_back(r);
    if (one.empty()) {
      llvm::errs() << "spinel-core-emit: --method '" << method
                   << "' is not in " << mapPath << "\n";
      return 2;
    }
    roots = one;
  }

  if (typedump.empty())
    typedump = core::defaultContractReader(argv[0], reinterpret_cast<void *>(&usage));
  if (typedump.empty()) {
    llvm::errs() << "spinel-core-emit: no contract reader; build tools/contract "
                    "or pass --typedump PATH\n";
    return 2;
  }
  // Decision 0042 stage 4: as the checker reads it, with the prelude.
  std::vector<std::string> keep;
  for (const auto &r : roots) keep.push_back(r.identity);
  auto module = core::loadContract(source, typedump,
                                   [](llvm::StringRef s) { llvm::errs() << s << "\n"; },
                                   inputsOut, 64, /*withPrelude=*/true, keep);
  if (!module) return 2;

  llvm::SmallString<128> tmpdir;
  if (llvm::sys::fs::createUniqueDirectory("spinel-core-emit", tmpdir)) {
    llvm::errs() << "spinel-core-emit: cannot create a temporary directory\n";
    return 2;
  }
  auto tempPath = [&](llvm::StringRef name) {
    llvm::SmallString<128> p(tmpdir);
    llvm::sys::path::append(p, name);
    return std::string(p);
  };
  auto runTool = [&](llvm::StringRef tool, llvm::ArrayRef<llvm::StringRef> args,
                     llvm::StringRef outPath, llvm::StringRef errPath) {
    std::optional<llvm::StringRef> redirects[3] = {
        std::nullopt,
        outPath.empty() ? std::nullopt : std::optional<llvm::StringRef>(outPath),
        errPath.empty() ? std::nullopt : std::optional<llvm::StringRef>(errPath)};
    return llvm::sys::ExecuteAndWait(tool, args, std::nullopt, redirects);
  };

  core::CoreEmitRequest req;
  req.roots = roots;
  req.outputPath = output;
  req.clangPath = clangPath;
  req.clangArgs = clangArgs;
  req.emitMlirPath = emitMlir;
  req.headerPath = headerOut;
  req.shimPath = shimOut;

  int failures = 0;
  auto diag = [&](llvm::StringRef m) { ++failures; llvm::errs() << m << "\n"; };
  auto status = core::emitCoreObject(*module, req, runTool, tempPath, diag);
  llvm::sys::fs::remove_directories(tmpdir);
  switch (status) {
  case core::CoreEmitStatus::Ok:
    llvm::outs() << "spinel-core-emit: wrote " << output << "\n";
    return 0;
  case core::CoreEmitStatus::InputRejected:  return 1;
  case core::CoreEmitStatus::BadRequest:     return 2;
  case core::CoreEmitStatus::Infrastructure: return 3;
  }
  return 3;
}
