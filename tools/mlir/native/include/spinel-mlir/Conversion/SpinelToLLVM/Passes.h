// Spinel-to-LLVM conversion entry points.
#ifndef SPINEL_MLIR_CONVERSION_SPINELTOLLVM_PASSES_H
#define SPINEL_MLIR_CONVERSION_SPINELTOLLVM_PASSES_H

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Pass/Pass.h"

#include "llvm/ADT/StringRef.h"

#include <memory>

namespace mlir {
namespace spinel {

// Target is a closed three-value set with no default. The CLI requires an
// explicit target=; missing, empty, unknown and duplicate values are refused.
// FreestandingHook is the only target that lowers policy trap: on overflow,
// call the profile hook (hook=<symbol>) with four arguments, then terminate
// with llvm.unreachable. The two existing targets' arms remain byte-identical.
// Hosted/Freestanding refuse trap, and FreestandingHook refuses raise, since
// silently substituting either would change semantics.
enum class CheckedArithmeticTarget {
  Hosted,
  Freestanding,
  FreestandingHook,
};

// hookSymbol is meaningful only for FreestandingHook and must be nonempty;
// the profile owns its name. A nonempty value on another target is refused.
std::unique_ptr<mlir::Pass>
createLowerSpinelCheckedArithmeticPass(CheckedArithmeticTarget target,
                                       llvm::StringRef hookSymbol = {});

// Factory for CLI TableGen options. The target is initially unvalidated and
// is checked at the start of runOnOperation.
std::unique_ptr<mlir::Pass> createLowerSpinelCheckedArithmeticPassFromOptions();

#define GEN_PASS_DECL
#include "spinel-mlir/Conversion/SpinelToLLVM/Passes.h.inc"

#define GEN_PASS_REGISTRATION
#include "spinel-mlir/Conversion/SpinelToLLVM/Passes.h.inc"

} // namespace spinel
} // namespace mlir

#endif // SPINEL_MLIR_CONVERSION_SPINELTOLLVM_PASSES_H
