//===- spinel-core-package - bind a contract's artefacts together ---------===//
//
// Decision 0007 task 4.  A contract produces four generated files and one
// object, and a consumer compiles against one of them while linking another.
// Nothing in a header or an object says which contract it came from once they
// are separate files, so this writes a manifest that does, and verifies it.
//
//   spinel-core-package write  <contract> --root <dir> --dir <d> -o <manifest>
//   spinel-core-package verify <manifest>
//
// What a manifest is for: swapping one contract's object for another's, or
// editing an identity into a header, changes a digest and the verification
// refuses. It is an integrity check between artefacts of one build, NOT a
// signature: anyone who can rewrite a file can rewrite the manifest beside it.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Input.h"

#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SHA256.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

using namespace llvm;
using namespace spinel_mlir;

namespace {

void usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " write <contract> --root <dir> --dir <d> -o <manifest>\n"
            "       " << argv0 << " verify <manifest>\n";
}

bool digestOf(StringRef path, std::string &out, std::string &error) {
  auto b = MemoryBuffer::getFile(path, /*IsText=*/false,
                                 /*RequiresNullTerminator=*/false,
                                 /*IsVolatile=*/true);
  if (!b) { error = b.getError().message(); return false; }
  SHA256 h;
  h.update((*b)->getBuffer());
  out = toHex(h.final(), /*LowerCase=*/true);
  return true;
}

