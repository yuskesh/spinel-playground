// Lower checked arithmetic for hosted/freestanding. Preserve the canonical
// pair.raise.expected.mlir control flow: call signed add/sub/mul-with-overflow,
// extract flag in the original block, branch to overflow or continuation, and
// extract the value at continuation start. Hosted overflow calls sp_raise_cls
// with the same RangeError/message/signature/noreturn/cold as the importer,
// then unreachable. Freestanding uses intrinsic trap and unreachable, with no
// hosted runtime/strings. Matrix shape names identify mechanisms, excluding
// unreachable on both sides, so matrix/runner grammar stays unchanged.
// First apply shared wrap/none rewrites, then mark all three ops illegal and
// register raise conversion only. Leftover wrap/none must fail, not survive.
// Transfer discardable attributes such as sp.origin to with-overflow; shared
// wrap/none patterns copy them to replacement arith ops. Historical target set
// had two explicit choices, no default: missing/empty/unknown/duplicate values
// produce one invalid-lowering-target line; lowering-control.test controls it.
// Hosted reserved symbols are reused only if their printed definitions match
// canonical bytes, otherwise lowering-symbol-conflict. Freestanding initially
// skipped the check since the pass introduced no references, but an input
// sp_cstr_raise_cls silently survived. Now universally walk every operation,
// including nested symbol tables such as gpu.module: any of the five reserved
// definitions is forbidden, even byte-identical or of another op kind, with one
// forbidden-hosted-symbol line. Fixture not-grep remains an extra output pin.
#include "spinel-mlir/Conversion/SpinelToLLVM/Passes.h"

#include "spinel-mlir/Dialect/Spinel/IR/SpinelDialect.h"
#include "spinel-mlir/Dialect/Spinel/Transforms/Passes.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/WalkPatternRewriteDriver.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <utility>

namespace mlir {
namespace spinel {
#define GEN_PASS_DEF_LOWERSPINELCHECKEDARITHMETIC
#include "spinel-mlir/Conversion/SpinelToLLVM/Passes.h.inc"
} // namespace spinel
} // namespace mlir

using namespace mlir;
using namespace mlir::spinel;

