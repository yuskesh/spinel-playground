// Canonicalize checked arithmetic by policy. wrap uses flag-free arith addi/subi/muli, defined
// signed 64-bit two-complement wrapping: nsw would incorrectly promise no overflow
// (pair.wrap.expected.mlir). none uses identical flag-free IR (pair.none.expected.mlir). raise
// retains Spinel ops, folding only constant pairs proved nonoverflowing by APInt signed overflow
// helpers. On overflow return failure and retain the op, never substitute
// zero/saturation/wrap/poison. Use separate typed patterns for add/sub/mul, not string opcode
// dispatch, and generated policy enums.
#include "spinel-mlir/Dialect/Spinel/Transforms/Passes.h"

#include "spinel-mlir/Dialect/Spinel/IR/SpinelDialect.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Matchers.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

namespace mlir {
namespace spinel {
#define GEN_PASS_DEF_CANONICALIZECHECKEDARITHMETIC
#include "spinel-mlir/Dialect/Spinel/Transforms/Passes.h.inc"
} // namespace spinel
} // namespace mlir

using namespace mlir;
using namespace mlir::spinel;

namespace {

// Preserve discardable attributes such as sp.origin across rewrite/fold, as promised by roundtrip.
// Copy onto replacements before replacing; otherwise producer fields silently disappear.
template <typename NewOpT>
void replaceKeepingDiscardableAttrs(PatternRewriter &rewriter, Operation *op,
                                    NewOpT newOp) {
  newOp->setDiscardableAttrs(op->getDiscardableAttrDictionary());
  rewriter.replaceOp(op, newOp->getResults());
}

// Fold raise constants only when both operands are constants and compute reports no overflow.
// Otherwise notifyMatchFailure and retain the op; conversion owns runtime exceptions for
// overflowing constants, not a fabricated result here.
template <typename OpT, typename ComputeFn>
LogicalResult foldSafeRaise(OpT op, PatternRewriter &rewriter,
                            ComputeFn compute) {
  APInt lhs, rhs;
  if (!matchPattern(op.getLhs(), m_ConstantInt(&lhs)) ||
      !matchPattern(op.getRhs(), m_ConstantInt(&rhs)))
    return rewriter.notifyMatchFailure(op, "non-constant raise is preserved");
  bool overflow = false;
  APInt result = compute(lhs, rhs, overflow);
  if (overflow)
    return rewriter.notifyMatchFailure(
        op, "constant raise that overflows is preserved");
  auto cst = arith::ConstantOp::create(rewriter, op.getLoc(),
                                       IntegerAttr::get(op.getType(), result));
  replaceKeepingDiscardableAttrs(rewriter, op, cst);
  return success();
}

struct RewriteCheckedAdd : OpRewritePattern<CheckedAddOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(CheckedAddOp op,
                                PatternRewriter &rewriter) const override {
    switch (op.getPolicy()) {
    case OverflowPolicy::Wrap:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::AddIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::None:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::AddIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::Raise:
      return foldSafeRaise(op, rewriter,
                           [](const APInt &l, const APInt &r, bool &ov) {
                             return l.sadd_ov(r, ov);
                           });
    case OverflowPolicy::Trap:
      // Never rewrite trap: only freestanding-hook lowering owns its overflow hook. Missing a
      // switch case once turned checked_add policy trap into arith.addi, silently wrapping. Do not
      // fold constants either: duplicating overflow checks here would split trap semantics across
      // implementations.
      return failure();
    }
    llvm_unreachable("covered OverflowPolicy switch");
  }
};

struct RewriteCheckedSub : OpRewritePattern<CheckedSubOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(CheckedSubOp op,
                                PatternRewriter &rewriter) const override {
    switch (op.getPolicy()) {
    case OverflowPolicy::Wrap:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::SubIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::None:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::SubIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::Raise:
      return foldSafeRaise(op, rewriter,
                           [](const APInt &l, const APInt &r, bool &ov) {
                             return l.ssub_ov(r, ov);
                           });
    case OverflowPolicy::Trap:
      // Never rewrite trap: only freestanding-hook lowering owns its overflow hook. Missing a
      // switch case once turned checked_add policy trap into arith.addi, silently wrapping. Do not
      // fold constants either: duplicating overflow checks here would split trap semantics across
      // implementations.
      return failure();
    }
    llvm_unreachable("covered OverflowPolicy switch");
  }
};

struct RewriteCheckedMul : OpRewritePattern<CheckedMulOp> {
  using OpRewritePattern::OpRewritePattern;
  LogicalResult matchAndRewrite(CheckedMulOp op,
                                PatternRewriter &rewriter) const override {
    switch (op.getPolicy()) {
    case OverflowPolicy::Wrap:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::MulIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::None:
      replaceKeepingDiscardableAttrs(
          rewriter, op,
          arith::MulIOp::create(rewriter, op.getLoc(), op.getLhs(),
                                 op.getRhs()));
      return success();
    case OverflowPolicy::Raise:
      return foldSafeRaise(op, rewriter,
                           [](const APInt &l, const APInt &r, bool &ov) {
                             return l.smul_ov(r, ov);
                           });
    case OverflowPolicy::Trap:
      // Never rewrite trap: only freestanding-hook lowering owns its overflow hook. Missing a
      // switch case once turned checked_add policy trap into arith.addi, silently wrapping. Do not
      // fold constants either: duplicating overflow checks here would split trap semantics across
      // implementations.
      return failure();
    }
    llvm_unreachable("covered OverflowPolicy switch");
  }
};

struct CanonicalizeCheckedArithmeticPass
    : spinel::impl::CanonicalizeCheckedArithmeticBase<
          CanonicalizeCheckedArithmeticPass> {
  void runOnOperation() override {
    RewritePatternSet patterns(&getContext());
    spinel::populateCanonicalizeCheckedArithmeticPatterns(patterns);
    if (failed(applyPatternsGreedily(getOperation(), std::move(patterns))))
      signalPassFailure();
  }
};

} // namespace

void mlir::spinel::populateCanonicalizeCheckedArithmeticPatterns(
    RewritePatternSet &patterns) {
  patterns.add<RewriteCheckedAdd, RewriteCheckedSub, RewriteCheckedMul>(
      patterns.getContext());
}

std::unique_ptr<Pass> mlir::spinel::createCanonicalizeCheckedArithmeticPass() {
  return std::make_unique<CanonicalizeCheckedArithmeticPass>();
}