/// The identity a generated text file claims, read back from it.
///
/// Both the header and the Ruby module print it; a file that claims a
/// different one from the manifest is the case this exists for, and reading it
/// rather than trusting the digest alone is what makes an EDITED identity a
/// refusal with something to say.
std::string claimedIdentity(StringRef path) {
  auto b = MemoryBuffer::getFile(path);
  if (!b) return "";
  StringRef text = (*b)->getBuffer();
  const size_t at = text.find("contract identity: ");
  if (at == StringRef::npos) return "";
  StringRef rest = text.substr(at + strlen("contract identity: "));
  return rest.take_until([](char c) { return c == '\n' || c == '\r'; }).str();
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) { usage(argv[0]); return 2; }
  const StringRef mode = argv[1];

  if (mode == "verify") {
    if (argc != 3) { usage(argv[0]); return 2; }
    auto buf = MemoryBuffer::getFile(argv[2]);
    if (!buf) {
      errs() << "spinel-core-package: cannot read " << argv[2] << "\n";
      return 2;
    }
    SmallString<256> dir(sys::path::parent_path(argv[2]));
    if (dir.empty()) dir = ".";
    std::string identity;
    bool bad = false;
    size_t files = 0;
    for (StringRef line : llvm::split((*buf)->getBuffer(), '\n')) {
      line = line.trim();
      if (line.empty() || line.starts_with("#")) continue;
      SmallVector<StringRef, 4> f;
      line.split(f, '\t');
      if (f[0] == "core-package") continue;
      if (f[0] == "identity" && f.size() == 2) { identity = f[1].str(); continue; }
      if (f[0] == "snapshot") continue;
      if (f[0] == "file" && f.size() == 3) {
        SmallString<256> path(dir);
        sys::path::append(path, f[1]);
        std::string got, error;
        if (!digestOf(path, got, error)) {
          errs() << argv[2] << ": missing-artefact: " << f[1] << ": " << error << "\n";
          bad = true;
          continue;
        }
        ++files;
        if (got != f[2]) {
          errs() << argv[2] << ": digest-mismatch: " << f[1] << " is " << got
                 << ", the manifest says " << f[2] << "\n";
          bad = true;
          continue;
        }
        // A text artefact that names an identity must name THIS one. The digest
        // already catches an edit; this says what was wrong when it is an
        // identity rather than anything else.
        const std::string claims = claimedIdentity(path);
        if (!claims.empty() && !identity.empty() && claims != identity) {
          errs() << argv[2] << ": identity-mismatch: " << f[1] << " claims \""
                 << claims << "\", the manifest says \"" << identity << "\"\n";
          bad = true;
        }
        continue;
      }
      errs() << argv[2] << ": unreadable-manifest: " << line << "\n";
      bad = true;
    }
    if (files == 0) {
      errs() << argv[2] << ": empty-manifest: it names no artefacts, so "
                           "verifying it establishes nothing\n";
      return 1;
    }
    if (bad) return 1;
    outs() << "spinel-core-package: " << files << " artefact(s) verified against "
           << argv[2] << "\n";
    return 0;
  }

  if (mode != "write") { usage(argv[0]); return 2; }

  std::string contract, root, dir, out, typedump;
  for (int i = 2; i < argc; ++i) {
    StringRef a = argv[i];
    auto next = [&](StringRef what) -> std::string {
      if (i + 1 >= argc) {
        errs() << "spinel-core-package: " << what << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--root") root = next("--root");
    else if (a == "--dir") dir = next("--dir");
    else if (a == "-o") out = next("-o");
    else if (a == "--typedump") typedump = next("--typedump");
    else if (a.starts_with("--")) {
      errs() << "spinel-core-package: unknown option " << a << "\n";
      return 2;
    } else if (contract.empty()) contract = a.str();
    else { errs() << "spinel-core-package: more than one contract\n"; return 2; }
  }
  if (contract.empty() || dir.empty() || out.empty()) { usage(argv[0]); return 2; }

  SmallString<256> rootDir;
  if (!root.empty()) rootDir = root;
  else {
    rootDir = sys::path::parent_path(contract);
    if (rootDir.empty()) rootDir = ".";
  }
  if (typedump.empty())
    typedump = core::defaultContractReader(argv[0], reinterpret_cast<void *>(&usage));
  if (typedump.empty()) {
    errs() << "spinel-core-package: no contract reader; pass --typedump PATH\n";
    return 2;
  }
  bool any = false;
  auto diag = [&](StringRef m) { any = true; errs() << m << "\n"; };
  auto prepared = core::prepareBoundary(contract, rootDir, typedump, diag);
  if (!prepared) {
    if (!any) errs() << contract << ":0: refused: the contract was rejected\n";
    return 1;
  }
  const core::BoundaryContract &c = prepared->contract;

  // Every artefact of this contract, by ROLE. The roles are what make a swap
  // detectable: an object in the CORE slot that is really the adapter's has a
  // different digest, whatever it is named.
  const std::vector<std::string> names = {
      "spinel_core_" + c.entry + ".h",
      c.entry + ".o",
      "spinel_adapter_" + c.entry + ".h",
      "spinel_adapter_" + c.entry + ".c",
      "spinel_adapter_registry.h",
      "spinel_adapter_registry.c",
      "core_" + c.entry + ".rb",
  };

  std::error_code ec;
  raw_fd_ostream os(out, ec, sys::fs::OF_Text);
  if (ec) {
    errs() << "spinel-core-package: cannot write " << out << ": " << ec.message() << "\n";
    return 3;
  }
  os << "# Generated -- do not edit.\n"
     << "#\n"
     << "# The artefacts of one contract, bound together. A consumer compiles\n"
     << "# against one of these and links another, and once they are separate\n"
     << "# files nothing in them says which contract they came from.\n"
     << "#\n"
     << "# This is an integrity check between artefacts of one build, not a\n"
     << "# signature: whoever can rewrite a file can rewrite this beside it.\n"
     << "core-package\t1\n"
     << "identity\t" << core::boundaryIdentity(c) << "\n"
     << "snapshot\t" << c.rootDigest << "\n";
  for (const std::string &name : names) {
    SmallString<256> path(dir);
    sys::path::append(path, name);
    std::string got, error;
    if (!digestOf(path, got, error)) {
      errs() << "spinel-core-package: cannot digest " << path << ": " << error
             << "\n";
      return 3;
    }
    os << "file\t" << name << "\t" << got << "\n";
  }
  os.close();
  outs() << "spinel-core-package: wrote " << out << "\n";
  return 0;
}