namespace {

// Use importer-equivalent private constant NUL-terminated strings in address space 0. Stable fixed
// names, unlike sequential sp_cstr_N, avoid existing-module counters. Reuse identical canonical
// definitions; validate mismatches at pass entry as lowering-symbol-conflict.
LLVM::GlobalOp getOrCreateCString(OpBuilder &builder, ModuleOp module,
                                  StringRef symbol, StringRef value) {
  if (auto existing = module.lookupSymbol<LLVM::GlobalOp>(symbol))
    return existing;
  OpBuilder::InsertionGuard guard(builder);
  builder.setInsertionPointToStart(module.getBody());
  std::string bytes = (value + Twine('\0')).str();
  auto type = LLVM::LLVMArrayType::get(builder.getI8Type(), bytes.size());
  auto global = LLVM::GlobalOp::create(
      builder, module.getLoc(), type, /*isConstant=*/true,
      LLVM::Linkage::Private, symbol, builder.getStringAttr(bytes));
  global->setAttr("addr_space", builder.getI32IntegerAttr(0));
  return global;
}

// Map trap detail to global symbols deterministically with FNV-1a. Avoid execution-seeded
// llvm::hash_value because gates require artifact byte identity.
uint64_t fnv1a64(StringRef s) {
  uint64_t h = 0xcbf29ce484222325ULL; // offset basis
  for (unsigned char c : s) {
    h ^= c;
    h *= 0x100000001b3ULL; // prime
  }
  return h;
}

// Profile-named trap hook: void(i32 code,i64 a,i64 b,ptr detail), noreturn/cold. Declare and call
// it in func dialect: this pass precedes FuncToLLVM, like boundary/prototype checks. llvm.call
// cannot reference an existing func.func and previously reported an invalid LLVM function.
void getOrCreateTrapHook(OpBuilder &builder, ModuleOp module,
                         StringRef symbol) {
  // Look up symbols of every kind: wrappers/prototype checks already declare this hook as
  // func.func; looking only for LLVMFuncOp would create a second definition. Callers need only its
  // name, so create nothing if present.
  if (module.lookupSymbol(symbol))
    return;
  OpBuilder::InsertionGuard guard(builder);
  builder.setInsertionPointToStart(module.getBody());
  auto ptr = LLVM::LLVMPointerType::get(builder.getContext());
  auto none = LLVM::LLVMVoidType::get(builder.getContext());
  auto ty = builder.getFunctionType({builder.getI32Type(), builder.getI64Type(),
                                     builder.getI64Type(), ptr},
                                    {});
  auto fn = func::FuncOp::create(builder, module.getLoc(), symbol, ty);
  fn.setPrivate();
  // Add nounwind as well as noreturn/cold: freestanding hooks never unwind. Frozen code had all
  // three, revealed by stored extern artifacts. Never add nounwind to hosted sp_raise_cls, which
  // raises and unwinds.
  fn->setAttr("passthrough",
              builder.getArrayAttr({builder.getStringAttr("noreturn"),
                                    builder.getStringAttr("cold"),
                                    builder.getStringAttr("nounwind")}));
  (void)none;
}

// Canonical reserved function spelling shared by generation, byte comparison and freestanding
// prohibition.
constexpr const char *kSymRaiseCls = "sp_raise_cls";
constexpr const char *kSymCstrRaiseCls = "sp_cstr_raise_cls";

// Hosted nil-sentinel raiser is separate from the five overflow symbols: importer Raise emits its
// guard before checked operations. It reports boxed-nil bits in an integer slot, with no
// freestanding equivalent. The 2026-08-30 decision lowers detection to a trap rather than passing
// through the raiser or rejecting every raise/freestanding input.
constexpr const char *kSymRaiseNilIntOp = "sp_raise_nil_int_op";

// Closed set of importer-generated hosted externs. Freestanding exit checks every member rather
// than one hardcoded name; source-scanning controls match MlirGen kRaiseCls/kRaiseNilOp (importer
// hosted externs=2).
constexpr const char *kImporterHostedExterns[] = {kSymRaiseCls,
                                                  kSymRaiseNilIntOp};
constexpr size_t kImporterHostedExternCount =
    sizeof(kImporterHostedExterns) / sizeof(kImporterHostedExterns[0]);
static_assert(kImporterHostedExternCount == 2,
              "the importer emits exactly two hosted runtime externs; adding a "
              "third requires teaching the freestanding exit check about it");

// Declare sp_raise_cls with the importer signature and noreturn/cold.
LLVM::LLVMFuncOp getOrCreateRaiseCls(OpBuilder &builder, ModuleOp module) {
  if (auto existing = module.lookupSymbol<LLVM::LLVMFuncOp>(kSymRaiseCls))
    return existing;
  OpBuilder::InsertionGuard guard(builder);
  builder.setInsertionPointToStart(module.getBody());
  auto ptrTy = LLVM::LLVMPointerType::get(builder.getContext());
  auto fnTy = LLVM::LLVMFunctionType::get(
      LLVM::LLVMVoidType::get(builder.getContext()), {ptrTy, ptrTy});
  auto fn =
      LLVM::LLVMFuncOp::create(builder, module.getLoc(), kSymRaiseCls, fnTy);
  fn->setAttr("passthrough",
              builder.getArrayAttr({builder.getStringAttr("noreturn"),
                                    builder.getStringAttr("cold")}));
  return fn;
}

struct RaiseLoweringInfo {
  const char *opSymbol;     // Operator in the exception message.
  const char *msgSymbol;    // Message global symbol name.
};

// One shared add/sub/mul raise-information table for lowering and canonical-definition generation.
constexpr RaiseLoweringInfo kRaiseAdd = {"+", "sp_cstr_raise_msg_add"};
constexpr RaiseLoweringInfo kRaiseSub = {"-", "sp_cstr_raise_msg_sub"};
constexpr RaiseLoweringInfo kRaiseMul = {"*", "sp_cstr_raise_msg_mul"};

// One reserved-symbol array read in the same order by hosted byte comparison and freestanding
// prohibition. Members come from constants/tables above, keeping each spelling once.
constexpr const char *kReservedHostedSymbols[] = {
    kSymRaiseCls,        kSymCstrRaiseCls,    kRaiseAdd.msgSymbol,
    kRaiseSub.msgSymbol, kRaiseMul.msgSymbol,
};

// Fix closed-set cardinality. Canonical construction names five definitions; an array-only addition
// would lack one. Check array length statically and missing definitions at runtime too, since
// Release removes assertions.
constexpr size_t kReservedHostedSymbolCount =
    sizeof(kReservedHostedSymbols) / sizeof(kReservedHostedSymbols[0]);
static_assert(kReservedHostedSymbolCount == 5,
              "kReservedHostedSymbols is a closed set of 5 names; adding one "
              "requires teaching the canonical module builder about it too");

// Print an operation for byte comparison, including types/linkage/attributes.
std::string printOpToString(Operation *op) {
  std::string buffer;
  llvm::raw_string_ostream os(buffer);
  op->print(os);
  return buffer;
}

// Universal reserved-definition scan: earlier root/ModuleOp enumeration missed other symbol tables
// such as gpu.module, leaking hosted names into freestanding and conflicting hosted copies
// silently. Walk every Operation with sym_name in the five-name set regardless of parent kind.
// Definitions only: SymbolUserOpInterface uses (e.g. llvm.call callee) require a resolvable
// definition via verification. Other uses remain outside scope: an arbitrary discardable
// SymbolRefAttr such as carrier evil=@sp_raise_cls is neither a definition nor verified symbol use
// and survives MLIR. Observed translation drops that unknown attribute, leaving no hosted reference
// in LLVM IR; the spelling passes through, not an object dependency. This limitation is recorded.
using ReservedSymbolHandler = function_ref<WalkResult(Operation *, StringRef)>;
WalkResult walkReservedHostedSymbolDefs(ModuleOp root,
                                        ReservedSymbolHandler handler) {
  return root->walk([&](Operation *op) {
    auto symbol =
        op->getAttrOfType<StringAttr>(SymbolTable::getSymbolAttrName());
    if (!symbol)
      return WalkResult::advance();
    for (StringRef name : kReservedHostedSymbols)
      if (symbol.getValue() == name)
        return handler(op, name);
    return WalkResult::advance();
  });
}

// Build canonical definitions once in an isolated temporary module with the same
// getOrCreateRaiseCls/getOrCreateCString helpers, making canonical and generation definitions
// identical by construction. Reuse byte matches; report only the first mismatch at its location.
// Universal scanning permits an identical nested-table copy even if lowering never references it,
// since it satisfies the contract.
LogicalResult validateReservedHostedSymbols(ModuleOp root) {
  MLIRContext *ctx = root.getContext();
  OpBuilder builder(ctx);
  OwningOpRef<ModuleOp> canon = ModuleOp::create(UnknownLoc::get(ctx));
  getOrCreateRaiseCls(builder, *canon);
  getOrCreateCString(builder, *canon, kSymCstrRaiseCls, "RangeError");
  for (const RaiseLoweringInfo &info : {kRaiseAdd, kRaiseSub, kRaiseMul})
    getOrCreateCString(builder, *canon, info.msgSymbol,
                       (Twine("integer overflow in ") + info.opSymbol).str());

  // Fail visibly on array/canonical-definition drift in Release too; assertions disappeared there
  // and printing null formerly segfaulted.
  std::string canonical[kReservedHostedSymbolCount];
  for (size_t i = 0; i < kReservedHostedSymbolCount; ++i) {
    StringRef name = kReservedHostedSymbols[i];
    Operation *want =
        SymbolTable::lookupSymbolIn(*canon, StringAttr::get(ctx, name));
    if (!want) {
      root.emitError()
          << "internal-mlir-diagnostic: reserved symbol '" << name
          << "' has no canonical definition (kReservedHostedSymbols and the "
             "canonical module builder are out of sync)";
      return failure();
    }
    canonical[i] = printOpToString(want);
  }

  WalkResult walked = walkReservedHostedSymbolDefs(
      root, [&](Operation *existing, StringRef name) {
        for (size_t i = 0; i < kReservedHostedSymbolCount; ++i) {
          if (name != kReservedHostedSymbols[i])
            continue;
          if (printOpToString(existing) == canonical[i])
            return WalkResult::advance();
          break;
        }
        existing->emitError()
            << "lowering-symbol-conflict: existing symbol '" << name
            << "' is not byte-identical to the definition this lowering creates "
               "(E160 hosted runtime contract)";
        return WalkResult::interrupt();
      });
  return failure(walked.wasInterrupted());
}

// Freestanding universally refuses any reserved definition, even byte-identical or a different op
// kind, reporting only the first. The old no-generated-reference rationale leaked input symbols.
// Then replace importer llvm.call sp_raise_nil_int_op with llvm.intr.trap, preserving CFG and
// following unreachable. Only the no-return mechanism changes; unused operator strings/declarations
// disappear during cleanup.
void lowerFreestandingSentinelRaisers(ModuleOp root) {
  SmallVector<LLVM::CallOp> calls;
  root.walk([&](LLVM::CallOp call) {
    if (auto callee = call.getCallee())
      if (*callee == kSymRaiseNilIntOp)
        calls.push_back(call);
  });
  for (LLVM::CallOp call : calls) {
    OpBuilder builder(call);
    LLVM::Trap::create(builder, call.getLoc());
    call.erase();
  }
  // Remove declarations only after their uses disappear, preserving a valid symbol table for later
  // passes.
  if (auto decl = root.lookupSymbol<LLVM::LLVMFuncOp>(kSymRaiseNilIntOp)) {
    if (SymbolTable::symbolKnownUseEmpty(decl, root))
      decl.erase();
  }
}

// Freestanding exit checks every kImporterHostedExterns member, unlike entry rejection of the five
// reserved overflow definitions. A new importer extern must fail visibly until its trap lowering is
// defined.
LogicalResult validateFreestandingNoHostedExterns(ModuleOp root) {
  for (const char *name : kImporterHostedExterns) {
    if (auto decl = root.lookupSymbol<LLVM::LLVMFuncOp>(name)) {
      InFlightDiagnostic diag = decl.emitError();
      diag << "residual-hosted-extern: '" << name
           << "' survives the freestanding lowering (a freestanding artefact "
              "must not depend on the hosted runtime; the sentinel raiser is "
              "lowered to a trap and the overflow raiser is refused at the "
              "entry)";
      return failure();
    }
  }
  return success();
}

LogicalResult validateFreestandingForbiddenSymbols(ModuleOp root) {
  WalkResult walked = walkReservedHostedSymbolDefs(
      root, [](Operation *existing, StringRef name) {
        existing->emitError() << "forbidden-hosted-symbol: symbol '" << name
                              << "' is not allowed for target freestanding";
        return WalkResult::interrupt();
      });
  return failure(walked.wasInterrupted());
}

// Share raise control-flow construction; only intrinsic creation is operation-specific and typed.
template <typename OpT, typename IntrOpT>
struct LowerCheckedRaiseBase : OpConversionPattern<OpT> {
  LowerCheckedRaiseBase(MLIRContext *ctx, CheckedArithmeticTarget target,
                        RaiseLoweringInfo info, StringRef hookSymbol)
      : OpConversionPattern<OpT>(ctx), target(target), info(info),
        hookSymbol(hookSymbol.str()) {}

