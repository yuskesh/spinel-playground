//===- SpinelGCRoots.cpp - GC shadow-stack root elision / batching --------===//
//
// E015 (P001 Phase 2 candidate #2).  An out-of-tree NewPM plugin that removes
// or batches the SP_GC_ROOT shadow-stack traffic Spinel's codegen emits.
//
// WHERE IT RUNS.  PipelineStartEP of clang's (ThinLTO pre-link) -O2 pipeline,
// i.e. before mem2reg/SROA.  Two reasons:
//   1. `SP_GC_ROOT(v)` is still a recognisable `call @_sp_gc_root_push(ptr %v)`
//      there.  After -O2 the macro has been inlined, control-flow-split by the
//      SP_GC_STACK_MAX bounds check and CSE'd across roots; the protocol is no
//      longer a pattern.
//   2. Taking `&v` for the root is what makes the alloca escape.  Deleting the
//      push BEFORE SROA lets the local be promoted to a register, which is
//      where most of the win is (see E015 Stage 1: the ceiling is far above the
//      profiler's push/pop self time).
//
// WHAT IT PROVES (see results/E015/safety_analysis.md for the full argument):
//   R1 "inert region" elision -- a push/pop pair is deleted when no function
//   that can reach a collection is called anywhere in the window
//     reachable-from(push)  INTERSECT  can-reach(any use of the rooted value).
//   Uses are closed transitively over the users of every load of the slot, so
//   a value handed to a callee counts as live at that call.
//
//   E017 revised R1 in two ways.  (a) The GEN closure now gives up on any use
//   it cannot follow -- a store of the VALUE into memory, a ptrtoint, or any
//   other instruction whose result carries the address -- instead of silently
//   ending the live range there (E016 §4c).  When the store's destination is a
//   non-escaping alloca, that alloca is JOINED into the live range instead
//   (-spinel-gc-alias-join, on by default).  (b) A parameter's entry-block root
//   is PINNED while R3 is on, because R3's exemption is a contract with the
//   callee and eliding the callee's own parameter root breaks it.
//   See results/E017/{r1_fix.md,r3_param_pin.md}.
//
//   R2 batching -- a run of surviving pushes with no call of any kind between
//   them becomes one `sp_gc_nroots` load, N slot stores and one store back.
//   The slot stores are emitted BEFORE the counter store, so no observer can
//   ever see a counter that covers an unwritten slot.  A capacity guard keeps
//   the SP_GC_STACK_MAX overflow behaviour exact by falling back to the
//   original per-root calls.
//
// The may-GC set is conservative: seeds are the allocators/collectors, any
// function containing an indirect call is may-GC, and any function without a
// body in this TU is may-GC unless it appears in the whole-program NOGC list
// supplied by -spinel-nogc-list= (computed offline from the llvm-link'ed
// module) or is recognised as libc/libm/intrinsic.
//
//===----------------------------------------------------------------------===//

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Plugins/PassPlugin.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Regex.h"
#include "llvm/Support/raw_ostream.h"

#include <deque>

using namespace llvm;

#define DEBUG_TYPE "spinel-gc-roots"

static cl::opt<std::string> NoGCListFile(
    "spinel-nogc-list", cl::desc("file of whole-program-proven NOGC symbols"),
    cl::value_desc("path"), cl::init(""));
static cl::opt<bool> DoElide("spinel-gc-elide", cl::init(true),
                             cl::desc("elide roots over inert regions"));
static cl::opt<bool> DoBatch("spinel-gc-batch", cl::init(true),
                             cl::desc("batch adjacent surviving pushes"));
static cl::opt<bool> Report("spinel-gc-report", cl::init(false),
                            cl::desc("print statistics to stderr"));
static cl::opt<bool> UseCalleeRoots(
    "spinel-gc-callee-roots", cl::init(true),
    cl::desc("treat a callee that roots its own parameter as covering it"));
// Debug knobs (hidden): apply only the elisions / batches whose module-wide
// index falls in [lo, hi].  Used to bisect which SITE breaks a program -- E017
// found the R3 composition hole with these (bm_spectral_norm needs BOTH
// elision #0 and #1 gone to break, so no single-site search would have found
// it).  NOT for production: a partial application has no soundness argument.
static cl::opt<int> ElideLo("spinel-gc-elide-lo", cl::init(0), cl::Hidden,
                            cl::desc("first elision index to apply"));
static cl::opt<int> ElideHi("spinel-gc-elide-hi", cl::init(1 << 30), cl::Hidden,
                            cl::desc("last elision index to apply"));
static cl::opt<int> BatchLo("spinel-gc-batch-lo", cl::init(0), cl::Hidden,
                            cl::desc("first batch index to apply"));
static cl::opt<int> BatchHi("spinel-gc-batch-hi", cl::init(1 << 30), cl::Hidden,
                            cl::desc("last batch index to apply"));
static cl::opt<bool> AliasJoin(
    "spinel-gc-alias-join", cl::init(true),
    cl::desc("when the rooted value is stored into a non-escaping alloca, join "
             "that alloca's live range instead of giving up on the root"));

namespace {

// SP_GC_STACK_MAX from vendor/spinel/lib/sp_gc.h.
static const int64_t kGCStackMax = 65536;

static const char *kPushFn = "_sp_gc_root_push";
static const char *kPopFn = "_sp_gc_root_pop";

// Functions that actually run (or can immediately run) a collection.
static const char *kSeeds[] = {
    "sp_gc_alloc",        "sp_gc_alloc_nogc",       "sp_str_alloc",
    "sp_gc_collect",      "sp_gc_collect_retune",   "sp_gc_collect_retune_all",
    "sp_gc_collect_request", "sp_str_collect_retune", "sp_stw_collect",
    "sp_safepoint",       "sp_gc_mark_all",
};

struct Stats {
  unsigned pushSeen = 0, elided = 0, batched = 0, batches = 0;
  unsigned bailEscape = 0, bailShape = 0, bailMayGC = 0, bailValEsc = 0;
  unsigned bailParamRoot = 0;
  unsigned aliasJoined = 0;
  unsigned framesSeen = 0, framesElided = 0, bailFrameShape = 0;
};

class RootOpt {
public:
  RootOpt(Module &M) : M(M) {}
  bool run(Stats &S);

private:
  Module &M;
  DenseSet<const Function *> MayGC;
  StringSet<> NoGCNames;

