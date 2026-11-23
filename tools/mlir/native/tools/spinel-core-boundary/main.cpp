//===- spinel-core-boundary - parse a contract, emit its C header ---------===//
//
// Decision 0007 task 1.  Two jobs and no more: validate a version-1 contract
// file, and emit the C header that describes the boundary it names.
//
//   spinel-core-boundary <contract> [--root <dir>] [--header <out.h>]
//                                   [--identity] [--layout <s>]
//
// `--root` is the directory the contract's `root` path resolves against
// (default: the contract's own directory), so a contract does not depend on
// the caller's working directory.  `--identity` prints the canonical identity
// line and nothing else, which is what a packaging step compares.
//
// Exit 0 only when the contract is fully valid.  On any defect every
// diagnostic is printed and the exit status is 1; no partial header is written.
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Input.h"

#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/SHA256.h"

#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;
using namespace spinel_mlir::core;

int main(int argc, char **argv) {
  StringRef contract, root, header, layout;
  bool identity = false;
  for (int i = 1; i < argc; ++i) {
    StringRef a = argv[i];
    auto next = [&](StringRef what) -> StringRef {
      if (i + 1 >= argc) {
        errs() << "spinel-core-boundary: " << what << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--root") root = next("--root");
    else if (a == "--header") header = next("--header");
    else if (a == "--layout") layout = next("--layout");
    else if (a == "--identity") identity = true;
    else if (a.starts_with("--")) { errs() << "spinel-core-boundary: unknown option " << a << "\n"; return 2; }
    else if (contract.empty()) contract = a;
    else { errs() << "spinel-core-boundary: more than one contract given\n"; return 2; }
  }
  if (contract.empty()) {
    errs() << "usage: spinel-core-boundary <contract> [--root <dir>] "
              "[--header <out.h>] [--identity] [--layout <s>]\n";
    return 2;
  }

  std::string reader = spinel_mlir::core::defaultContractReader(argv[0], (void *)(intptr_t)main);
  if (reader.empty()) {
    errs() << "spinel-core-boundary: no contract reader beside this executable\n";
    return 2;
  }

  SmallString<256> rootDir;
  if (!root.empty()) rootDir = root;
  else {
    rootDir = sys::path::parent_path(contract);
    if (rootDir.empty()) rootDir = ".";
  }

  bool any = false;
  auto diag = [&](StringRef m) { any = true; errs() << m << "\n"; };
  // Contract, owned snapshot, analysis, digest and entry -- all of it in the
  // library, so this tool and spinel-core-kernel cannot come to hold two
  // snapshot disciplines that drift apart.
  auto prepared = prepareBoundary(contract, rootDir, reader, diag);
  if (!prepared) {
    if (!any) errs() << contract << ":0: refused: the contract was rejected\n";
    return 1;
  }
  const BoundaryContract *c = &prepared->contract;

  if (identity) {
    outs() << boundaryIdentity(*c) << "\n";
    return 0;
  }

  std::string lay = layout.empty() ? hostTargetLayout() : layout.str();
  if (header.empty()) {
    emitBoundaryHeader(*c, contract, lay, outs());
    return 0;
  }
  std::error_code ec;
  raw_fd_ostream os(header, ec, sys::fs::OF_Text);
  if (ec) {
    errs() << "spinel-core-boundary: cannot write " << header << ": " << ec.message() << "\n";
    return 2;
  }
  emitBoundaryHeader(*c, contract, lay, os);
  return 0;
}