  LogicalResult
  matchAndRewrite(OpT op, typename OpT::Adaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    // wrap/none should already be rewritten; otherwise leave them illegal without a matching
    // conversion pattern. Entry validation already requires raise with hosted/freestanding and trap
    // only with freestanding-hook, naming mismatches rather than relying on illegal leftovers.
    const bool wantTrap = target == CheckedArithmeticTarget::FreestandingHook;
    if (op.getPolicy() != (wantTrap ? OverflowPolicy::Trap
                                    : OverflowPolicy::Raise))
      return rewriter.notifyMatchFailure(
          op, "policy does not match the lowering target");

    Location loc = op.getLoc();
    auto module = op->template getParentOfType<ModuleOp>();
    MLIRContext *ctx = rewriter.getContext();
    auto i64 = adaptor.getLhs().getType();
    auto structTy = LLVM::LLVMStructType::getLiteral(
        ctx, {i64, rewriter.getI1Type()});

    // Build the intrinsic and extract its flag at the operation location; move discardable
    // attributes onto the intrinsic.
    auto intr = IntrOpT::create(rewriter, loc, structTy, adaptor.getLhs(),
                                adaptor.getRhs());
    intr->setDiscardableAttrs(op->getDiscardableAttrDictionary());
    Value flag = LLVM::ExtractValueOp::create(rewriter, loc, intr.getRes(), 1);

    // Split immediately after the operation; extract the result at continuation start, keeping the
    // flag in the original block as the importer does.
    Block *opBlock = op->getBlock();
    Block *contBlock =
        rewriter.splitBlock(opBlock, std::next(Block::iterator(op)));
    Region *region = opBlock->getParent();

    // Append overflow blocks at the region end, matching importer function layout.
    Block *overflowBlock = rewriter.createBlock(region, region->end());
    rewriter.setInsertionPointToStart(overflowBlock);
    if (target == CheckedArithmeticTarget::Hosted) {
      getOrCreateRaiseCls(rewriter, module);
      getOrCreateCString(rewriter, module, kSymCstrRaiseCls, "RangeError");
      getOrCreateCString(rewriter, module, info.msgSymbol,
                         (Twine("integer overflow in ") + info.opSymbol).str());
      Value cls = LLVM::AddressOfOp::create(
          rewriter, loc, LLVM::LLVMPointerType::get(ctx), kSymCstrRaiseCls);
      Value msg = LLVM::AddressOfOp::create(
          rewriter, loc, LLVM::LLVMPointerType::get(ctx), info.msgSymbol);
      LLVM::CallOp::create(rewriter, loc, TypeRange(),
                           SymbolRefAttr::get(ctx, kSymRaiseCls),
                           ValueRange{cls, msg});
    } else if (target == CheckedArithmeticTarget::FreestandingHook) {
      // Call the profile hook with code and original operands (observed 1, first operand, second
      // operand). Use the full detail attribute carrying the Ruby name; the enclosing sp_<fn>
      // cannot safely recover it. Non-importer operations without detail derive it from operation
      // spelling.
      const std::string detail =
          op.getDetail()
              ? op.getDetail()->str()
              : (Twine("integer overflow in ") + info.opSymbol).str();
      // Use detail FNV-1a for stable global names, avoiding execution-seeded llvm::hash_value and
      // preserving artifact identity. The original comment states that different details never
      // share a global.
      const std::string detailSymbol =
          (Twine("sp_cstr_trap_") + Twine(fnv1a64(detail))).str();
      getOrCreateTrapHook(rewriter, module, hookSymbol);
      getOrCreateCString(rewriter, module, detailSymbol, detail);
      Value codeV = arith::ConstantOp::create(
          rewriter, loc, rewriter.getI32Type(), rewriter.getI32IntegerAttr(1));
      Value detailPtr = LLVM::AddressOfOp::create(
          rewriter, loc, LLVM::LLVMPointerType::get(ctx), detailSymbol);
      Value lhs = adaptor.getLhs(), rhs = adaptor.getRhs();
      if (lhs.getType().isInteger(32)) {
        lhs = arith::ExtSIOp::create(rewriter, loc, rewriter.getI64Type(), lhs);
        rhs = arith::ExtSIOp::create(rewriter, loc, rewriter.getI64Type(), rhs);
      }
      func::CallOp::create(rewriter, loc, TypeRange(), hookSymbol,
                           ValueRange{codeV, lhs, rhs, detailPtr});
    } else {
      LLVM::Trap::create(rewriter, loc);
    }
    LLVM::UnreachableOp::create(rewriter, loc);

    // Terminate the original block with an overflow/continuation flag branch.
    rewriter.setInsertionPointToEnd(opBlock);
    cf::CondBranchOp::create(rewriter, loc, flag, overflowBlock, contBlock);

    // Extract the result at continuation start and replace the operation.
    rewriter.setInsertionPointToStart(contBlock);
    Value value = LLVM::ExtractValueOp::create(rewriter, loc, intr.getRes(), 0);
    rewriter.replaceOp(op, value);
    return success();
  }