  void loadNoGCList();
  bool externIsSafe(StringRef N) const;
  void computeMayGC();
  bool isMayGCCall(const Instruction *I) const;
  bool calleeRootsParam(const Function *F, unsigned ArgNo);
  DenseMap<std::pair<const Function *, unsigned>, bool> RootsParamCache;
  int BatchIndex = 0; // module-wide batch counter, for the bisection knobs
  int ElideIndex = 0; // module-wide elision counter, ditto

  bool slotWindowInert(Function &F, AllocaInst *Slot, Instruction *Start,
                       Stats &S);
  bool runOnFunction(Function &F, Stats &S);
  bool elideFrames(Function &F, Stats &S);
  bool batchFunction(Function &F, Stats &S);
};

//===--------------------------------------------------------------------===//
// may-GC set
//===--------------------------------------------------------------------===//

void RootOpt::loadNoGCList() {
  if (NoGCListFile.empty())
    return;
  auto Buf = MemoryBuffer::getFile(NoGCListFile);
  if (!Buf) {
    errs() << "spinel-gc-roots: cannot read " << NoGCListFile << "\n";
    return;
  }
  SmallVector<StringRef, 2048> Lines;
  (*Buf)->getBuffer().split(Lines, '\n');
  for (StringRef L : Lines) {
    L = L.trim();
    if (!L.empty() && L[0] != '#')
      NoGCNames.insert(L);
  }
}

bool RootOpt::externIsSafe(StringRef N) const {
  if (N.starts_with("llvm."))
    return true;
  if (NoGCNames.count(N))
    return true;
  // Mach-O asm labels keep a leading \01_ or _.
  StringRef S = N;
  S.consume_front("\01");
  S.consume_front("_");
  if (NoGCNames.count(S))
    return true;
  static Regex LibC(
      "^(malloc|calloc|realloc|free|memcpy|memmove|memset|memcmp|bcmp|"
      "strlen|strcmp|strncmp|strcpy|strncpy|strstr|strchr|strrchr|"
      "strtol|strtoll|strtod|snprintf|sprintf|vsnprintf|printf|fprintf|"
      "fputs|fputc|putc|fwrite|fread|fopen|fclose|fflush|fgets|puts|putchar|"
      "getchar|exit|abort|getenv|setenv|time|clock|clock_gettime|gettimeofday|"
      "qsort|bsearch|abs|labs|llabs|atoi|atol|atof|"
      "sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|exp|exp2|log|log2|"
      "log10|pow|sqrt|cbrt|hypot|floor|ceil|round|trunc|fmod|fabs|frexp|"
      "ldexp|modf|copysign|erf|erfc|lgamma|tgamma)$");
  return LibC.match(S);
}

// `MayGC` here means may-collect-AND-return.  A callee that can only collect
// on a path that never comes back (every `raise` in spinel: sp_raise_cls
// allocates the exception, then longjmps) cannot invalidate a value the CALLER
// uses afterwards, because the caller has no afterwards on that path.  This is
// what separates `sp_imod` -- whose only reachable allocation is the
// ZeroDivisionError arm ending in `unreachable` -- from `sp_Vec_new`.
// See safety_analysis.md; the caller-side setjmp guard is in runOnFunction.

// blocks of F from which a `ret` is reachable
static void computeCanReturn(const Function &F,
                             DenseSet<const BasicBlock *> &Out) {
  std::deque<const BasicBlock *> Q;
  for (const BasicBlock &BB : F)
    if (isa<ReturnInst>(BB.getTerminator()))
      if (Out.insert(&BB).second)
        Q.push_back(&BB);
  while (!Q.empty()) {
    const BasicBlock *B = Q.front();
    Q.pop_front();
    for (const BasicBlock *P : predecessors(B))
      if (Out.insert(P).second)
        Q.push_back(P);
  }
}

void RootOpt::computeMayGC() {
  loadNoGCList();

  StringSet<> Seeds;
  for (const char *S : kSeeds)
    Seeds.insert(S);

  DenseMap<const Function *, DenseSet<const BasicBlock *>> CanRet;
  for (Function &F : M)
    if (!F.isDeclaration())
      computeCanReturn(F, CanRet[&F]);

  for (Function &F : M) {
    StringRef N = F.getName();
    StringRef S = N;
    S.consume_front("\01");
    S.consume_front("_");
    if (F.doesNotReturn())
      continue; // cannot hand control back: nothing after it to protect
    if (Seeds.count(N) || Seeds.count(S)) {
      MayGC.insert(&F);
      continue;
    }
    if (F.isDeclaration() && !externIsSafe(N))
      MayGC.insert(&F);
  }

  // Propagate: F may-GC-and-return if some call site whose callee may
  // GC-and-return (or is indirect) sits in a block from which F can return.
  bool Changed = true;
  while (Changed) {
    Changed = false;
    for (Function &F : M) {
      if (F.isDeclaration() || MayGC.count(&F) || F.doesNotReturn())
        continue;
      const auto &Ret = CanRet[&F];
      for (const Instruction &I : instructions(F)) {
        const auto *CB = dyn_cast<CallBase>(&I);
        if (!CB || isa<IntrinsicInst>(CB))
          continue;
        if (!Ret.count(I.getParent()))
          continue; // this call site never leads back to a `ret`
        const Function *Callee = CB->getCalledFunction();
        if (!Callee || MayGC.count(Callee)) { // indirect hook, or may-GC
          MayGC.insert(&F);
          Changed = true;
          break;
        }
      }
    }
  }
}

bool RootOpt::isMayGCCall(const Instruction *I) const {
  const auto *CB = dyn_cast<CallBase>(I);
  if (!CB)
    return false;
  if (isa<IntrinsicInst>(CB))
    return false;
  const Function *Callee = CB->getCalledFunction();
  if (!Callee)
    return true; // indirect
  StringRef N = Callee->getName();
  if (N == kPushFn || N == kPopFn || N == "sp_gc_cleanup")
    return false;
  return MayGC.count(Callee) != 0;
}

//===--------------------------------------------------------------------===//
// R3: does the callee root parameter #ArgNo before it can collect?
//===--------------------------------------------------------------------===//

static Value *peelTag(Value *V);

//
// Spinel's codegen opens every generated method with SP_GC_ROOT on each
// reference parameter.  We do not assume it -- we check the body:
//   store ptr %argN, ptr %slot         (the parameter's home alloca)
//   ...
//   call i32 @_sp_gc_root_push(ptr %slot)
// with no may-GC call anywhere before that push on any path from entry.

bool RootOpt::calleeRootsParam(const Function *F, unsigned ArgNo) {
  if (!F || F->isDeclaration() || ArgNo >= F->arg_size())
    return false;
  auto Key = std::make_pair(F, ArgNo);
  auto It = RootsParamCache.find(Key);
  if (It != RootsParamCache.end())
    return It->second;
  RootsParamCache[Key] = false; // break recursion pessimistically

  const Argument *A = F->getArg(ArgNo);
  if (!A->getType()->isPointerTy())
    return false;

  // the alloca the parameter is spilled into
  const AllocaInst *Home = nullptr;
  for (const User *U : A->users())
    if (const auto *ST = dyn_cast<StoreInst>(U))
      if (ST->getValueOperand() == A)
        if (const auto *AI = dyn_cast<AllocaInst>(ST->getPointerOperand()))
          Home = AI;
  if (!Home)
    return false;

  const Function *PushF = M.getFunction(kPushFn);
  if (!PushF)
    return false;

  // the push must be in the entry block, with no may-GC call before it
  const BasicBlock &Entry = F->getEntryBlock();
  for (const Instruction &I : Entry) {
    if (const auto *CI = dyn_cast<CallInst>(&I)) {
      if (CI->getCalledFunction() == PushF) {
        if (peelTag(const_cast<Value *>(CI->getArgOperand(0))) == Home) {
          RootsParamCache[Key] = true;
          return true;
        }
        continue;
      }
      if (isMayGCCall(&I))
        return false;
    }
  }
  return false;
}

//===--------------------------------------------------------------------===//
// R1: elision over inert regions
//===--------------------------------------------------------------------===//

// Peel `inttoptr(or(ptrtoint(A), tag))` -- the RBVAL/STR tagged forms.
static Value *peelTag(Value *V) {
  for (unsigned i = 0; i < 4; ++i) {
    if (auto *I2P = dyn_cast<IntToPtrInst>(V)) {
      V = I2P->getOperand(0);
      continue;
    }
    if (auto *BO = dyn_cast<BinaryOperator>(V)) {
      if (BO->getOpcode() == Instruction::Or &&
          isa<ConstantInt>(BO->getOperand(1))) {
        V = BO->getOperand(0);
        continue;
      }
    }
    if (auto *P2I = dyn_cast<PtrToIntInst>(V)) {
      V = P2I->getOperand(0);
      continue;
    }
    if (auto *CE = dyn_cast<ConstantExpr>(V)) {
      V = CE->getOperand(0);
      continue;
    }
    break;
  }
  return V;
}

// E017.  Does a value of this type carry a pointer (directly, or buried in a
// struct/array/vector)?  Used to spot instructions that keep the rooted
// address in their result without being one of the derivations we follow.
static bool typeCarriesPointer(Type *T, unsigned Depth = 0) {
  if (Depth > 4)
    return true; // do not out-clever ourselves on deep aggregates
  if (T->isPointerTy())
    return true;
  if (auto *VT = dyn_cast<VectorType>(T))
    return typeCarriesPointer(VT->getElementType(), Depth + 1);
  if (auto *AT = dyn_cast<ArrayType>(T))
    return typeCarriesPointer(AT->getElementType(), Depth + 1);
  if (auto *ST = dyn_cast<StructType>(T)) {
    for (Type *E : ST->elements())
      if (typeCarriesPointer(E, Depth + 1))
        return true;
  }
  return false;
}

// E017.  Is this alloca a plain local slot -- i.e. is every use of its ADDRESS
// one we model?  Loads, stores through it, lifetime/debug markers, and the
// SP_GC_ROOT tag chain feeding a push are fine; anything else (a call taking
// the address, a gep handed on, the address itself being stored) means a
// value written into it can be read somewhere this analysis does not see.
static bool allocaIsLocalOnly(const AllocaInst *A, const Function *PushF) {
  for (const User *U : A->users()) {
    const auto *UI = dyn_cast<Instruction>(U);
    if (!UI)
      return false;
    if (isa<LoadInst>(UI) || isa<DbgInfoIntrinsic>(UI) ||
        isa<LifetimeIntrinsic>(UI))
      continue;
    if (const auto *ST = dyn_cast<StoreInst>(UI)) {
      if (ST->getPointerOperand() == A)
        continue; // a store INTO the slot
      return false; // the address itself is being stored
    }
    if (const auto *CI = dyn_cast<CallInst>(UI))
      if (PushF && CI->getCalledFunction() == PushF)
        continue; // the alias has a root of its own: fine, and irrelevant
    // `ptrtoint %A` with a single use is the SP_GC_ROOT_RBVAL/STR tag chain;
    // accept it only when it ends in a push.
    if (const auto *P2I = dyn_cast<PtrToIntInst>(UI)) {
      const Value *V = P2I;
      bool OkChain = false;
      for (unsigned i = 0; i < 4 && V->hasOneUse(); ++i) {
        const auto *N = cast<Instruction>(*V->user_begin());
        if (const auto *CI = dyn_cast<CallInst>(N)) {
          OkChain = PushF && CI->getCalledFunction() == PushF;
          break;
        }
        if (!isa<BinaryOperator>(N) && !isa<IntToPtrInst>(N))
          break;
        V = N;
      }
      if (OkChain)
        continue;
    }
    return false;
  }
  return true;
}

struct RootRecord {
  CallInst *Push = nullptr;
  StoreInst *FlagStore = nullptr;
  AllocaInst *Flag = nullptr;
  AllocaInst *Slot = nullptr;
  SmallVector<CallInst *, 4> Pops;
};

// E017.  R3 exempts a call from vetoing because "the callee roots that
// parameter itself".  That contract is only worth anything while the callee's
// parameter root is still THERE -- and nothing stopped the pass from eliding
// it in the callee's own turn, because inside the callee the parameter's only
// use is often another R3-exempt call.  Elide both and the object has no root
// left anywhere (measured on bm_spectral_norm: main's `u` root plus
// sp_multiply's `lv_u` parameter root; either alone is harmless, together they
// produce `nan (FloatDomainError)` under SPINEL_GC_STRESS=1).
//
// The fix is to pin exactly the roots calleeRootsParam() reports on: the
// entry-block push of a parameter's home alloca.  Pinning them makes R3
// composable by construction -- the property a caller checked stays true after
// the pass has run on the callee.
static bool isParameterHomeRoot(const Function &F, const AllocaInst *Slot,
                                const CallInst *Push) {
  if (Push->getParent() != &F.getEntryBlock())
    return false; // calleeRootsParam only ever looks at the entry block
  for (const Argument &A : F.args()) {
    if (!A.getType()->isPointerTy())
      continue;
    for (const User *U : A.users())
      if (const auto *ST = dyn_cast<StoreInst>(U))
        if (ST->getValueOperand() == &A && ST->getPointerOperand() == Slot)
          return true;
  }
  return false;
}

// Is Slot the home of one of F's pointer parameters?  The frame form of
// isParameterHomeRoot, whose entry-block test the caller makes.
static bool isParameterHomeSlot(const Function &F, const AllocaInst *Slot) {
  for (const Argument &A : F.args()) {
    if (!A.getType()->isPointerTy())
      continue;
    for (const User *U : A.users())
      if (const auto *ST = dyn_cast<StoreInst>(U))
        if (ST->getValueOperand() == &A && ST->getPointerOperand() == Slot)
          return true;
  }
  return false;
}

// R1 for one rooted slot: is a collection impossible wherever the value the
// slot holds is live after Start, the instruction the root begins at?  Start is
// the push for an SP_GC_ROOT, and the store of the slot's entry for a slot a
// root frame names.  True means the root can go; a false answer has counted
// the reason in S.
// Does F itself catch (setjmp or a returns-twice call)?  See runOnFunction.
static bool catchesHere(Function &F) {
  for (Instruction &I : instructions(F)) {
    const auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    if (CB->hasFnAttr(Attribute::ReturnsTwice))
      return true;
    if (const Function *C = CB->getCalledFunction()) {
      StringRef N = C->getName();
      N.consume_front("\01");
      N.consume_front("_");
      if (N == "setjmp" || N == "sigsetjmp" || N == "savectx")
        return true;
    }
  }
  return false;
}

bool RootOpt::slotWindowInert(Function &F, AllocaInst *Slot, Instruction *Start,
                              Stats &S) {
  // ---- protect points: uses of the slot, closed over users of its loads --
  DenseSet<Instruction *> Protect, Kill;
  bool Escapes = false;
  std::deque<Value *> WL;
  for (User *U : Slot->users()) {
    auto *UI = dyn_cast<Instruction>(U);
    if (!UI)
      continue;
    if (UI == Start)
      continue;
    if (isa<DbgInfoIntrinsic>(UI) || isa<LifetimeIntrinsic>(UI))
      continue;
    // the tag chain feeding the push is not a real use
    if (isa<PtrToIntInst>(UI) && UI->hasOneUse())
      continue;
    if (auto *LD = dyn_cast<LoadInst>(UI)) {
      Protect.insert(LD);
      WL.push_back(LD);
      continue;
    }
    if (auto *ST2 = dyn_cast<StoreInst>(UI)) {
      // A store INTO the slot overwrites the value: it KILLS the liveness of
      // whatever was there.  This is what makes a loop body tractable --
      // without it the back edge makes every later allocation look like it
      // is inside the window.
      if (ST2->getPointerOperand() == Slot) {
        Kill.insert(ST2);
        continue;
      }
      Escapes = true; // the address itself is stored somewhere
      break;
    }
    // anything else taking the address (a call, a gep handed on, ...)
    Escapes = true;
    break;
  }
  if (Escapes) {
    S.bailEscape++;
    return false;
  }
  // Close over POINTER DERIVATIONS only.  A gep/bitcast/phi/select of the
  // object pointer keeps the object live; the double a getter returns does
  // not, and neither does the freshly allocated object a callee hands back
  // (codegen roots that one separately).  Following every user transitively
  // would drag an unrelated later `sp_Vec_new` into the window and veto the
  // root that a getter's argument owns.
  //
  // E017.  That narrowing left a hole: the closure follows pointer
  // DERIVATIONS, so a `store ptr %v, ptr %other` -- which returns void --
  // stopped it dead while the object stayed reachable through %other.
  // Spinel's codegen emits exactly that shape as an unrooted alias
  //     sp_PolyArray *_t3 = _t2;      /* _t2 is the rooted one */
  // and a later collection then freed an object _t3 still pointed at
  // (E016 §4c).  Two ways out, selected by -spinel-gc-alias-join:
  //   join off: any store of the value gives up on the root (safe, costs);
  //   join on : if the destination is a NON-ESCAPING alloca, that alloca is
  //             a second home for the same object, so its loads join this
  //             value's live range.  Every other destination still gives up.
  DenseSet<Value *> Seen;
  DenseSet<const AllocaInst *> AliasSlots;
  SmallVector<AllocaInst *, 4> AliasPending;
  bool ValueEscapes = false;

  // a store of the tracked object into memory
  auto noteValueStore = [&](StoreInst *ST) {
    if (ST->getPointerOperand() == Slot)
      return; // written back into its own rooted slot: already a KILL
    if (!AliasJoin) {
      ValueEscapes = true;
      return;
    }
    auto *Dst = dyn_cast<AllocaInst>(ST->getPointerOperand());
    if (!Dst || !allocaIsLocalOnly(Dst, M.getFunction(kPushFn))) {
      // a global, a heap field, a computed address, or an alloca whose own
      // address escapes: the alias can be read from somewhere we do not
      // model.  Give up.
      ValueEscapes = true;
      return;
    }
    if (AliasSlots.insert(Dst).second)
      AliasPending.push_back(Dst);
  };

  for (;;) {
    while (!WL.empty()) {
      Value *V = WL.front();
      WL.pop_front();
      if (!Seen.insert(V).second)
        continue;
      for (User *U : V->users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if (!UI)
          continue;
        Protect.insert(UI); // V must be live where it is used
        if (auto *ST = dyn_cast<StoreInst>(UI))
          if (ST->getValueOperand() == V)
            noteValueStore(ST);
        // The same hole one step removed: ptrtoint takes the object out of
        // the pointer world, where this closure cannot follow it.
        if (isa<PtrToIntInst>(UI))
          ValueEscapes = true;
        bool Derives = UI->getType()->isPointerTy() &&
                       (isa<GetElementPtrInst>(UI) || isa<BitCastInst>(UI) ||
                        isa<AddrSpaceCastInst>(UI) || isa<PHINode>(UI) ||
                        isa<SelectInst>(UI));
        if (Derives) {
          WL.push_back(UI);
        } else if (!isa<CallBase>(UI) && !isa<LoadInst>(UI) &&
                   typeCarriesPointer(UI->getType())) {
          // Anything ELSE that keeps the address in its result -- freeze,
          // insertvalue of the pointer into an sp_RbVal, a vector build --
          // hands the object on somewhere this closure does not model.  A
          // call is exempt (its result is a different object, and the call
          // itself is already a protect point / veto); so is a load (that
          // reads a FIELD of the object, whose own rooting is another
          // root's business).
          ValueEscapes = true;
        }
      }
      if (ValueEscapes)
        break;
    }
    if (ValueEscapes || AliasPending.empty())
      break;
    // Feed an alias slot's loads back into the same closure.  Note that NO
    // kills are recorded for alias slots: an alias's live range is only ever
    // extended, never cut short, which is the safe direction.
    AllocaInst *A = AliasPending.pop_back_val();
    for (User *U : A->users())
      if (auto *LD = dyn_cast<LoadInst>(U)) {
        Protect.insert(LD);
        WL.push_back(LD);
      }
  }
  if (ValueEscapes) {
    S.bailValEsc++;
    return false;
  }
  S.aliasJoined += AliasSlots.size();

  // R3: a may-GC call that only CONSUMES the value as an argument does not
  // need the caller's root when the callee roots that parameter itself
  // before it can collect -- which is what Spinel's codegen emits for every
  // reference parameter.  Such a call stops VETOING.
  //
  // It must NOT stop being a protect point: the value is loaded before the
  // call and the remaining arguments are evaluated after that load, so a
  // may-GC call sitting between the load and this one still has to veto.
  // Dropping the call from `Protect` would end the live range at the load
  // and hide exactly that case.
  DenseSet<const Instruction *> Exempt;
  if (UseCalleeRoots) {
    for (Instruction *I : Protect) {
      auto *CB = dyn_cast<CallBase>(I);
      if (!CB || !isMayGCCall(I))
        continue;
      const Function *Callee = CB->getCalledFunction();
      if (!Callee)
        continue;
      bool AllArgsRooted = true;
      bool Any = false;
      for (unsigned a = 0; a < CB->arg_size(); ++a) {
        if (!Seen.count(CB->getArgOperand(a)))
          continue;
        Any = true;
        if (!calleeRootsParam(Callee, a)) {
          AllArgsRooted = false;
          break;
        }
      }
      if (Any && AllArgsRooted)
        Exempt.insert(I);
    }
  }

  // ---- window = forward-reachable-from-push  AND  value-live ------------
  BasicBlock *PushBB = Start->getParent();

  // backward liveness of the ROOTED VALUE, with stores into the slot as
  // kills.  LiveOut(BB) = OR LiveIn(succ); scanning a block backwards, a
  // GEN sets live, a KILL clears it.
  DenseSet<const BasicBlock *> LiveIn;
  {
    bool Changed = true;
    while (Changed) {
      Changed = false;
      for (BasicBlock &BB : F) {
        bool Live = false;
        for (BasicBlock *Su : successors(&BB))
          if (LiveIn.count(Su)) {
            Live = true;
            break;
          }
        for (auto It = BB.rbegin(); It != BB.rend(); ++It) {
          Instruction *I = &*It;
          if (Kill.count(I))
            Live = false;
          if (Protect.count(I))
            Live = true;
        }
        if (Live && LiveIn.insert(&BB).second)
          Changed = true;
      }
    }
  }

  // blocks reachable from PushBB through >= 1 edge
  DenseSet<BasicBlock *> FwdStrict;
  {
    std::deque<BasicBlock *> Q;
    for (BasicBlock *Su : successors(PushBB))
      if (FwdStrict.insert(Su).second)
        Q.push_back(Su);
    while (!Q.empty()) {
      BasicBlock *B = Q.front();
      Q.pop_front();
      for (BasicBlock *Su : successors(B))
        if (FwdStrict.insert(Su).second)
          Q.push_back(Su);
    }
  }

  bool Keep = false;
  for (BasicBlock &BB : F) {
    bool BlockFwd = FwdStrict.count(&BB) != 0;
    if (!BlockFwd && &BB != PushBB)
      continue;
    // live-after-instruction, computed by one backward scan of the block
    DenseSet<const Instruction *> LiveAfter;
    {
      bool Live = false;
      for (BasicBlock *Su : successors(&BB))
        if (LiveIn.count(Su)) {
          Live = true;
          break;
        }
      for (auto It = BB.rbegin(); It != BB.rend(); ++It) {
        Instruction *I = &*It;
        if (Live)
          LiveAfter.insert(I);
        if (Kill.count(I))
          Live = false;
        if (Protect.count(I))
          Live = true;
      }
    }

    bool AfterPush = BlockFwd; // whole block is forward-reachable
    for (Instruction &I : BB) {
      if (!AfterPush) {
        if (&I == Start)
          AfterPush = true;
        continue;
      }
      // the value must be live ACROSS I for a collection in I to matter
      if (!LiveAfter.count(&I) && !Protect.count(&I))
        continue;
      if (isMayGCCall(&I) && !Exempt.count(&I)) {
        Keep = true;
        if (Report) {
          const auto *CB = cast<CallBase>(&I);
          errs() << "  keep root in " << F.getName() << ": vetoed by "
                 << (CB->getCalledFunction()
                         ? CB->getCalledFunction()->getName()
                         : StringRef("<indirect>"))
                 << "\n";
        }
        break;
      }
    }
    if (Keep)
      break;
  }

  if (Keep) {
    S.bailMayGC++;
    return false;
  }
  return true;
}

bool RootOpt::runOnFunction(Function &F, Stats &S) {
  Function *PushF = M.getFunction(kPushFn);
  Function *PopF = M.getFunction(kPopFn);
  if (!PushF)
    return false;

  // The "may-GC only on a non-returning path" relaxation assumes a raise never
  // comes BACK into this frame.  A function that itself catches (setjmp)
  // resumes after the longjmp with sp_gc_nroots rolled back to the handler's
  // watermark, so leave every root of such a function alone.
  if (catchesHere(F))
    return false;

  SmallVector<RootRecord, 32> Records;
  for (Instruction &I : instructions(F)) {
    auto *CI = dyn_cast<CallInst>(&I);
    if (!CI || CI->getCalledFunction() != PushF)
      continue;
    S.pushSeen++;
    RootRecord R;
    R.Push = CI;
    // the flag: the single store of the push's result into an i32 alloca
    if (!CI->hasOneUse()) {
      S.bailShape++;
      continue;
    }
    auto *St = dyn_cast<StoreInst>(*CI->user_begin());
    if (!St || St->getValueOperand() != CI) {
      S.bailShape++;
      continue;
    }
    auto *Flag = dyn_cast<AllocaInst>(St->getPointerOperand());
    if (!Flag) {
      S.bailShape++;
      continue;
    }
    // the slot
    auto *Slot = dyn_cast<AllocaInst>(peelTag(CI->getArgOperand(0)));
    if (!Slot) {
      S.bailShape++;
      continue;
    }
    // every other user of the flag must be a pop
    bool Ok = true;
    for (User *U : Flag->users()) {
      if (U == St)
        continue;
      // clang at -O2 puts llvm.lifetime markers on both allocas
      if (isa<DbgInfoIntrinsic>(U) || isa<LifetimeIntrinsic>(U))
        continue;
      auto *PC = dyn_cast<CallInst>(U);
      if (PC && PopF && PC->getCalledFunction() == PopF) {
        R.Pops.push_back(PC);
        continue;
      }
      Ok = false;
      break;
    }
    if (!Ok || R.Pops.empty()) {
      S.bailShape++;
      continue;
    }
    R.FlagStore = St;
    R.Flag = Flag;
    R.Slot = Slot;
    Records.push_back(R);
  }

  bool Changed = false;
  for (RootRecord &R : Records) {
    // R3's contract (see isParameterHomeRoot): keep every parameter root while
    // callee-roots exemption is enabled, or the exemption eats its own base.
    if (UseCalleeRoots && isParameterHomeRoot(F, R.Slot, R.Push)) {
      S.bailParamRoot++;
      continue;
    }
    if (!slotWindowInert(F, R.Slot, R.Push, S))
      continue;

    // ---- erase -----------------------------------------------------------
    {
      int Idx = ElideIndex++;
      if (Idx < ElideLo || Idx > ElideHi)
        continue;
      if (Report) {
        errs() << "  elide #" << Idx << " in " << F.getName();
        if (const DebugLoc &DL = R.Push->getDebugLoc())
          errs() << " at line " << DL.getLine();
        errs() << "\n";
      }
    }
    for (CallInst *P : R.Pops)
      P->eraseFromParent();
    R.FlagStore->eraseFromParent();
    Value *Arg = R.Push->getArgOperand(0);
    R.Push->eraseFromParent();
    if (auto *AI = dyn_cast<Instruction>(Arg))
      if (AI->use_empty())
        AI->eraseFromParent();
    S.elided++;
    Changed = true;
  }
  return Changed;
}

//===--------------------------------------------------------------------===//
// R1 for root frames
//===--------------------------------------------------------------------===//
//
// Since upstream 5f7f80820 a generated function registers ONE root-array entry
// for all of its function-scope roots (vendor/spinel/lib/sp_gc.h, "root
// frames"):
//
//   %f = alloca { sp_gc_frame_hdr, [np x ptr] }      ; or with [nv x sp_RbVal]
//   memcpy(%f, @__const.<fn>._gcf, ...)              ; header {nv, np}, zeroed
//   _sp_gc_root_push(inttoptr(ptrtoint %f | 3))      ; result unused
//   store inttoptr(ptrtoint %slot | tag), gep %f, 0, 1, i   ; entry i
//   ...
//   sp_gc_cleanup(%saved)                            ; SP_GC_SAVE pops it
//
// The frame is one root whose contents are the entries.  Its push can go when
// every entry's slot passes the same R1 proof as an SP_GC_ROOT of that slot,
// with the window starting at the entry's store -- no collection can see the
// frame while any of those values is live, so registering it is unobservable.
// Anything else the frame holds or is used for (the boxed-temporary slots, a
// load of an entry, the frame's address leaving the function) is not
// modelled, and the frame is kept.  The entries go with the push.
bool RootOpt::elideFrames(Function &F, Stats &S) {
  Function *PushF = M.getFunction(kPushFn);
  if (!PushF || catchesHere(F))
    return false;
  SmallVector<CallInst *, 2> Pushes;
  for (Instruction &I : instructions(F))
    if (auto *CI = dyn_cast<CallInst>(&I))
      if (CI->getCalledFunction() == PushF && CI->use_empty())
        Pushes.push_back(CI);

  bool Changed = false;
  for (CallInst *Push : Pushes) {
    auto *Frame = dyn_cast<AllocaInst>(peelTag(Push->getArgOperand(0)));
    auto *FT = Frame ? dyn_cast<StructType>(Frame->getAllocatedType()) : nullptr;
    auto *Hdr = FT && FT->getNumElements() == 2
                    ? dyn_cast<StructType>(FT->getElementType(0)) : nullptr;
    auto *Arr = FT && FT->getNumElements() == 2
                    ? dyn_cast<ArrayType>(FT->getElementType(1)) : nullptr;
    // only the pointer-entry form: { sp_gc_frame_hdr, [np x ptr] }
    if (!Hdr || !Hdr->hasName() || !Hdr->getName().starts_with("struct.sp_gc_frame_hdr") ||
        !Arr || !Arr->getElementType()->isPointerTy())
      continue;
    S.framesSeen++;

    // Every use of the frame's address must be one modelled here.
    SmallVector<StoreInst *, 8> Entries;
    SmallVector<Instruction *, 8> Dead; // address arithmetic to drop afterwards
    bool Ok = true;
    std::deque<Instruction *> WL;
    for (User *U : Frame->users())
      WL.push_back(cast<Instruction>(U));
    while (Ok && !WL.empty()) {
      Instruction *UI = WL.front();
      WL.pop_front();
      if (isa<DbgInfoIntrinsic>(UI) || isa<LifetimeIntrinsic>(UI))
        continue;
      if (auto *MC = dyn_cast<MemCpyInst>(UI)) {
        // the header initialiser: a copy INTO the frame from a constant
        auto *G = dyn_cast<GlobalVariable>(MC->getSource());
        if (MC->getDest() == Frame && G && G->isConstant())
          continue;
        Ok = false;
        break;
      }
      if (auto *MS = dyn_cast<MemSetInst>(UI)) {
        // or a zeroing of the whole frame, then the counts stored (below)
        if (MS->getDest() == Frame && isa<ConstantInt>(MS->getValue()))
          continue;
        Ok = false;
        break;
      }
      if (isa<PtrToIntInst>(UI)) {
        // the tag chain into this push, and nowhere else
        Value *V = UI;
        bool Chain = false;
        for (unsigned i = 0; i < 4 && V->hasOneUse(); ++i) {
          auto *N = cast<Instruction>(*V->user_begin());
          if (N == Push) {
            Chain = true;
            break;
          }
          if (!isa<BinaryOperator>(N) && !isa<IntToPtrInst>(N))
            break;
          V = N;
        }
        if (!Chain)
          Ok = false;
        continue;
      }
      if (auto *GEP = dyn_cast<GetElementPtrInst>(UI)) {
        Dead.push_back(GEP);
        for (User *G : GEP->users())
          WL.push_back(cast<Instruction>(G));
        continue;
      }
      if (auto *ST = dyn_cast<StoreInst>(UI)) {
        // a store INTO the frame, through one of its geps: a constant count
        // is the header's initialiser, a pointer is an entry (a tagged slot
        // address). The frame's own address stored anywhere is neither.
        Value *Ptr = ST->getPointerOperand();
        if (ST->getValueOperand() == Frame || !isa<GetElementPtrInst>(Ptr)) {
          Ok = false;
          break;
        }
        if (isa<ConstantInt>(ST->getValueOperand()))
          continue;
        if (!ST->getValueOperand()->getType()->isPointerTy()) {
          Ok = false;
          break;
        }
        Entries.push_back(ST);
        continue;
      }
      Ok = false; // a load, a call taking the frame, the address stored ...
    }
    if (!Ok) {
      S.bailFrameShape++;
      continue;
    }

    bool Inert = true;
    for (StoreInst *E : Entries) {
      auto *Slot = dyn_cast<AllocaInst>(peelTag(E->getValueOperand()));
      if (!Slot) {
        S.bailFrameShape++;
        Inert = false;
        break;
      }
      // R3's contract, as for SP_GC_ROOT: a parameter's home rooted in the
      // entry block is what calleeRootsParam relies on
      if (UseCalleeRoots && E->getParent() == &F.getEntryBlock() &&
          isParameterHomeSlot(F, Slot)) {
        S.bailParamRoot++;
        Inert = false;
        break;
      }
      if (!slotWindowInert(F, Slot, E, S)) {
        Inert = false;
        break;
      }
    }
    if (!Inert)
      continue;

    {
      int Idx = ElideIndex++;
      if (Idx < ElideLo || Idx > ElideHi)
        continue;
      if (Report)
        errs() << "  elide frame #" << Idx << " in " << F.getName() << " ("
               << Entries.size() << " entries)\n";
    }
    for (StoreInst *E : Entries) {
      Value *V = E->getValueOperand();
      E->eraseFromParent();
      // the entry's own tag chain, now unused
      for (unsigned i = 0; i < 4; ++i) {
        auto *I = dyn_cast<Instruction>(V);
        if (!I || !I->use_empty())
          break;
        V = I->getNumOperands() ? I->getOperand(0) : nullptr;
        I->eraseFromParent();
        if (!V)
          break;
      }
    }
    Value *Arg = Push->getArgOperand(0);
    Push->eraseFromParent();
    for (unsigned i = 0; i < 4; ++i) {
      auto *I = dyn_cast<Instruction>(Arg);
      if (!I || !I->use_empty() || isa<AllocaInst>(I))
        break;
      Arg = I->getOperand(0);
      I->eraseFromParent();
    }
    for (auto It = Dead.rbegin(); It != Dead.rend(); ++It)
      if ((*It)->use_empty())
        (*It)->eraseFromParent();
    S.framesElided++;
    Changed = true;
  }
  return Changed;
}

//===--------------------------------------------------------------------===//
// R2: batching
//===--------------------------------------------------------------------===//
//
//   n = load sp_gc_nroots
//   if (n <= MAX - k) { roots[n]=p0 .. roots[n+k-1]=pk-1;      <- slots FIRST
//                       sp_gc_nroots = n + k;  flag_i = 1 }
//   else              { flag_i = _sp_gc_root_push(p_i) ... }   <- exact fallback
//
// The slot stores precede the counter store, so nothing can observe a counter
// covering an unwritten slot.  See safety_analysis.md for the longjmp case.

bool RootOpt::batchFunction(Function &F, Stats &S) {
  Function *PushF = M.getFunction(kPushFn);
  if (!PushF)
    return false;
  GlobalVariable *NRoots = M.getGlobalVariable("sp_gc_nroots", true);
  GlobalVariable *Roots = M.getGlobalVariable("sp_gc_roots", true);
  if (!NRoots || !Roots)
    return false;

  bool Changed = false;
  // snapshot: the transform inserts blocks (one of which holds the untouched
  // fallback calls), and revisiting those would batch them again forever.
  SmallVector<BasicBlock *, 64> Blocks;
  for (BasicBlock &BB : F)
    Blocks.push_back(&BB);
  for (BasicBlock *BBp : Blocks) {
    BasicBlock &BB = *BBp;
    // maximal runs of pushes with no other call in between
    SmallVector<CallInst *, 8> Run;
    SmallVector<SmallVector<CallInst *, 8>, 4> Runs;
    for (Instruction &I : BB) {
      auto *CI = dyn_cast<CallInst>(&I);
      if (CI && CI->getCalledFunction() == PushF) {
        Run.push_back(CI);
        continue;
      }
      if (CI && !isa<IntrinsicInst>(CI)) { // any other call breaks the run
        if (Run.size() > 1)
          Runs.push_back(Run);
        Run.clear();
      }
    }
    if (Run.size() > 1)
      Runs.push_back(Run);

    for (auto &R : Runs) {
      unsigned K = R.size();
      // every push in the run must have the flag-store shape
      SmallVector<StoreInst *, 8> Flags;
      bool Ok = true;
      for (CallInst *P : R) {
        if (!P->hasOneUse()) {
          Ok = false;
          break;
        }
        auto *St = dyn_cast<StoreInst>(*P->user_begin());
        if (!St || St->getValueOperand() != P ||
            !isa<AllocaInst>(St->getPointerOperand())) {
          Ok = false;
          break;
        }
        Flags.push_back(St);
      }
      if (!Ok)
        continue;

      int Idx = BatchIndex++;
      if (Idx < BatchLo || Idx > BatchHi)
        continue;
      if (Report)
        errs() << "  batch #" << Idx << " k=" << K << " in " << F.getName()
               << "\n";

      LLVMContext &C = F.getContext();
      Type *I32 = Type::getInt32Ty(C);
      Type *PtrT = PointerType::getUnqual(C);

      // Split so that [First .. LastFlagStore] becomes the fast/slow diamond.
      Instruction *First = R.front();
      Instruction *Last = Flags.back();
      IRBuilder<> B(First);
      LoadInst *N = B.CreateLoad(I32, NRoots, "sp.nroots");
      Value *Cond = B.CreateICmpSLE(
          N, ConstantInt::get(I32, kGCStackMax - (int64_t)K), "sp.fits");

      BasicBlock *Tail = Last->getParent()->splitBasicBlock(
          Last->getNextNode(), "sp.batch.done");
      BasicBlock *Head = First->getParent();
      BasicBlock *Fast = BasicBlock::Create(C, "sp.batch.fast", &F, Tail);
      BasicBlock *Slow = BasicBlock::Create(C, "sp.batch.slow", &F, Tail);

      // rewire Head's terminator (the unconditional br the split created)
      Head->getTerminator()->eraseFromParent();
      IRBuilder<> HB(Head);
      HB.CreateCondBr(Cond, Fast, Slow);

      // fast path: k slot stores, then one counter store
      IRBuilder<> FB(Fast);
      Value *NIdx = FB.CreateSExt(N, Type::getInt64Ty(C));
      for (unsigned i = 0; i < K; ++i) {
        Value *Idx = FB.CreateAdd(NIdx, ConstantInt::get(Type::getInt64Ty(C), i));
        Value *GEP = FB.CreateGEP(PtrT, Roots, Idx);
        FB.CreateStore(R[i]->getArgOperand(0), GEP);
      }
      FB.CreateStore(FB.CreateAdd(N, ConstantInt::get(I32, K)), NRoots);
      for (unsigned i = 0; i < K; ++i)
        FB.CreateStore(ConstantInt::get(I32, 1), Flags[i]->getPointerOperand());
      FB.CreateBr(Tail);

      // slow path: the original calls, moved verbatim
      IRBuilder<> SB(Slow);
      for (unsigned i = 0; i < K; ++i) {
        CallInst *NewC = cast<CallInst>(R[i]->clone());
        NewC->insertInto(Slow, Slow->end());
        SB.SetInsertPoint(Slow);
        new StoreInst(NewC, Flags[i]->getPointerOperand(), Slow);
      }
      BranchInst::Create(Tail, Slow);

      // drop the originals (they sat between First and Last in Head)
      for (unsigned i = 0; i < K; ++i) {
        Flags[i]->eraseFromParent();
        R[i]->eraseFromParent();
      }
      S.batched += K;
      S.batches++;
      Changed = true;
      break; // conservative: one batch per block per run of the pass
    }
  }
  return Changed;
}

bool RootOpt::run(Stats &S) {
  computeMayGC();
  bool Changed = false;
  for (Function &F : M) {
    if (F.isDeclaration())
      continue;
    if (DoElide) {
      Changed |= runOnFunction(F, S);
      Changed |= elideFrames(F, S);
    }
  }
  if (DoBatch)
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      Changed |= batchFunction(F, S);
    }
  return Changed;
}

