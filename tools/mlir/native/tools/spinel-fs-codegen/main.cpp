//===- main.cpp - spinel-fs-codegen ---------------------------------------===//
//
// The machine-code step of the freestanding lane, as its own command:
//
//   spinel-fs-codegen --profile <p.yaml> [--menus <menus.yaml>]
//                     [--profile-cflags-only] --print-data-layout
//   spinel-fs-codegen --profile <p.yaml> [--menus <menus.yaml>]
//                     [--profile-cflags-only] <in.ll> -o <out.o>
//
// The flags it compiles with are the ones the emitter used to give clang:
// -mcpu=<the profile's cpu>, -O2 -ffreestanding -fno-builtin, then the
// profile's cflags. --profile-cflags-only takes the profile's cflags alone,
// which is what spinel-fs-grad gave clang for the adjoint. What each flag
// means is lib/Freestanding/Codegen.cpp's table.
//
// It writes the object and nothing else: the emitter and the grad generator
// keep the order of their steps, compare the layout again afterwards and run
// the undef gate themselves.
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Freestanding/Codegen.h"
#include "spinel-mlir/Freestanding/Diagnostics.h"
#include "spinel-mlir/Freestanding/PlatformLedger.h"
#include "spinel-mlir/Freestanding/Profile.h"

#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

using namespace llvm;
namespace fs_ = spinel_mlir::freestanding;

namespace {

int usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " --profile <p.yaml> [--menus <menus.yaml>] [--profile-cflags-only]"
            " --print-data-layout\n"
         << "   or: " << argv0
         << " --profile <p.yaml> [--menus <menus.yaml>] [--profile-cflags-only]"
            " <in.ll> -o <out.o>\n";
  return 2;
}

int die(const Twine &message) {
  errs() << "spinel-fs-codegen: " << message << "\n";
  return 1;
}

} // namespace

int main(int argc, char **argv) {
  std::string profilePath, menusPath, input, output;
  bool printLayout = false, cflagsOnly = false;
  for (int i = 1; i < argc; ++i) {
    StringRef a(argv[i]);
    auto take = [&](std::string &dst) {
      if (i + 1 >= argc || !dst.empty())
        return false;
      dst = argv[++i];
      return true;
    };
    if (a == "--profile") { if (!take(profilePath)) return usage(argv[0]); }
    else if (a == "--menus") { if (!take(menusPath)) return usage(argv[0]); }
    else if (a == "-o") { if (!take(output)) return usage(argv[0]); }
    else if (a == "--print-data-layout") printLayout = true;
    else if (a == "--profile-cflags-only") cflagsOnly = true;
    else if (!a.starts_with("-") && input.empty()) input = a.str();
    else return usage(argv[0]);
  }
  if (profilePath.empty() || printLayout == (!input.empty() || !output.empty()) ||
      (!printLayout && (input.empty() || output.empty())))
    return usage(argv[0]);

  // The profile is read the way the emitter reads it, ledger and all.
  auto yaml = MemoryBuffer::getFile(profilePath);
  if (!yaml)
    return die("cannot read " + profilePath + ": " + yaml.getError().message());
  if (menusPath.empty())
    menusPath = fs_::locateDefaultLedger(argv[0]);
  bool rejected = false;
  auto diag = [&](const fs_::Rejection &r) {
    rejected = true;
    errs() << fs_::formatRejection(r) << "\n";
  };
  std::string ledgerInfra;
  auto profile = fs_::resolveFreestandingProfile(
      profilePath, (*yaml)->getBuffer(), menusPath, diag, &ledgerInfra);
  if (!ledgerInfra.empty())
    return die("ledger: " + ledgerInfra);
  if (!profile)
    return rejected ? 1 : die("cannot read the profile " + profilePath);

  std::vector<std::string> flags;
  if (!cflagsOnly) {
    if (!profile->cpu().empty())
      flags.push_back(("-mcpu=" + profile->cpu()).str());
    for (const char *f : {"-O2", "-ffreestanding", "-fno-builtin"})
      flags.push_back(f);
  }
  for (const std::string &f : profile->cflags())
    flags.push_back(f);

  std::string error;
  auto config = fs_::codegenConfigFromFlags(profile->triple(), flags, error);
  if (!config)
    return die(error);

  if (printLayout) {
    auto layout = fs_::codegenDataLayout(*config, error);
    if (!layout)
      return die(error);
    outs() << *layout << "\n";
    return 0;
  }

  LLVMContext context;
  SMDiagnostic parseError;
  std::unique_ptr<Module> module = parseIRFile(input, parseError, context);
  if (!module) {
    std::string text;
    raw_string_ostream os(text);
    parseError.print("spinel-fs-codegen", os);
    errs() << os.str();
    return 1;
  }
  if (!fs_::optimizeAndEmitObject(*module, *config, output, error))
    return die(error);
  return 0;
}
