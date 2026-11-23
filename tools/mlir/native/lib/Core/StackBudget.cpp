//===- StackBudget.cpp - decision 0010's stack budget, from the emitted IR -===//
#include "spinel-mlir/Core/StackBudget.h"

#include "spinel-mlir/Core/Profile.h"

#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Regex.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <functional>
#include <map>
#include <set>

using namespace llvm;

namespace spinel_mlir::core {
namespace {

/// THE TARGET PROFILE'S per-call overhead, with the measurement that produced
/// it. Decision 0010 puts this in the target profile beside interrupt_reserve;
/// until that file exists this is where it lives, as data with its evidence
/// rather than as a literal in the arithmetic.
///
/// The number is what a call costs that NEITHER frame reports:
///   x86-64  the `call` pushes an 8-byte return address, and the reported
///           frame is the callee's own `sub` plus its saved registers.
///   arm64   the callee saves the link register INSIDE its frame -- measured
///           `sub sp, sp, #0x70 ; stp x29, x30, [sp, #0x60]` for a frame
///           reported as 112 -- so the call adds nothing the sizes miss.
struct TargetOverhead {
  const char *triplePrefix;
  uint64_t bytes;
  const char *evidence;
};
constexpr TargetOverhead kOverheads[] = {
    {"x86_64", 8,
     "the call pushes an 8-byte return address that no reported frame "
     "contains (prologues of the fixture, 2026-09-20)"},
    {"aarch64", 0,
     "the callee saves the link register inside its own frame, which the "
     "reported size already counts (prologues of the same fixture compiled "
     "for arm64, 2026-09-20)"},
    {"arm64", 0,
     "the callee saves the link register inside its own frame, which the "
     "reported size already counts (prologues of the same fixture compiled "
     "for arm64, 2026-09-20)"},
    // Thumb on Cortex-M33: `bl` writes the return address to lr, not to the
    // stack, and the callee pushes lr with its other saved registers:
    // `push.w {r4-r11, lr}` (36 bytes) then `sub sp, #100` for a frame the
    // diagnostic reported as 136 (sp_st_d2), and `push {r4-r7, lr}` (20) then
    // `sub sp, #4` for one reported as 24 (st_leaf).
    {"thumbv8m", 0,
     "bl writes no stack and the callee pushes the link register inside its "
     "own frame, which the reported size already counts (prologues of the "
     "same fixture compiled for thumbv8m.main-none-eabi, 2026-09-22)"},
    // Thumb on Cortex-M7 (decision 0023), the same convention: `push {r4, r5,
    // r7, lr}` (16) then `sub sp, #104` for a frame -fstack-usage reports as
    // 120 (sp_st_d2).
    {"thumbv7em", 0,
     "bl writes no stack and the callee pushes the link register inside its "
     "own frame, which the reported size already counts (prologues of the "
     "same fixture compiled for thumbv7em-none-eabi -mcpu=cortex-m7, "
     "2026-10-21)"},
};

const TargetOverhead *overheadFor(StringRef triple) {
  for (const TargetOverhead &o : kOverheads)
    if (triple.starts_with(o.triplePrefix)) return &o;
  return nullptr;
}

/// Every function's frame size, from clang's own diagnostic over the same IR.
///
/// The attribute goes on in memory and the module is written out again: text
/// editing of IR would be a second parser to keep correct.
/// The positive control, added to the SIDE COMPILE's module only.
///
/// The method reads an absence -- a function clang said nothing about has a
/// zero-byte frame -- and an absence is also what a broken method produces.
/// This function has a frame that cannot be zero, so its diagnostic proves the
/// measurement was live on THIS run, rather than on the run someone checked it
/// on once. It never reaches the object: the module it is added to is the
/// throwaway copy printed for the side compile.
/// The control's own frame is NOT expected to equal its alloca. MEASURED,
/// 2026-09-21, x86-64: a 4096-byte alloca is reported as 3968, which is 4096
/// less the 128-byte red zone. The control therefore asks only that the
/// diagnostic arrived and named a frame far larger than any this analysis
/// would otherwise see -- it is a liveness check, not a second measurement.
constexpr const char *kCanaryName = "__spinel_stack_budget_canary";
constexpr uint64_t kCanaryBytes = 4096;
constexpr uint64_t kCanaryFloor = 2048;

void addCanary(Module &m) {
  LLVMContext &ctx = m.getContext();
  FunctionType *ty = FunctionType::get(Type::getVoidTy(ctx), false);
  Function *f = Function::Create(ty, GlobalValue::ExternalLinkage, kCanaryName, m);
  f->addFnAttr("warn-stack-size", "0");
  BasicBlock *bb = BasicBlock::Create(ctx, "entry", f);
  IRBuilder<> b(bb);
  AllocaInst *buf = b.CreateAlloca(
      ArrayType::get(Type::getInt8Ty(ctx), kCanaryBytes), nullptr, "canary");
  // Written through, so no later pass can call the storage dead. The side
  // compile runs with the middle end disabled, but the method must not depend
  // on that to keep its own control alive.
  b.CreateStore(b.getInt8(0), buf);
  b.CreateRetVoid();
}

bool frameSizes(Module &m, const std::string &clangPath,
                const std::vector<std::string> &clangArgs, RunToolFn runTool,
                TempPathFn tempPath, std::map<std::string, uint64_t> &sizes,
                uint64_t &canaryFrame, std::string &refusal) {
  for (Function &f : m)
    if (!f.isDeclaration()) f.addFnAttr("warn-stack-size", "0");
  addCanary(m);

  const std::string irPath = tempPath("stack.warn.ll");
  {
    std::error_code ec;
    raw_fd_ostream os(irPath, ec);
    if (ec) {
      refusal = "cannot write " + irPath + " for the frame-size compile";
      return false;
    }
    m.print(os, nullptr);
  }

  // THE OBJECT'S OWN CODEGEN LINE, with the middle end disabled exactly as the
  // second step of the emission disables it. A different line would measure a
  // different program's frames.
  std::vector<std::string> owned = {clangPath, "-O2", "-Wno-override-module"};
  for (const std::string &a : clangArgs) owned.push_back(a);
  owned.push_back("-Xclang");
  owned.push_back("-disable-llvm-passes");
  owned.push_back("-c");
  owned.push_back(irPath);
  owned.push_back("-o");
  owned.push_back(tempPath("stack.warn.o"));
  std::vector<StringRef> argv(owned.begin(), owned.end());
  const std::string errPath = tempPath("stack.warn.err");
  if (runTool(clangPath, argv, "", errPath) != 0) {
    refusal = "the frame-size compile failed; its stderr is at " + errPath;
    return false;
  }
  auto text = MemoryBuffer::getFile(errPath);
  if (!text) {
    refusal = "cannot read " + errPath;
    return false;
  }

  // clang: "stack frame size (3976) exceeds limit (0) in function 'leaf'"
  Regex re("stack frame size \\(([0-9]+)\\) exceeds limit \\([0-9]+\\) in "
           "function '([^']+)'");
  SmallVector<StringRef, 4> got;
  SmallVector<StringRef, 32> lines;
  (*text)->getBuffer().split(lines, '\n');
  for (StringRef line : lines) {
    got.clear();
    if (!re.match(line, &got) || got.size() != 3) continue;
    uint64_t bytes = 0;
    if (got[1].getAsInteger(10, bytes)) continue;
    sizes[got[2].str()] = bytes;
  }
  // THE CONTROL IS READ FIRST, and it is what licenses reading an absence as a
  // zero. An entry whose functions all need no frame reports nothing at all,
  // and without the control that is indistinguishable from the diagnostic
  // having stopped arriving.
  auto canary = sizes.find(kCanaryName);
  if (canary == sizes.end() || canary->second < kCanaryFloor) {
    refusal =
        "the frame-size method did not report the control function, which "
        "allocates " +
        std::to_string(kCanaryBytes) +
        " bytes on the stack, so no absent diagnostic on this run can be read "
        "as a zero-byte frame; the side compile's stderr is at " + errPath;
    return false;
  }
  canaryFrame = canary->second;
  sizes.erase(canary);

  // A DEFINITION CLANG SAID NOTHING ABOUT HAS A ZERO-BYTE FRAME. The check
  // behind the diagnostic is `size > threshold`, and the threshold is 0, so a
  // function that needs no frame is silent -- indistinguishable, in the
  // diagnostic alone, from one that was never asked about.
  //
  // MEASURED, 2026-09-21, against method B (`.llvm_stack_sizes` from a side
  // compile of this same IR) on `renderall`: 48 functions, the same 48 names
  // in both; the 40 clang named match B exactly, and the 8 clang was silent
  // about are exactly the 8 B reports as 0. Without this the report shows them
  // as an absent measurement, which is a different and wrong claim.
  //
  // A DECLARATION IS NOT FILLED IN. An extern on the worst path has no frame
  // here by construction -- 0010 takes its stack from the overlay -- and
  // charging it zero would be a claim about someone else's code.
  for (Function &f : m)
    if (!f.isDeclaration() && f.getName() != kCanaryName)
      sizes.emplace(f.getName().str(), 0);
  return true;
}

/// THE CALL FRAMES ARM CODEGEN DID NOT RESERVE. When a function's largest
/// outgoing argument area is 2047 bytes or more, the Arm backend leaves call
/// frames out of the function's frame and moves sp around each call instead,
/// and the diagnostic frameSizes reads reports the frame without them.
/// MEASURED, 2026-10-21, thumbv8m.main: a call with 520 pointer arguments is
/// reported as 24 and made after `sub.w sp, sp, #2064`; with 500 it is
/// reserved and reported as 2000. On the DOOM entries this is 3504 bytes in
/// sp_doom_core_step, part of what the FRDM-IMXRT1186's scheduler thread
/// overflowed by. MEASURED, 2026-10-21, thumbv7em -mcpu=cortex-m7 (decision
/// 0023): the same -- 520 pointer arguments reported as 8 after `push {r7,
/// lr}` and `sub.w sp, sp, #2064`, 500 reserved and reported as 1992.
///
/// Read from the same module compiled to assembly with the same line (the
/// frame-size compile's codegen, printed rather than assembled), against the
/// frame sizes: a prologue is a run of sp decrements -- push, vpush, sub sp by
/// an immediate, with frame-pointer setup between them -- at the function's
/// start or beginning with a push (a shrink-wrapped prologue). What the
/// largest run moves sp by beyond the reported frame is a call frame the
/// prologue allocated with it; any other `sub sp, #N` is a call frame of N.
/// The larger of the two is added to the frame. A run smaller than the
/// reported frame, or sp moved by a register, is refused. Unwind tables would
/// mark the prologue with `.pad`, but they change code (measured the same
/// day: a noreturn function gains a `push {r7, lr}`), so they are not used.
constexpr const char *kCallControlName = "__spinel_stack_budget_call_control";
constexpr const char *kCallSinkName = "__spinel_stack_budget_call_sink";
// The control per target: Arm, a call whose area cannot be reserved; x86-64,
// a call whose six stack arguments are pushed.
constexpr unsigned kCallControlArgs = 600;
constexpr uint64_t kCallControlFloor = 2048;
constexpr unsigned kCallControlArgsX86 = 12;
constexpr uint64_t kCallControlFloorX86 = 16;

// 32-bit Arm only. "arm64" (Darwin's AArch64, and arm64_32) also starts with
// "arm", and its call frames are neither built nor printed this way: the Arm
// reader finds no `.type %function` in Mach-O assembly, so it refused every
// arm64 host build.
bool isArmTarget(StringRef triple) {
  return triple.starts_with("thumb") ||
         (triple.starts_with("arm") && !triple.starts_with("arm64"));
}

bool isX86Target(StringRef triple) { return triple.starts_with("x86_64"); }

/// The positive control: a call with 600 i32 arguments, whose area on Thumb
/// cannot be reserved. It goes in a module of its own, compiled with the same
/// line, so the entry's assembly is left as the entry's; it carries the
/// frame-size attribute so its reported frame comes with it. If the method
/// reports nothing for it, no silence about another function can be read as
/// "every call frame was reserved".
void addCallControl(Module &m, unsigned argc) {
  LLVMContext &ctx = m.getContext();
  Type *i32 = Type::getInt32Ty(ctx);
  std::vector<Type *> params(argc, i32);
  Function *sink = Function::Create(FunctionType::get(Type::getVoidTy(ctx), params, false),
                                    GlobalValue::ExternalLinkage, kCallSinkName, m);
  Function *f = Function::Create(FunctionType::get(Type::getVoidTy(ctx), false),
                                 GlobalValue::ExternalLinkage, kCallControlName, m);
  f->addFnAttr("warn-stack-size", "0");
  IRBuilder<> b(BasicBlock::Create(ctx, "entry", f));
  std::vector<Value *> args;
  for (unsigned i = 0; i < argc; ++i) args.push_back(b.getInt32(i));
  b.CreateCall(sink, args);
  b.CreateRetVoid();
}

/// `m` written out and compiled to assembly with the object's codegen line;
/// answers the assembly, or an empty buffer with `refusal` set.
std::unique_ptr<MemoryBuffer> compileToAsm(Module &m, const std::string &name,
                                           const std::string &clangPath,
                                           const std::vector<std::string> &clangArgs,
                                           RunToolFn runTool, TempPathFn tempPath,
                                           std::string &asmPath, std::string &refusal) {
  const std::string irPath = tempPath(name + ".ll");
  {
    std::error_code ec;
    raw_fd_ostream os(irPath, ec);
    if (ec) {
      refusal = "cannot write " + irPath + " for the call-frame compile";
      return nullptr;
    }
    m.print(os, nullptr);
  }
  asmPath = tempPath(name + ".s");
  std::vector<std::string> owned = {clangPath, "-O2", "-Wno-override-module"};
  for (const std::string &a : clangArgs) owned.push_back(a);
  owned.push_back("-Xclang");
  owned.push_back("-disable-llvm-passes");
  owned.push_back("-S");
  owned.push_back(irPath);
  owned.push_back("-o");
  owned.push_back(asmPath);
  std::vector<StringRef> argv(owned.begin(), owned.end());
  const std::string errPath = tempPath(name + ".err");
  if (runTool(clangPath, argv, "", errPath) != 0) {
    refusal = "the call-frame compile failed; its stderr is at " + errPath;
    return nullptr;
  }
  auto text = MemoryBuffer::getFile(asmPath);
  if (!text) {
    refusal = "cannot read " + asmPath;
    return nullptr;
  }
  return std::move(*text);
}

/// The bytes a register list pushes: `{r4, r5, lr}`, `{d8-d15}`.
uint64_t reglistBytes(StringRef ops) {
  size_t a = ops.find('{'), z = ops.find('}');
  if (a == StringRef::npos || z == StringRef::npos) return 0;
  SmallVector<StringRef, 16> regs;
  ops.slice(a + 1, z).split(regs, ',');
  uint64_t bytes = 0;
  for (StringRef r : regs) {
    r = r.trim();
    auto [lo, hi] = r.split('-');
    uint64_t n = 1;
    if (!hi.empty()) {
      unsigned x = 0, y = 0;
      lo.drop_front().getAsInteger(10, x);
      hi.trim().drop_front().getAsInteger(10, y);
      n = y >= x ? y - x + 1 : 1;
    }
    bytes += n * (lo.starts_with("d") ? 8 : 4);
  }
  return bytes;
}

/// Per function, what its code moves sp by that its reported frame lacks.
bool parseUnreserved(StringRef text, const std::string &asmPath,
                     const std::map<std::string, uint64_t> &frames,
                     std::map<std::string, uint64_t> &extra,
                     std::string &refusal) {
  Regex type("^[ \t]*\\.type[ \t]+([^,]+),[ \t]*%function");
  Regex label("^([A-Za-z_.$][A-Za-z0-9_.$]*):");
  Regex insn("^[ \t]+([a-z][a-z0-9.]*)[ \t]*(.*)$");
  Regex subImm("^sp,[ \t]*(sp,[ \t]*)?#([0-9]+)$");
  Regex subReg("^sp,[ \t]*(sp,[ \t]*)?(r[0-9]+|ip|lr)");
  Regex strPush("\\[sp, #-([0-9]+)\\]!$");
  Regex fpSetup("^r[0-9]+,[ \t]*sp([, ]|$)");
  std::set<std::string> functions;
  struct Fn {
    uint64_t largestRun = 0, run = 0, later = 0;
    bool open = false, first = true;
  };
  std::map<std::string, Fn> seen;
  Fn *cur = nullptr;
  std::string curName;
  SmallVector<StringRef, 64> lines;
  text.split(lines, '\n');
  SmallVector<StringRef, 4> got;
  auto close = [&] {
    if (cur && cur->open) cur->largestRun = std::max(cur->largestRun, cur->run);
    if (cur) { cur->open = false; cur->run = 0; }
  };
  for (StringRef line : lines) {
    got.clear();
    if (type.match(line, &got)) {
      functions.insert(got[1].trim().str());
      continue;
    }
    if (label.match(line, &got)) {
      if (functions.count(got[1].str())) {
        close();
        curName = got[1].str();
        cur = &seen[curName];
      }
      continue;
    }
    if (!cur || line.ltrim().starts_with(".") || !insn.match(line, &got)) continue;
    StringRef op = got[1], ops = got[2].trim();
    const bool isSub = op == "sub" || op == "sub.w" || op == "subw";
    uint64_t push = 0, sub = 0;
    if (op == "push" || op == "push.w" || op == "vpush")
      push = reglistBytes(ops);
    else if ((op == "str" || op == "str.w") && strPush.match(ops, &got))
      got[1].getAsInteger(10, push);
    SmallVector<StringRef, 4> s;
    if (isSub && subReg.match(ops)) {
      refusal = "function '" + curName + "' moves sp by a register (" +
                op.str() + " " + ops.str() + "), so its call frame has no size "
                "here; the assembly is at " + asmPath;
      return false;
    }
    if (isSub && subImm.match(ops, &s)) s[2].getAsInteger(10, sub);
    if (push && (cur->open || !cur->run)) {
      cur->open = true;
      cur->run += push;
    } else if (sub && (cur->open || cur->first)) {
      cur->open = true;
      cur->run += sub;
    } else if (sub) {
      cur->later = std::max(cur->later, sub);
    } else if (!(cur->open && (op == "add" || op == "add.w" || op == "mov") &&
                 fpSetup.match(ops))) {
      close();
    }
    cur->first = false;
  }
  close();
  for (const auto &kv : seen) {
    auto f = frames.find(kv.first);
    if (f == frames.end()) continue;
    const uint64_t prologue = kv.second.largestRun;
    if (prologue < f->second) {
      refusal = "function '" + kv.first + "' moves sp by " +
                std::to_string(prologue) + " in its prologue, less than its "
                "reported frame " + std::to_string(f->second) +
                ", so the frame is not read here; the assembly is at " + asmPath;
      return false;
    }
    const uint64_t more = std::max(prologue - f->second, kv.second.later);
    if (more) extra[kv.first] = more;
  }
  return true;
}

/// x86-64: the call frames X86CallFrameOptimization builds with pushes. It
/// turns the stores of a call's stack arguments into `push`es just before the
/// call, and the frame-size diagnostic does not count them. MEASURED,
/// 2026-10-21: a call with 8 pointer arguments is reported as 8 (the
/// alignment `pushq %rax`) and made after two more pushes (16 bytes); the
/// host DOOM objects push up to 3480 bytes before one call.
///
/// Read from the same assembly as on Arm, against the reported frames. The
/// prologue is the function's first sp decrements (push, `subq $N, %rsp`,
/// with `movq %rsp, %rbp` between them) up to the reported frame, wherever
/// they start (a shrink-wrapped prologue starts after an early exit). After
/// it, pushes and `subq` on %rsp before a call, net of `addq` and `pop`, are
/// that call's frame; the largest is added to the function's frame. A
/// prologue that does not add up to the reported frame, or %rsp written in
/// any other way than these and a restore (`movq`/`leaq` into it), is refused.
bool parseUnreservedX86(StringRef text, const std::string &asmPath,
                        const std::map<std::string, uint64_t> &frames,
                        std::map<std::string, uint64_t> &extra,
                        std::string &refusal) {
  Regex type("^[ \t]*\\.type[ \t]+([^,]+),[ \t]*@function");
  Regex label("^([A-Za-z_.$][A-Za-z0-9_.$@]*):");
  Regex insn("^[ \t]+([a-z][a-z0-9]*)[ \t]*([^#]*)");
  Regex imm("^\\$(-?[0-9]+),[ \t]*%rsp$");
  std::set<std::string> functions;
  std::string cur;
  uint64_t frame = 0, prologue = 0, depth = 0, deepest = 0;
  bool inPrologue = false, prologueDone = false;
  auto finish = [&]() -> bool {
    if (cur.empty()) return true;
    if (!prologueDone && prologue != frame && frames.count(cur)) {
      refusal = "function '" + cur + "' moves sp by " + std::to_string(prologue) +
                " before its first call or return, not its reported frame " +
                std::to_string(frame) + "; the assembly is at " + asmPath;
      return false;
    }
    if (deepest && frames.count(cur)) extra[cur] = deepest;
    return true;
  };
  SmallVector<StringRef, 64> lines;
  text.split(lines, '\n');
  SmallVector<StringRef, 4> got;
  for (StringRef line : lines) {
    got.clear();
    if (type.match(line, &got)) {
      functions.insert(got[1].trim().str());
      continue;
    }
    if (label.match(line, &got)) {
      if (functions.count(got[1].str())) {
        if (!finish()) return false;
        cur = got[1].str();
        auto f = frames.find(cur);
        frame = f == frames.end() ? 0 : f->second;
        prologue = depth = deepest = 0;
        inPrologue = false;
        prologueDone = frame == 0;
      } else if (prologueDone) {
        depth = 0;  // a call frame never spans a block
      }
      continue;
    }
    if (cur.empty() || line.ltrim().starts_with(".") || !insn.match(line, &got))
      continue;
    StringRef op = got[1], ops = got[2].trim();
    uint64_t down = 0, up = 0;
    SmallVector<StringRef, 4> m;
    if (op == "pushq") down = 8;
    else if (op == "popq") up = 8;
    else if (op == "subq" && imm.match(ops, &m)) m[1].getAsInteger(10, down);
    else if (op == "addq" && imm.match(ops, &m)) m[1].getAsInteger(10, up);
    else if (ops.ends_with("%rsp") && (op == "movq" || op == "leaq")) {
      if (prologueDone) depth = 0;  // a restore: the epilogue's
      continue;
    } else if (ops.ends_with("%rsp")) {
      refusal = "function '" + cur + "' writes %rsp with `" + op.str() + " " +
                ops.str() + "`, which has no call-frame reading here; the "
                "assembly is at " + asmPath;
      return false;
    }
    if (!prologueDone) {
      if (down && prologue + down <= frame) {
        inPrologue = true;
        prologue += down;
        if (prologue == frame) prologueDone = true;
        continue;
      }
      if (inPrologue && op == "movq" && ops == "%rsp, %rbp") continue;
      if (up || inPrologue || op.starts_with("call")) {
        refusal = "function '" + cur + "' moves sp by " +
                  std::to_string(prologue) + " in its prologue, not its "
                  "reported frame " + std::to_string(frame) +
                  "; the assembly is at " + asmPath;
        return false;
      }
      continue;  // before a shrink-wrapped prologue: no sp moves
    }
    if (down) depth += down;
    if (up) depth = up > depth ? 0 : depth - up;
    if (op.starts_with("call")) deepest = std::max(deepest, depth);
  }
  return finish();
}

/// `m` is the frame-size module (the canary in it) and `sizes` its reported
/// frames: compiled to assembly with the object's line and read against them;
/// then the control, in a module of its own.
bool unreservedCallFrames(Module &m, bool x86,
                          const std::map<std::string, uint64_t> &sizes,
                          const std::string &clangPath,
                          const std::vector<std::string> &clangArgs,
                          RunToolFn runTool, TempPathFn tempPath,
                          std::map<std::string, uint64_t> &extra,
                          uint64_t &control, std::string &refusal) {
  std::string asmPath, controlPath;
  auto text = compileToAsm(m, "stack.calls", clangPath, clangArgs, runTool,
                           tempPath, asmPath, refusal);
  if (!text) return false;
  auto parse = x86 ? parseUnreservedX86 : parseUnreserved;
  const unsigned argc = x86 ? kCallControlArgsX86 : kCallControlArgs;
  const uint64_t floor = x86 ? kCallControlFloorX86 : kCallControlFloor;
  if (!parse(text->getBuffer(), asmPath, sizes, extra, refusal))
    return false;

  LLVMContext ctx;
  Module cm("stack.control", ctx);
  cm.setTargetTriple(m.getTargetTriple());
  cm.setDataLayout(m.getDataLayout());
  addCallControl(cm, argc);
  auto ctl = compileToAsm(cm, "stack.control", clangPath, clangArgs, runTool,
                          tempPath, controlPath, refusal);
  if (!ctl) return false;
  // the control's reported frame, from the diagnostic its compile printed
  std::map<std::string, uint64_t> ctlFrames;
  if (auto err = MemoryBuffer::getFile(tempPath("stack.control.err"))) {
    Regex re("stack frame size \\(([0-9]+)\\) exceeds limit \\([0-9]+\\) in "
             "function '([^']+)'");
    SmallVector<StringRef, 32> errLines;
    (*err)->getBuffer().split(errLines, '\n');
    for (StringRef l : errLines) {
      SmallVector<StringRef, 4> g;
      uint64_t b = 0;
      if (re.match(l, &g) && !g[1].getAsInteger(10, b)) ctlFrames[g[2].str()] = b;
    }
  }
  ctlFrames.emplace(kCallControlName, 0);
  std::map<std::string, uint64_t> got;
  if (!parse(ctl->getBuffer(), controlPath, ctlFrames, got, refusal))
    return false;
  auto c = got.find(kCallControlName);
  if (c == got.end() || c->second < floor) {
    refusal = "the call-frame method did not report its control, a call with " +
              std::to_string(argc) +
              " arguments, so no function without an unreserved call frame "
              "can be read as having none; the assembly is at " + controlPath;
    return false;
  }
  control = c->second;
  return true;
}

} // namespace

StackBudgetResult deriveStackBudget(const std::string &irPath,
                                    const std::string &clangPath,
                                    const std::vector<std::string> &clangArgs,
                                    const std::string &target,
                                    RunToolFn runTool, TempPathFn tempPath,
                                    const std::map<std::string, uint64_t> &attested) {
  StackBudgetResult r;
  r.target = target;

  LLVMContext ctx;
  SMDiagnostic err;
  std::unique_ptr<Module> m = parseIRFile(irPath, err, ctx);
  if (!m) {
    r.refusal = "cannot read the emitted IR at " + irPath;
    return r;
  }

  // The call graph, and the three shapes that have no answer rather than a
  // large one.
  std::map<std::string, std::set<std::string>> edges;
  for (Function &f : *m) {
    if (f.isDeclaration()) continue;
    edges[f.getName().str()];
    for (BasicBlock &bb : f) {
      for (Instruction &i : bb) {
        if (auto *a = dyn_cast<AllocaInst>(&i)) {
          if (!a->isStaticAlloca()) {
            r.dynamicStack = true;
            r.refusal = "function '" + f.getName().str() +
                        "' allocates on the stack dynamically, so it has no "
                        "fixed frame";
            return r;
          }
          continue;
        }
        auto *call = dyn_cast<CallBase>(&i);
        if (!call) continue;
        if (isa<IntrinsicInst>(call)) continue;  // lowered, not called
        Function *callee = call->getCalledFunction();
        if (!callee) {
          r.refusal = "function '" + f.getName().str() +
                      "' makes an indirect call, which has no callee to charge "
                      "a frame to";
          return r;
        }
        if (callee->isIntrinsic()) continue;
        edges[f.getName().str()].insert(callee->getName().str());
      }
    }
  }

  std::map<std::string, uint64_t> sizes;
  if (!frameSizes(*m, clangPath, clangArgs, runTool, tempPath, sizes,
                  r.canaryFrame, r.refusal))
    return r;
  if (isArmTarget(target) || isX86Target(target)) {
    std::map<std::string, uint64_t> extra;
    if (!unreservedCallFrames(*m, isX86Target(target), sizes, clangPath, clangArgs, runTool, tempPath, extra,
                              r.unreservedControl, r.refusal))
      return r;
    for (const auto &kv : extra) {
      auto it = sizes.find(kv.first);
      if (it == sizes.end()) continue;  // not a definition of the entry's IR
      it->second += kv.second;
      r.unreserved.push_back({kv.first, kv.second, true});
    }
  }
  for (const auto &kv : sizes)
    r.functions.push_back({kv.first, kv.second, true});
  for (const auto &kv : edges)
    if (!sizes.count(kv.first)) r.functions.push_back({kv.first, 0, false});
  std::sort(r.functions.begin(), r.functions.end(),
            [](const StackFunction &a, const StackFunction &b) {
              return a.name < b.name;
            });

  const TargetOverhead *over = overheadFor(target);
  if (!over) {
    r.refusal = "no per-call stack overhead is recorded for target '" + target +
                "'; it is a property of the target and this report will not "
                "guess it";
    return r;
  }
  r.callOverhead = over->bytes;
  r.overheadEvidence = over->evidence;

  // The worst path, by depth-first search with the cycle check in the same
  // walk: a function on the stack twice is a cycle, and a cycle has no
  // longest path.
  std::map<std::string, std::pair<uint64_t, std::vector<std::string>>> best;
  std::set<std::string> onStack;
  std::string cycleAt;
  std::function<std::pair<uint64_t, std::vector<std::string>>(const std::string &)>
      walk = [&](const std::string &fn)
      -> std::pair<uint64_t, std::vector<std::string>> {
    if (!cycleAt.empty()) return {0, {}};
    auto known = best.find(fn);
    if (known != best.end()) return known->second;
    if (!onStack.insert(fn).second) {
      cycleAt = fn;
      return {0, {}};
    }
    auto it = sizes.find(fn);
    uint64_t own = it == sizes.end() ? 0 : it->second;
    // DECISION 0014: a callee this IR only declares is an extern. Its stack is
    // not measured here -- libgcc and the providers are not this compiler's --
    // so it comes from bound evidence, or the path has no answer. Charging a
    // declaration nothing, which is what an absent frame size would do, would
    // be a measurement of the wrong program.
    if (!edges.count(fn)) {
      auto a = attested.find(fn);
      if (a == attested.end()) {
        r.refusal = "function '" + fn + "' is only declared in this IR and has no "
                    "bound stack evidence, so the path through it has no answer";
        cycleAt = fn;  // unwinds the walk, like a cycle would
        return {0, {}};
      }
      own = a->second;
      r.attested.push_back({fn, own, true});
    }
    uint64_t deepest = 0;
    std::vector<std::string> deepestPath;
    auto e = edges.find(fn);
    if (e != edges.end()) {
      for (const std::string &callee : e->second) {
        auto sub = walk(callee);
        if (!cycleAt.empty()) return {0, {}};
        const uint64_t cost = sub.first + r.callOverhead;
        if (cost > deepest) {
          deepest = cost;
          deepestPath = sub.second;
        }
      }
    }
    onStack.erase(fn);
    std::vector<std::string> path{fn};
    path.insert(path.end(), deepestPath.begin(), deepestPath.end());
    auto answer = std::make_pair(own + deepest, path);
    best[fn] = answer;
    return answer;
  };

  // Every function is a candidate root: the entry is one of them, and a helper
  // nothing calls would otherwise be unreported.
  uint64_t worst = 0;
  std::vector<std::string> worstPath;
  bool haveWorst = false;
  for (const auto &kv : edges) {
    auto got = walk(kv.first);
    if (!cycleAt.empty()) {
      if (r.refusal.empty())
        r.refusal = "the call graph has a cycle through '" + cycleAt +
                    "', so there is no longest path to report";
      return r;
    }
    // `>` alone would leave an all-zero entry with an EMPTY path and a zero
    // total, which reads as "nothing was analysed" rather than "nothing needs
    // a frame". The first candidate always wins so the path names a function.
    if (!haveWorst || got.first > worst) {
      haveWorst = true;
      worst = got.first;
      worstPath = got.second;
    }
  }

  uint64_t frameTotal = 0;
  for (const std::string &fn : worstPath) {
    auto it = sizes.find(fn);
    if (it == sizes.end()) {
      // Every definition has a size by now, so this is a callee the IR only
      // declares: an extern, whose stack is the overlay's to state -- and
      // decision 0014 states it as bound evidence, which the walk took.
      auto a = attested.find(fn);
      if (a == attested.end()) {
        r.refusal = "'" + fn +
                    "' is on the worst path and is only declared here, so its "
                    "frame is not this artifact's to measure; 0010 takes an "
                    "extern's stack from its overlay";
        return r;
      }
      frameTotal += a->second;
      continue;
    }
    frameTotal += it->second;
  }
  r.worstPath = worstPath;
  r.frameTotal = frameTotal;
  r.kernelStack = worst;
  r.analysed = true;
  return r;
}

StackVerdict decideStackBudget(const std::string &profile,
                               const StackBudgetResult &stack,
                               const FixtureStackProfile &fixture) {
  StackVerdict v;

  // 0010: the `realtime` profile ADMITS no dynamic stack allocation, and an
  // entry that needs one gets verdict `fail`. That is an admission rule, not
  // an arithmetic: it needs neither provisioned_stack nor interrupt_reserve,
  // which is why it is the one part of `realtime` this build can make real.
  // `hosted-stage2` has no admission rule in this row, so the same IR there is
  // simply a frame size that does not exist.
  if (!stack.analysed && stack.dynamicStack && profile == kRealtimeProfile) {
    v.evaluated = true;
    v.verdict = "fail";
    v.reason = "profile '" + profile + "' admits no dynamic stack allocation: " +
               stack.refusal;
    return v;
  }
  if (!stack.analysed) {
    v.reason = stack.refusal.empty() ? "the emitted IR was not available"
                                     : stack.refusal;
    return v;
  }

  v.evaluated = true;
  v.hasNumbers = true;
  if (!fixture.given) {
    v.verdict = "unknown";
    v.reason = "profile '" + profile +
               "' declares no provisioned_stack and no interrupt_reserve, so "
               "the inequality has no right-hand side";
    return v;
  }
  const uint64_t need = stack.kernelStack + fixture.interruptReserve;
  if (need <= fixture.provisionedStack) {
    v.verdict = "pass";
    v.reason = "kernel_stack + interrupt_reserve = " + std::to_string(need) +
               " <= provisioned_stack " +
               std::to_string(fixture.provisionedStack);
  } else {
    v.verdict = "fail";
    v.reason = "kernel_stack + interrupt_reserve = " + std::to_string(need) +
               " exceeds provisioned_stack " +
               std::to_string(fixture.provisionedStack) + " by " +
               std::to_string(need - fixture.provisionedStack) + " bytes";
  }
  return v;
}

} // namespace spinel_mlir::core
