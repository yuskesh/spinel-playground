//===- spinel-core-kernel - contract in, checked CORE object out ----------===//
//
// Decision 0007 task 2.  The CLI half: arguments, temporary paths and
// subprocess launching, which the library deliberately does not do.
//
//   spinel-core-kernel <contract> --root <dir> -o <out.o>
//                      [--header <out.h>] [--layout <s>] [--identity]
//                      [--emit-mlir <out.mlir>] --clang <path>
//                      [--report <out.json> --profile hosted-stage2|realtime
//                       [--report-revision <rev>]] [-- <clang args>]
//
// The header and the object come from ONE run over ONE snapshot, so the
// declaration a C caller compiles against and the definition it links cannot
// describe two different contracts. The report, when asked for, comes from the
// same run too, and is written last: it digests the object it describes.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Input.h"
#include "spinel-mlir/Core/Kernel.h"
#include "spinel-mlir/Core/Report.h"

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
void usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " <contract> --root <dir> -o <out.o> --clang <path>\n"
            "       [--header <out.h>] [--extern-header <out.h>] [--layout <s>] [--identity]\n"
            "       [--admit-only] [--record-cross [--record-cross-frame <bytes>]]\n"
            "       [--emit-mlir <out.mlir>] [--emit-optimised-ir <out.bc>]\n"
            "       [--typedump <path>] [--int-width=32|64] [--int64-allow <table.tsv>]\n"
            "       [--failure-sites <sites.tsv>]\n"
            "       [--report <out.json> --profile hosted-stage2|realtime\n"
            "        [--config-binding <dts-sha256>:<config-sha256>:<flags-sha256>]\n"
            "        [--report-revision <rev>]\n"
            "        [--fixture-stack-provision <bytes> --fixture-interrupt-reserve <bytes>]]\n"
            "       [-- <clang args>]\n";
}
} // namespace

