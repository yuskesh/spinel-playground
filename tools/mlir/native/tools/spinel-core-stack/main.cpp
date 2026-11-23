//===- spinel-core-stack - the stack budget over one IR file --------------===//
//
// Decision 0010 step 2.  The analysis the report embeds, run over an IR file
// given on the command line and printed as plain text:
//
//   spinel-core-stack <ir> --clang <path> --profile <name>
//                     [--fixture-stack-provision <bytes>
//                      --fixture-interrupt-reserve <bytes>]
//                     [-- <clang args>]
//
// WHY IT EXISTS, and what it deliberately is not. 0010's proof of concept must
// show that a dynamic `alloca` is refused under `realtime`. The CORE scalar
// subset cannot produce one -- every Array, String and Hash form is rejected
// before code generation (lib/Core/SubsetRefusals.cpp) and a buffer parameter
// is an address the caller owns -- so that admission rule cannot be
// reached from any entry this compiler accepts, today. It is a guard for the
// IR shapes other lanes already emit (lib/Freestanding/GradShim.cpp builds a
// VLA alloca), and the only way to exercise it is to hand the analysis IR of
// that shape.
//
// It is NOT a second reporter. The report is written by writeCoreReport and
// rendered once, in Report.cpp. What this shares with it is `deriveStackBudget`
// and `decideStackBudget` -- the analysis and the decision, which are what the
// acceptance is about. This prints them; it writes no JSON and no object.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/Profile.h"
#include "spinel-mlir/Core/StackBudget.h"

#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <map>
#include <string>
#include <vector>

using namespace llvm;
using namespace spinel_mlir;

namespace {
void usage(const char *argv0) {
  errs() << "usage: " << argv0
         << " <ir> --clang <path> --profile hosted-stage2|realtime\n"
            "       [--fixture-stack-provision <bytes>"
            " --fixture-interrupt-reserve <bytes>]\n"
            "       [--attested <symbol>=<bytes>]...\n"
            "       [-- <clang args>]\n";
}
} // namespace

