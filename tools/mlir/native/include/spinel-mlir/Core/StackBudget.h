//===- StackBudget.h - frame sizes and the worst path, from one IR --*- C++ -*-===//
//
// Decision 0010's stack budget, step 2. Three inputs, all taken from the IR
// CODE GENERATION CONSUMED -- the file the two-step emission leaves behind --
// so that the call graph and the frame sizes cannot describe different
// programs:
//
//   frame sizes      a side compile of that IR with `warn-stack-size`=0 on
//                    every function, and clang's diagnostic parsed. The side
//                    compile uses THE SAME codegen line as the object, so the
//                    sizes are the object's sizes; only the attribute differs,
//                    and the attribute was measured not to change the object.
//   the call graph    read from the same IR, after optimisation and inlining,
//                    so an inlined call correctly has no frame.
//   call overhead     per target, and DATA rather than a literal: 8 bytes on
//                    x86-64 where the call pushes a return address no frame
//                    contains, 0 on arm64 where the callee saves the link
//                    register inside its own frame, which the reported size
//                    already counts. Measured 2026-09-20 from the prologues of
//                    the same fixture compiled for both.
//   unreserved call  Arm and Thumb (x86-64 below). When a function's largest
//   frames           outgoing argument area is 2047 bytes or more, codegen does not
//                    reserve call frames in its frame: it moves sp around
//                    each call, and the diagnostic does not count that.
//                    Measured 2026-10-21: 520 pointer arguments, reported
//                    24, `sub.w sp, sp, #2064` before the call. A second
//                    side compile prints the assembly with the same line;
//                    what a function moves sp by beyond its reported frame
//                    (StackBudget.cpp) is added to that frame. x86-64 too:
//                    X86CallFrameOptimization pushes a call's stack
//                    arguments, and the diagnostic does not count them.
//
// WHAT IT REFUSES TO GUESS. An indirect call has no callee to charge, a cycle
// has no longest path, and a dynamic alloca has no fixed frame at all. Each
// ends the analysis with a reason rather than a number -- measured on the
// tree of 2026-09-20, none of the three occurs in col, stepall or renderall,
// and that is a fact about today's entries rather than about the analysis.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_STACKBUDGET_H
#define SPINEL_MLIR_CORE_STACKBUDGET_H

#include "spinel-mlir/Core/Emit.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace spinel_mlir::core {

struct StackFunction {
  std::string name;
  uint64_t frameBytes = 0;
  /// False for a callee this IR only declares -- an extern, whose stack 0010
  /// takes from its overlay. Every DEFINITION has a size: clang's diagnostic
  /// tests `size > 0`, so a zero-byte frame is silent rather than absent, and
  /// StackBudget.cpp records the measurement that established this.
  bool frameKnown = false;
};

struct StackBudgetResult {
  /// True when kernelStack means something. False leaves `refusal` set.
  bool analysed = false;
  /// Why there is no number, in the report's words.
  std::string refusal;
  /// Set with `refusal` when the reason was a dynamic stack allocation.
  ///
  /// The three refusals are not interchangeable to a profile: 0010 says the
  /// `realtime` profile ADMITS no dynamic stack allocation, so this one is a
  /// verdict (`fail`) there rather than an absent measurement. A cycle or an
  /// indirect call is still only an absent measurement -- the profile has no
  /// admission rule about them in this row.
  bool dynamicStack = false;
  std::vector<StackFunction> functions;
  /// The path that produced kernelStack, entry first.
  std::vector<std::string> worstPath;
  uint64_t frameTotal = 0;    ///< sum of the frames on that path
  uint64_t callOverhead = 0;  ///< per call edge, for this target
  uint64_t kernelStack = 0;   ///< frameTotal + edges * callOverhead
  std::string target;         ///< the triple the overhead was chosen for
  std::string overheadEvidence;  ///< the measurement behind that number
  /// The frame the 4096-byte control was reported with on this run: the
  /// liveness of the diagnostic, which licenses reading an absence as zero.
  /// It is not the alloca (3968 on x86-64, the red zone taken off) and it is
  /// printed by spinel-core-stack, not written into the report.
  uint64_t canaryFrame = 0;
  /// Decision 0014: the declared callees on the paths whose frames came from
  /// bound evidence (an attestation), with those bytes.
  std::vector<StackFunction> attested;
  /// The call frames codegen did not reserve, which the frame-size diagnostic
  /// does not count (Arm and Thumb, StackBudget.cpp): per function the largest
  /// one, already added to that function's frame in `functions`.
  std::vector<StackFunction> unreserved;
  /// The call frame the method's own control reported on this run (Arm and
  /// Thumb only; 0 elsewhere), printed by spinel-core-stack like canaryFrame.
  uint64_t unreservedControl = 0;
};

/// Analyses `irPath` -- the IR the object was generated from -- and answers
/// the frame sizes, the worst path and kernel_stack. `clangPath`, `clangArgs`
/// and the runner are the ones that produced the object: the side compile must
/// be the object's codegen or the sizes are another program's.
StackBudgetResult deriveStackBudget(const std::string &irPath,
                                    const std::string &clangPath,
                                    const std::vector<std::string> &clangArgs,
                                    const std::string &target,
                                    RunToolFn runTool, TempPathFn tempPath,
                                    const std::map<std::string, uint64_t> &attested = {});

/// The two policy terms of 0010's inequality, supplied for the step 2 proof of
/// concept ALONE.
///
/// UNSELECTABLE FOR A REAL BUILD, by three mechanisms that each work without
/// the others:
///   1. they arrive only through `--fixture-stack-provision` and
///      `--fixture-interrupt-reserve`, whose names carry `fixture` at the
///      point of use, and which the kernel refuses outside `--profile
///      realtime`;
///   2. a report built with them records `"origin": "fixture"` on the
///      declaration evidence, so the artifact says so afterwards rather than
///      relying on anyone remembering;
///   3. nothing tracked passes them except the stack-budget lane, which greps
///      the tree for other users and fails if it finds one.
/// A real `provisioned_stack` comes from the target profile or the entry's
/// contract, per 0010, and a real `interrupt_reserve` carries the interrupt
/// nesting assumption it rests on. Neither exists yet; inventing one here
/// would be a policy number nobody decided, dressed as a check.
struct FixtureStackProfile {
  bool given = false;
  uint64_t provisionedStack = 0;
  uint64_t interruptReserve = 0;
};

/// What this property is, once the profile has been applied to the analysis.
///
/// ONE implementation, two callers: the report renders it as JSON and the
/// fixture tool prints it. The rendering stays in Report.cpp; what is shared
/// is the decision, which is what 0010's acceptance is about.
struct StackVerdict {
  /// True when the property was DECIDED -- either a kernel_stack was derived,
  /// or the profile's admission rule decided it without one.
  bool evaluated = false;
  /// "pass", "fail" or "unknown". Empty when `evaluated` is false.
  std::string verdict;
  std::string reason;
  /// True when the report should carry kernel_stack and the frame tables. A
  /// dynamic alloca refused by the profile has a verdict and deliberately no
  /// number: the frame it would have counted does not exist.
  bool hasNumbers = false;
};

StackVerdict decideStackBudget(const std::string &profile,
                               const StackBudgetResult &stack,
                               const FixtureStackProfile &fixture);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_STACKBUDGET_H