int main(int argc, char **argv) {
  std::string contract, root, output, header, externHeader, layout, emitMlir, clangPath, typedump;
  std::string reportPath, profile, reportRevision, configBinding;
  bool revisionGiven = false;
  unsigned profileIntegerBits = 0;
  std::string int64Allow; // decision 0019's table; empty: the repository's
  std::string failureSites; // a debugging aid: the failure-site table to write
  // Decision 0010's two policy terms, for the step 2 proof of concept only.
  // Report.h states the three mechanisms that keep them out of a real build;
  // the first of them is here, in the name and in the refusal below.
  std::string fixtureProvision, fixtureReserve;
  // The IR code generation consumed. The build always produces it (below);
  // this flag only says where to keep it, so that decision 0010's cross-check
  // -- `.llvm_stack_sizes` from a side compile of the SAME IR -- can be run by
  // something other than the kernel itself. Without it the file lives and dies
  // inside a temporary directory and the cross-check is not reproducible.
  std::string emitOptimisedIr;
  std::vector<std::string> clangArgs;
  bool identity = false;
  // Decision 0014: admission alone, for the application tool's cross-entry
  // checks and for tests of the contract; no object, header or report.
  bool admitOnly = false;
  // 0014 §10: the verification lowering, cross-context accesses recorded
  bool recordCross = false;
  std::string recordCrossFrame; // the hooks' attested frame, for the report
  for (int i = 1; i < argc; ++i) {
    StringRef a = argv[i];
    auto next = [&](StringRef what) -> std::string {
      if (i + 1 >= argc) {
        errs() << "spinel-core-kernel: " << what << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--root") root = next("--root");
    else if (a == "-o") output = next("-o");
    else if (a == "--header") header = next("--header");
    else if (a == "--extern-header") externHeader = next("--extern-header");
    else if (a == "--layout") layout = next("--layout");
    else if (a == "--emit-mlir") emitMlir = next("--emit-mlir");
    else if (a == "--clang") clangPath = next("--clang");
    else if (a == "--typedump") typedump = next("--typedump");
    else if (a == "--int64-allow") int64Allow = next("--int64-allow");
    else if (a == "--failure-sites") failureSites = next("--failure-sites");
    else if (a.starts_with("--int-width=")) {
      StringRef width = a.drop_front(12);
      if (width != "32" && width != "64") {
        errs() << "spinel-core-kernel: --int-width must be 32 or 64\n";
        return 2;
      }
      profileIntegerBits = width == "32" ? 32 : 64;
    }

    else if (a == "--report") reportPath = next("--report");
    else if (a == "--profile") profile = next("--profile");
    else if (a == "--emit-optimised-ir") emitOptimisedIr = next("--emit-optimised-ir");
    else if (a == "--fixture-stack-provision")
      fixtureProvision = next("--fixture-stack-provision");
    else if (a == "--fixture-interrupt-reserve")
      fixtureReserve = next("--fixture-interrupt-reserve");
    else if (a == "--report-revision") {
      reportRevision = next("--report-revision");
      revisionGiven = true;
    }
    else if (a == "--identity") identity = true;
    else if (a == "--admit-only") admitOnly = true;
    else if (a == "--record-cross") recordCross = true;
    else if (a == "--record-cross-frame") recordCrossFrame = next("--record-cross-frame");
    else if (a == "--config-binding") configBinding = next("--config-binding");
    else if (a == "--") { for (++i; i < argc; ++i) clangArgs.push_back(argv[i]); }
    else if (a.starts_with("--")) {
      errs() << "spinel-core-kernel: unknown option " << a << "\n";
      return 2;
    } else if (contract.empty()) contract = a.str();
    else { errs() << "spinel-core-kernel: more than one contract given\n"; return 2; }
  }
  if (contract.empty() || (output.empty() && !admitOnly)) { usage(argv[0]); return 2; }
  if (clangPath.empty()) {
    // Same rule the unchecked core lane states: the caller resolves the
    // toolchain. A tool that searched the PATH could assemble IR from one LLVM
    // with the clang of another, and the first symptom is an unrelated syntax
    // error in the .ll.
    errs() << "spinel-core-kernel: --clang is required; the caller resolves the "
              "toolchain, this tool does not search for one\n";
    return 2;
  }
  // Decision 0010: the profile is an explicit input, and it means something
  // only for a report. Each without the other is refused rather than given a
  // default, so an existing invocation cannot acquire a profile by accident.
  if (!reportPath.empty() && profile.empty()) {
    errs() << "spinel-core-kernel: --report needs --profile; the profile is "
              "recorded in the report and has no default\n";
    return 2;
  }
  if (reportPath.empty() && !profile.empty()) {
    errs() << "spinel-core-kernel: --profile is meaningful only with --report\n";
    return 2;
  }
  if (reportPath.empty() && revisionGiven) {
    errs() << "spinel-core-kernel: --report-revision is meaningful only with "
              "--report\n";
    return 2;
  }
  if (!profile.empty() && profile != core::kHostedStage2Profile &&
      profile != core::kRealtimeProfile) {
    errs() << "spinel-core-kernel: profile '" << profile
           << "' is not implemented; this build reports under "
           << core::kHostedStage2Profile << " and " << core::kRealtimeProfile
           << "\n";
    return 2;
  }
  core::FixtureStackProfile fixtureStack;
  if (!fixtureProvision.empty() || !fixtureReserve.empty()) {
    if (fixtureProvision.empty() || fixtureReserve.empty()) {
      errs() << "spinel-core-kernel: --fixture-stack-provision and "
                "--fixture-interrupt-reserve are given together or not at all; "
                "the inequality needs both terms\n";
      return 2;
    }
    // The flags exist for decision 0010's step 2 proof of concept, which has
    // to show both branches of the inequality. They are NOT a target profile:
    // a real provision comes from the target profile or the entry's contract,
    // and a real reserve carries the interrupt nesting assumption it rests on.
    if (profile != core::kRealtimeProfile) {
      errs() << "spinel-core-kernel: the fixture stack provision is accepted "
                "only with --profile "
             << core::kRealtimeProfile << "\n";
      return 2;
    }
    if (StringRef(fixtureProvision).getAsInteger(10, fixtureStack.provisionedStack) ||
        StringRef(fixtureReserve).getAsInteger(10, fixtureStack.interruptReserve)) {
      errs() << "spinel-core-kernel: the fixture stack provision and reserve "
                "are byte counts in decimal\n";
      return 2;
    }
    fixtureStack.given = true;
  }
  if (revisionGiven && reportRevision.empty()) {
    errs() << "spinel-core-kernel: --report-revision needs a non-empty value\n";
    return 2;
  }
  // A report written over the object it describes would be the one way this
  // flag could change an artifact. The object is digested INTO the report, so
  // the overwrite would even look like it had worked.
  if (!reportPath.empty())
    for (const auto &other : {std::make_pair(StringRef("-o"), StringRef(output)),
                              std::make_pair(StringRef("--header"), StringRef(header)),
                              std::make_pair(StringRef("--emit-mlir"), StringRef(emitMlir))}) {
      if (other.second.empty()) continue;
      bool same = reportPath == other.second.str();
      if (!same) sys::fs::equivalent(Twine(reportPath), Twine(other.second), same);
      if (same) {
        errs() << "spinel-core-kernel: --report names the same file as "
               << other.first << "; the report would be written over it\n";
        return 2;
      }
    }

  // Same reason as the report's check below it: this file is written DURING
  // the emission, so naming an output with it would destroy that output before
  // the run that produced it had finished.
  if (!emitOptimisedIr.empty())
    for (const auto &other : {std::make_pair(StringRef("-o"), StringRef(output)),
                              std::make_pair(StringRef("--header"), StringRef(header)),
                              std::make_pair(StringRef("--emit-mlir"), StringRef(emitMlir)),
                              std::make_pair(StringRef("--report"), StringRef(reportPath))}) {
      if (other.second.empty()) continue;
      bool same = emitOptimisedIr == other.second.str();
      if (!same) sys::fs::equivalent(Twine(emitOptimisedIr), Twine(other.second), same);
      if (same) {
        errs() << "spinel-core-kernel: --emit-optimised-ir names the same file "
                  "as " << other.first << "\n";
        return 2;
      }
    }

  SmallString<256> rootDir;
  if (!root.empty()) rootDir = root;
  else {
    rootDir = sys::path::parent_path(contract);
    if (rootDir.empty()) rootDir = ".";
  }

  if (typedump.empty())
    typedump = core::defaultContractReader(argv[0], reinterpret_cast<void *>(&usage));
  if (typedump.empty()) {
    errs() << "spinel-core-kernel: no contract reader; build tools/contract or "
              "pass --typedump PATH\n";
    return 2;
  }

  bool any = false;
  auto diag = [&](StringRef m) { any = true; errs() << m << "\n"; };
  if (admitOnly && (!output.empty() || !header.empty())) {
    errs() << "spinel-core-kernel: --admit-only writes no object; drop -o and --header\n";
    return 2;
  }

  SmallString<128> tmpdir;
  if (sys::fs::createUniqueDirectory("spinel-core-kernel", tmpdir)) {
    errs() << "spinel-core-kernel: cannot create a temporary directory\n";
    return 3;
  }
  auto tempPath = [&](StringRef name) {
    SmallString<128> p(tmpdir);
    sys::path::append(p, name);
    return std::string(p);
  };
  auto runTool = [&](StringRef tool, ArrayRef<StringRef> args, StringRef outPath,
                     StringRef errPath) {
    std::optional<StringRef> redirects[3] = {
        std::nullopt,
        outPath.empty() ? std::nullopt : std::optional<StringRef>(outPath),
        errPath.empty() ? std::nullopt : std::optional<StringRef>(errPath)};
    return sys::ExecuteAndWait(tool, args, std::nullopt, redirects);
  };

  unsigned pointerBits = 64;
  // THE HEADER'S LAYOUT IS THE TARGET'S, NOT THE HOST'S. The triple comes from
  // clang with the caller's own arguments, so `--target=` after `--` is seen
  // here exactly as the emission sees it. A cross target must be named with
  // `--layout`, and a given `--layout` must agree with the triple: the first
  // thumbv8m build (2026-09-22) wrote `ptr64-i64-64long` into the header of a
  // 32-bit object, and nothing refused it.
  {
    std::vector<StringRef> tripleArgs{clangPath};
    for (const std::string &a : clangArgs) tripleArgs.push_back(a);
    tripleArgs.push_back("-print-target-triple");
    const std::string tripleOut = tempPath("clang-triple.out");
    std::string triple;
    if (runTool(clangPath, tripleArgs, tripleOut, tempPath("clang-triple.err")) == 0)
      if (auto buf = MemoryBuffer::getFile(tripleOut))
        triple = (*buf)->getBuffer().split('\n').first.trim().str();
    if (triple.empty()) {
      errs() << "spinel-core-kernel: cannot ask " << clangPath
             << " for its target triple with the given arguments\n";
      sys::fs::remove_directories(tmpdir);
      return 3;
    }
    if (!core::targetPointerBits(triple)) {
      errs() << "spinel-core-kernel: unknown target pointer width for " << triple << "\n";
      sys::fs::remove_directories(tmpdir);
      return 2;
    }
    const std::string derived = core::targetLayoutFor(triple);
    pointerBits = core::targetPointerBits(triple);
    if (layout.empty() && derived != core::hostTargetLayout()) {
      errs() << "spinel-core-kernel: the target " << triple
             << " is not this host's; pass --layout " << derived
             << " so the header states the widths it was generated for\n";
      sys::fs::remove_directories(tmpdir);
      return 2;
    }
    if (!layout.empty() && layout != derived) {
      errs() << "spinel-core-kernel: --layout " << layout
             << " disagrees with the target " << triple << ", whose layout is "
             << derived << "\n";
      sys::fs::remove_directories(tmpdir);
      return 2;
    }
  }

  auto prepared = core::prepareBoundary(contract, rootDir, typedump, diag, pointerBits, profileIntegerBits, int64Allow);
  if (!prepared) {
    if (!any) errs() << contract << ":0: refused: the contract was rejected\n";
    return 1;
  }

  if (identity) outs() << core::boundaryIdentity(prepared->contract) << "\n";

  if (admitOnly) {
    const auto admitted = core::admitCoreKernel(*prepared, diag);
    if (!admitted) {
      sys::fs::remove_directories(tmpdir);
      return 1;
    }
    outs() << "spinel-core-kernel: admitted " << prepared->contract.entry << " (core-contract "
           << prepared->contract.version << ", " << admitted->methods.size() << " method(s), "
           << admitted->externCalls.size() << " extern call(s))\n";
    // DECISION 0014: an admission-only report for a version 2 entry -- the
    // application tool's cross-entry checks read the effects and the extern
    // evidence from it before anything is lowered. It carries no object.
    if (!reportPath.empty()) {
      if (!prepared->contract.isApplication()) {
        errs() << "spinel-core-kernel: an admission-only report is a version 2 form; a "
                  "version 1 report describes an object\n";
        sys::fs::remove_directories(tmpdir);
        return 2;
      }
      core::CoreReportRequest rreq;
      rreq.path = reportPath;
      rreq.profile = profile;
      rreq.revision = reportRevision;
      rreq.contractPath = contract;
      rreq.readerPath = typedump;
      rreq.kernelPath = sys::fs::getMainExecutable(argv[0], reinterpret_cast<void *>(&usage));
      rreq.clangPath = clangPath;
      rreq.clangArgs = clangArgs;
      rreq.configBinding = configBinding;
      rreq.admissionOnly = true;
      const auto rs = core::writeCoreReport(*prepared, *admitted, rreq, runTool, tempPath, diag);
      sys::fs::remove_directories(tmpdir);
      if (rs != core::CoreEmitStatus::Ok) return rs == core::CoreEmitStatus::BadRequest ? 2 : 3;
      outs() << "spinel-core-kernel: wrote " << reportPath << "\n";
      return 0;
    }
    sys::fs::remove_directories(tmpdir);
    return 0;
  }

  core::CoreKernelRequest req;
  req.outputPath = output;
  req.clangPath = clangPath;
  req.clangArgs = clangArgs;
  req.pointerBits = pointerBits;
  req.emitMlirPath = emitMlir;
  req.recordCross = recordCross;
  req.failureSitesPath = failureSites;
  // THE OBJECT IS GENERATED FROM THIS FILE, always, not only when a report is
  // asked for. One path, so the object a report describes is produced by the
  // same command line as the object an ordinary build produces -- two paths
  // that agree today are two paths that can stop agreeing.
  const std::string optimisedIr =
      emitOptimisedIr.empty() ? tempPath("kern.opt.bc") : emitOptimisedIr;
  req.optimisedIrPath = optimisedIr;
  core::EligibilityReport admitted;
  if (!reportPath.empty()) req.admitted = &admitted;
  const auto status = core::emitCoreKernel(*prepared, req, runTool, tempPath, diag);
  auto exitFor = [](core::CoreEmitStatus s) {
    switch (s) {
    case core::CoreEmitStatus::Ok: return 0;
    case core::CoreEmitStatus::InputRejected:  return 1;
    case core::CoreEmitStatus::BadRequest:     return 2;
    case core::CoreEmitStatus::Infrastructure: return 3;
    }
    return 3;
  };
  if (status != core::CoreEmitStatus::Ok) {
    sys::fs::remove_directories(tmpdir);
    return exitFor(status);
  }

  // The header LAST, and only once the object exists: a header on disk for an
  // object that was never written would be a declaration of something nothing
  // defines.
  if (!header.empty()) {
    std::error_code ec;
    raw_fd_ostream os(header, ec, sys::fs::OF_Text);
    if (ec) {
      errs() << "spinel-core-kernel: cannot write " << header << ": "
             << ec.message() << "\n";
      sys::fs::remove_directories(tmpdir);
      return 3;
    }
    core::emitBoundaryHeader(prepared->contract, contract,
                             layout.empty() ? core::hostTargetLayout() : layout, os);
  }
  // DECISION 0014: the extern prototype header, for the providers. A version
  // 1 contract declares no externs and gets none.
  if (!externHeader.empty()) {
    if (!prepared->contract.isApplication()) {
      errs() << "spinel-core-kernel: --extern-header is a version 2 form; this contract "
                "declares no externs\n";
      sys::fs::remove_directories(tmpdir);
      return 2;
    }
    std::error_code ec;
    raw_fd_ostream os(externHeader, ec, sys::fs::OF_Text);
    if (ec) {
      errs() << "spinel-core-kernel: cannot write " << externHeader << ": "
             << ec.message() << "\n";
      sys::fs::remove_directories(tmpdir);
      return 3;
    }
    core::emitExternHeader(prepared->contract, contract, os);
  }
  outs() << "spinel-core-kernel: wrote " << output << "\n";

  // The report LAST: it digests the object, and it describes a build whose
  // header and object both exist.
  if (!reportPath.empty()) {
    core::CoreReportRequest rreq;
    rreq.path = reportPath;
    rreq.profile = profile;
    rreq.revision = reportRevision;
    rreq.contractPath = contract;
    rreq.objectPath = output;
    rreq.readerPath = typedump;
    rreq.kernelPath =
        sys::fs::getMainExecutable(argv[0], reinterpret_cast<void *>(&usage));
    rreq.clangPath = clangPath;
    rreq.clangArgs = clangArgs;
    rreq.optimisedIrPath = optimisedIr;
    rreq.fixtureStack = fixtureStack;
    rreq.configBinding = configBinding;
    if (!recordCrossFrame.empty()) {
      if (!recordCross) {
        errs() << "spinel-core-kernel: --record-cross-frame needs --record-cross\n";
        sys::fs::remove_directories(tmpdir);
        return 2;
      }
      char *end = nullptr;
      const long frame = std::strtol(recordCrossFrame.c_str(), &end, 10);
      if (recordCrossFrame.empty() || *end != 0 || frame < 0) {
        errs() << "spinel-core-kernel: --record-cross-frame takes a non-negative byte count, not '"
               << recordCrossFrame << "'\n";
        sys::fs::remove_directories(tmpdir);
        return 2;
      }
      rreq.recordCrossFrame = frame;
    }
    const auto rs =
        core::writeCoreReport(*prepared, admitted, rreq, runTool, tempPath, diag);
    sys::fs::remove_directories(tmpdir);
    if (rs != core::CoreEmitStatus::Ok) return exitFor(rs);
    outs() << "spinel-core-kernel: wrote " << reportPath << "\n";
    return 0;
  }
  sys::fs::remove_directories(tmpdir);
  return 0;
}