int main(int argc, char **argv) {
  std::string irPath, clangPath, profile, provision, reserve;
  // Decision 0014: the frame of a callee this IR only declares, as bound
  // evidence would supply it; the fixture form of what the kernel reads from
  // an evidence file.
  std::map<std::string, uint64_t> attested;
  std::vector<std::string> clangArgs;
  for (int i = 1; i < argc; ++i) {
    StringRef a = argv[i];
    auto next = [&](StringRef what) -> std::string {
      if (i + 1 >= argc) {
        errs() << "spinel-core-stack: " << what << " needs a value\n";
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--clang") clangPath = next("--clang");
    else if (a == "--profile") profile = next("--profile");
    else if (a == "--fixture-stack-provision")
      provision = next("--fixture-stack-provision");
    else if (a == "--fixture-interrupt-reserve")
      reserve = next("--fixture-interrupt-reserve");
    else if (a == "--attested") {
      const std::string v = next("--attested");
      const auto eq = v.find('=');
      uint64_t bytes = 0;
      if (eq == std::string::npos || StringRef(v).drop_front(eq + 1).getAsInteger(10, bytes)) {
        errs() << "spinel-core-stack: --attested takes <symbol>=<bytes>\n";
        return 2;
      }
      attested[v.substr(0, eq)] = bytes;
    }
    else if (a == "--") { for (++i; i < argc; ++i) clangArgs.push_back(argv[i]); }
    else if (a.starts_with("--")) {
      errs() << "spinel-core-stack: unknown option " << a << "\n";
      return 2;
    } else if (irPath.empty()) irPath = a.str();
    else { errs() << "spinel-core-stack: more than one IR file given\n"; return 2; }
  }
  if (irPath.empty() || clangPath.empty() || profile.empty()) {
    usage(argv[0]);
    return 2;
  }
  if (profile != core::kHostedStage2Profile && profile != core::kRealtimeProfile) {
    errs() << "spinel-core-stack: profile '" << profile
           << "' is not implemented; this build knows "
           << core::kHostedStage2Profile << " and " << core::kRealtimeProfile
           << "\n";
    return 2;
  }
  core::FixtureStackProfile fixture;
  if (!provision.empty() || !reserve.empty()) {
    if (provision.empty() || reserve.empty()) {
      errs() << "spinel-core-stack: the fixture provision and reserve are "
                "given together or not at all; the inequality needs both "
                "terms\n";
      return 2;
    }
    if (profile != core::kRealtimeProfile) {
      errs() << "spinel-core-stack: the fixture stack provision is accepted "
                "only with --profile " << core::kRealtimeProfile << "\n";
      return 2;
    }
    if (StringRef(provision).getAsInteger(10, fixture.provisionedStack) ||
        StringRef(reserve).getAsInteger(10, fixture.interruptReserve)) {
      errs() << "spinel-core-stack: the fixture provision and reserve are byte "
                "counts in decimal\n";
      return 2;
    }
    fixture.given = true;
  }

  SmallString<128> tmpdir;
  if (sys::fs::createUniqueDirectory("spinel-core-stack", tmpdir)) {
    errs() << "spinel-core-stack: cannot create a temporary directory\n";
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

  // The target the caller's clang line resolves to, asked for the same way the
  // report asks: a triple this tool guessed would pick a different overhead.
  std::string target;
  {
    const std::string out = tempPath("triple.out");
    std::vector<std::string> owned{clangPath};
    owned.insert(owned.end(), clangArgs.begin(), clangArgs.end());
    owned.push_back("-print-target-triple");
    std::vector<StringRef> args(owned.begin(), owned.end());
    if (runTool(clangPath, args, out, tempPath("triple.err")) != 0) {
      errs() << "spinel-core-stack: cannot ask " << clangPath
             << " for its target triple\n";
      sys::fs::remove_directories(tmpdir);
      return 3;
    }
    auto buf = MemoryBuffer::getFile(out);
    if (!buf) {
      errs() << "spinel-core-stack: cannot read " << out << "\n";
      sys::fs::remove_directories(tmpdir);
      return 3;
    }
    target = StringRef((*buf)->getBuffer()).split('\n').first.trim().str();
  }

  const core::StackBudgetResult stack = core::deriveStackBudget(
      irPath, clangPath, clangArgs, target, runTool, tempPath, attested);
  const core::StackVerdict v = core::decideStackBudget(profile, stack, fixture);
  sys::fs::remove_directories(tmpdir);

  outs() << "profile: " << profile << "\n";
  outs() << "target: " << target << "\n";
  outs() << "evaluated: " << (v.evaluated ? "true" : "false") << "\n";
  if (!v.verdict.empty()) outs() << "verdict: " << v.verdict << "\n";
  outs() << "reason: " << v.reason << "\n";
  if (v.hasNumbers) {
    outs() << "kernel_stack: " << stack.kernelStack << "\n";
    outs() << "frame_total: " << stack.frameTotal << "\n";
    outs() << "call_overhead: " << stack.callOverhead << "\n";
    outs() << "canary_frame: " << stack.canaryFrame << "\n";
    if (stack.unreservedControl != 0)
      outs() << "unreserved_control: " << stack.unreservedControl << "\n";
    for (const core::StackFunction &u : stack.unreserved)
      outs() << "unreserved " << u.name << " " << u.frameBytes << "\n";
    if (fixture.given) {
      outs() << "interrupt_reserve: " << fixture.interruptReserve << "\n";
      outs() << "provisioned_stack: " << fixture.provisionedStack << "\n";
    }
    outs() << "worst_path:";
    for (const std::string &fn : stack.worstPath) outs() << " " << fn;
    outs() << "\n";
    for (const core::StackFunction &f : stack.functions) {
      outs() << "frame " << f.name << " ";
      if (f.frameKnown) outs() << f.frameBytes << "\n";
      else outs() << "unknown\n";
    }
  }
  // A refused admission is a verdict, not a tool failure: the caller reads the
  // verdict. Only a tool that could not run at all exits non-zero.
  return v.evaluated || !stack.refusal.empty() ? 0 : 3;
}
