//===- spinel-core-adapter - the Full adapter for one contract ------------===//
//
// Decision 0007 task 4.  Reads a validated contract and writes the adapter's
// C header and source beside the CORE header the kernel tool generated.
//
//   spinel-core-adapter <contract> --root <dir> --outdir <dir>
//                       [--core-header <name>] [--typedump <path>] [--failure-sites]
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Adapter.h"
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Input.h"

#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <string>

using namespace llvm;
using namespace spinel_mlir;

namespace {
void usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " <contract> --root <dir> --outdir <dir>\n"
            "       [--core-header <name>] [--typedump <path>] [--failure-sites]\n";
}
} // namespace

int main(int argc, char **argv) {
  std::string contract, root, outdir, coreHeader, typedump;
  bool failureSites = false; // a debugging aid, paired with spinel-core-kernel --failure-sites
  for (int i = 1; i < argc; ++i) {
    StringRef a = argv[i];
    auto next = [&](StringRef what) -> std::string {
      if (i + 1 >= argc) {
        errs() << "spinel-core-adapter: " << what << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--root") root = next("--root");
    else if (a == "--outdir") outdir = next("--outdir");
    else if (a == "--core-header") coreHeader = next("--core-header");
    else if (a == "--typedump") typedump = next("--typedump");
    else if (a == "--failure-sites") failureSites = true;
    else if (a.starts_with("--")) {
      errs() << "spinel-core-adapter: unknown option " << a << "\n";
      return 2;
    } else if (contract.empty()) contract = a.str();
    else { errs() << "spinel-core-adapter: more than one contract given\n"; return 2; }
  }
  if (contract.empty() || outdir.empty()) { usage(argv[0]); return 2; }

  SmallString<256> rootDir;
  if (!root.empty()) rootDir = root;
  else {
    rootDir = sys::path::parent_path(contract);
    if (rootDir.empty()) rootDir = ".";
  }
  if (typedump.empty())
    typedump = core::defaultContractReader(argv[0], reinterpret_cast<void *>(&usage));
  if (typedump.empty()) {
    errs() << "spinel-core-adapter: no contract reader; build tools/contract or "
              "pass --typedump PATH\n";
    return 2;
  }

  bool any = false;
  auto diag = [&](StringRef m) { any = true; errs() << m << "\n"; };
  // The SAME preparation the header and the kernel use: one snapshot
  // discipline, so the adapter cannot be generated from a different reading of
  // the source than the object it calls.
  auto prepared = core::prepareBoundary(contract, rootDir, typedump, diag);
  if (!prepared) {
    if (!any) errs() << contract << ":0: refused: the contract was rejected\n";
    return 1;
  }
  const core::BoundaryContract &c = prepared->contract;
  if (!c.result) {
    errs() << contract << ":0: unsupported-boundary: the contract declares no "
              "`result`; the adapter publishes one\n";
    return 1;
  }

  if (auto ec = sys::fs::create_directories(outdir)) {
    errs() << "spinel-core-adapter: cannot create " << outdir << ": "
           << ec.message() << "\n";
    return 3;
  }
  const std::string header = "spinel_adapter_" + c.entry + ".h";
  const std::string source = "spinel_adapter_" + c.entry + ".c";
  const std::string core = coreHeader.empty() ? ("spinel_core_" + c.entry + ".h")
                                              : coreHeader;
  auto write = [&](StringRef name, auto emit) -> bool {
    SmallString<256> path(outdir);
    sys::path::append(path, name);
    std::error_code ec;
    raw_fd_ostream os(path, ec, sys::fs::OF_Text);
    if (ec) {
      errs() << "spinel-core-adapter: cannot write " << path << ": "
             << ec.message() << "\n";
      return false;
    }
    emit(os);
    return true;
  };
  // The registry first, and once: every adapter in the program shares it.
  if (!write("spinel_adapter_registry.h",
             [&](raw_ostream &os) { core::emitRegistryHeader(os); }))
    return 3;
  if (!write("spinel_adapter_registry.c",
             [&](raw_ostream &os) { core::emitRegistrySource(os); }))
    return 3;
  if (!write(header, [&](raw_ostream &os) {
        core::emitAdapterHeader(c, contract, os);
      }))
    return 3;
  if (!write(source, [&](raw_ostream &os) {
        core::emitAdapterSource(c, contract, core, os, failureSites);
      }))
    return 3;
  if (!write("core_" + c.entry + ".rb",
             [&](raw_ostream &os) { core::emitAdapterRuby(c, contract, os); }))
    return 3;
  outs() << "spinel-core-adapter: wrote " << outdir << "/" << header << " and "
         << source << "\n";
  return 0;
}
