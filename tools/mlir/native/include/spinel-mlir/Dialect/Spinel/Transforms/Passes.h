// Spinel pass entry points.
#ifndef SPINEL_MLIR_DIALECT_SPINEL_TRANSFORMS_PASSES_H
#define SPINEL_MLIR_DIALECT_SPINEL_TRANSFORMS_PASSES_H

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include <memory>

namespace mlir {
namespace spinel {

std::unique_ptr<mlir::Pass> createCanonicalizeCheckedArithmeticPass();

// Expose the canonicalization patterns so lowering handles wrap/none with the same implementation
// rather than a second copy with divergent semantics.
void populateCanonicalizeCheckedArithmeticPatterns(
    mlir::RewritePatternSet &patterns);

#define GEN_PASS_DECL
#include "spinel-mlir/Dialect/Spinel/Transforms/Passes.h.inc"

#define GEN_PASS_REGISTRATION
#include "spinel-mlir/Dialect/Spinel/Transforms/Passes.h.inc"

} // namespace spinel
} // namespace mlir

#endif // SPINEL_MLIR_DIALECT_SPINEL_TRANSFORMS_PASSES_H