struct SpinelGCRootsPass : PassInfoMixin<SpinelGCRootsPass> {
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
    Stats S;
    RootOpt O(M);
    bool Changed = O.run(S);
    if (Report)
      errs() << "spinel-gc-roots: " << M.getName() << ": seen " << S.pushSeen
             << " elided " << S.elided << " batched " << S.batched << " in "
             << S.batches << " batches | kept: mayGC " << S.bailMayGC
             << " escape " << S.bailEscape << " valesc " << S.bailValEsc
             << " paramroot " << S.bailParamRoot
             << " shape " << S.bailShape << " | aliases joined "
             << S.aliasJoined << " | frames: seen " << S.framesSeen
             << " elided " << S.framesElided << " shape " << S.bailFrameShape
             << "\n";
    return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
  }
  static bool isRequired() { return true; }
};

} // namespace

llvm::PassPluginLibraryInfo getSpinelGCRootsPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "SpinelGCRoots", LLVM_VERSION_STRING,
          [](PassBuilder &PB) {
            // opt -passes=spinel-gc-roots
            PB.registerPipelineParsingCallback(
                [](StringRef Name, ModulePassManager &MPM,
                   ArrayRef<PassBuilder::PipelineElement>) {
                  if (Name == "spinel-gc-roots") {
                    MPM.addPass(SpinelGCRootsPass());
                    return true;
                  }
                  return false;
                });
            // clang -fpass-plugin=...: run before mem2reg/SROA
            PB.registerPipelineStartEPCallback(
                [](ModulePassManager &MPM, OptimizationLevel L) {
                  if (L != OptimizationLevel::O0)
                    MPM.addPass(SpinelGCRootsPass());
                });
          }};
}

extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
  return getSpinelGCRootsPluginInfo();
}