  CheckedArithmeticTarget target;
  RaiseLoweringInfo info;
  std::string hookSymbol;
};

struct LowerCheckedAdd
    : LowerCheckedRaiseBase<CheckedAddOp, LLVM::SAddWithOverflowOp> {
  LowerCheckedAdd(MLIRContext *ctx, CheckedArithmeticTarget target,
                   StringRef hook)
      : LowerCheckedRaiseBase(ctx, target, kRaiseAdd, hook) {}
};
struct LowerCheckedSub
    : LowerCheckedRaiseBase<CheckedSubOp, LLVM::SSubWithOverflowOp> {
  LowerCheckedSub(MLIRContext *ctx, CheckedArithmeticTarget target,
                   StringRef hook)
      : LowerCheckedRaiseBase(ctx, target, kRaiseSub, hook) {}
};
struct LowerCheckedMul
    : LowerCheckedRaiseBase<CheckedMulOp, LLVM::SMulWithOverflowOp> {
  LowerCheckedMul(MLIRContext *ctx, CheckedArithmeticTarget target,
                   StringRef hook)
      : LowerCheckedRaiseBase(ctx, target, kRaiseMul, hook) {}
};

struct LowerSpinelCheckedArithmeticPass
    : spinel::impl::LowerSpinelCheckedArithmeticBase<
          LowerSpinelCheckedArithmeticPass> {
  using Base = spinel::impl::LowerSpinelCheckedArithmeticBase<
      LowerSpinelCheckedArithmeticPass>;
  LowerSpinelCheckedArithmeticPass() = default;
  LowerSpinelCheckedArithmeticPass(CheckedArithmeticTarget target,
                                   StringRef hookSymbol)
      : programmaticTarget(target), programmaticHook(hookSymbol.str()) {}
  LowerSpinelCheckedArithmeticPass(
      const LowerSpinelCheckedArithmeticPass &other)
      : Base(other), programmaticTarget(other.programmaticTarget),
        programmaticHook(other.programmaticHook) {}

  void runOnOperation() override {
    // Resolve the historical closed two-target set without a default; explicitly refuse
    // missing/empty/unknown/duplicate values.
    CheckedArithmeticTarget target;
    std::string hook;
    if (programmaticTarget) {
      target = *programmaticTarget;
      hook = programmaticHook;
      if (target == CheckedArithmeticTarget::FreestandingHook && hook.empty()) {
        getOperation().emitError()
            << "invalid-lowering-target: target=freestanding-hook requires a "
               "non-empty hook symbol (the profile owns the name)";
        return signalPassFailure();
      }
    } else {
      if (targets.empty()) {
        getOperation().emitError()
            << "invalid-lowering-target: 'target' is required and has no "
               "default (use target=hosted or target=freestanding)";
        return signalPassFailure();
      }
      if (targets.size() > 1) {
        getOperation().emitError()
            << "invalid-lowering-target: 'target' is specified "
            << targets.size() << " times (it must be given exactly once)";
        return signalPassFailure();
      }
      StringRef t = targets.front();
      if (t == "hosted") {
        target = CheckedArithmeticTarget::Hosted;
      } else if (t == "freestanding") {
        target = CheckedArithmeticTarget::Freestanding;
      } else if (t == "freestanding-hook") {
        target = CheckedArithmeticTarget::FreestandingHook;
      } else {
        getOperation().emitError()
            << "invalid-lowering-target: unknown target '" << t
            << "' (closed set: hosted | freestanding | freestanding-hook)";
        return signalPassFailure();
      }
      // hook= is required for freestanding-hook and refused elsewhere. The profile owns this fact;
      // the pass may not infer a default.
      if (target == CheckedArithmeticTarget::FreestandingHook) {
        if (hooks.size() != 1 || hooks.front().empty()) {
          getOperation().emitError()
              << "invalid-lowering-target: target=freestanding-hook requires "
                 "'hook' exactly once with a non-empty symbol (given "
              << hooks.size() << ")";
          return signalPassFailure();
        }
        hook = hooks.front();
      } else if (!hooks.empty()) {
        getOperation().emitError()
            << "invalid-lowering-target: 'hook' is only valid with "
               "target=freestanding-hook";
        return signalPassFailure();
      }
    }

    // Validate every policy/target pairing at entry, naming the conflicting operation/policy/target
    // rather than a generic leftover-illegal-op failure.
    {
      bool bad = false;
      getOperation().walk([&](Operation *op) {
        std::optional<OverflowPolicy> policy;
        if (auto a = dyn_cast<CheckedAddOp>(op)) policy = a.getPolicy();
        else if (auto b = dyn_cast<CheckedSubOp>(op)) policy = b.getPolicy();
        else if (auto m = dyn_cast<CheckedMulOp>(op)) policy = m.getPolicy();
        if (!policy)
          return;
        const bool isTrap = *policy == OverflowPolicy::Trap;
        const bool hookTarget =
            target == CheckedArithmeticTarget::FreestandingHook;
        if (isTrap && !hookTarget) {
          op->emitError() << "invalid-policy-for-target: trap policy needs "
                             "target=freestanding-hook";
          bad = true;
        } else if (*policy == OverflowPolicy::Raise && hookTarget) {
          op->emitError() << "invalid-policy-for-target: raise policy cannot "
                             "be lowered for target=freestanding-hook";
          bad = true;
        }
      });
      if (bad)
        return signalPassFailure();
    }

    // Universal entry rules differ by target: hosted requires byte-identical canonical definitions;
    // freestanding refuses their presence.
    if (target == CheckedArithmeticTarget::Hosted) {
      if (failed(validateReservedHostedSymbols(getOperation())))
        return signalPassFailure();
    } else {
      if (failed(validateFreestandingForbiddenSymbols(getOperation())))
        return signalPassFailure();
    }

    // Phase 1 rewrites wrap/none with shared patterns via walkAndApplyPatterns. A greedy driver
    // also folds/deletes/merges unrelated already-lowered IR on a second run (observed
    // overflow-block merging and addressof hoisting), breaking idempotence. Walk applies patterns
    // only and leaves modules without spinel operations unchanged.
    {
      RewritePatternSet patterns(&getContext());
      spinel::populateCanonicalizeCheckedArithmeticPatterns(patterns);
      walkAndApplyPatterns(getOperation(), std::move(patterns));
    }

    // Phase 2 lowers raise to LLVM dialect. All three operations are illegal; any survivor fails
    // conversion.
    ConversionTarget conversionTarget(getContext());
    conversionTarget.addIllegalOp<CheckedAddOp, CheckedSubOp, CheckedMulOp>();
    conversionTarget.addLegalDialect<arith::ArithDialect,
                                     cf::ControlFlowDialect,
                                     LLVM::LLVMDialect>();
    conversionTarget.markUnknownOpDynamicallyLegal(
        [](Operation *) { return true; });
    RewritePatternSet patterns(&getContext());
    patterns.add<LowerCheckedAdd, LowerCheckedSub, LowerCheckedMul>(
        &getContext(), target, hook);
    if (failed(applyPartialConversion(getOperation(), conversionTarget,
                                      std::move(patterns))))
      return signalPassFailure();

    // Phase 3, freestanding only: lower importer nil-sentinel cold arms to trap and universally
    // check that no hosted extern remains. Run after phase 2 to keep this separate from
    // hosted-target raise references.
    if (target == CheckedArithmeticTarget::Freestanding ||
        target == CheckedArithmeticTarget::FreestandingHook) {
      lowerFreestandingSentinelRaisers(getOperation());
      if (failed(validateFreestandingNoHostedExterns(getOperation())))
        return signalPassFailure();
    }
  }

  std::optional<CheckedArithmeticTarget> programmaticTarget;
  std::string programmaticHook;
};

} // namespace

std::unique_ptr<Pass> mlir::spinel::createLowerSpinelCheckedArithmeticPass(
    CheckedArithmeticTarget target, StringRef hookSymbol) {
  return std::make_unique<LowerSpinelCheckedArithmeticPass>(target, hookSymbol);
}

std::unique_ptr<Pass>
mlir::spinel::createLowerSpinelCheckedArithmeticPassFromOptions() {
  return std::make_unique<LowerSpinelCheckedArithmeticPass>();
}
