// Spinel-to-LLVM conversion declarations.
#ifndef SPINEL_CONVERSION_SPINELTOLLVM_PASSES
#define SPINEL_CONVERSION_SPINELTOLLVM_PASSES

include "mlir/Pass/PassBase.td"

def LowerSpinelCheckedArithmetic
    : Pass<"lower-spinel-checked-arithmetic", "mlir::ModuleOp"> {
  let summary = "lower checked arithmetic to the LLVM dialect with an explicit target";
  let description = [{
    raise lowers to s{add,sub,mul}.with.overflow and a flag branch.
    On overflow, hosted calls @sp_raise_cls under the existing runtime contract
    and ends with llvm.unreachable; freestanding uses llvm.intr.trap followed
    by llvm.unreachable.
    First canonicalize wrap/none with the shared rewrite patterns, not copies.
    target is required: refuse missing, empty, unknown or duplicate values.
    No implicit hosted target, OS inference or automatic fallback. Fail if any
    spinel.checked_* remains after conversion.
  }];
  let constructor = "mlir::spinel::createLowerSpinelCheckedArithmeticPassFromOptions()";
  let dependentDialects = [
    "mlir::arith::ArithDialect",
    "mlir::func::FuncDialect",
    "mlir::cf::ControlFlowDialect",
    "mlir::LLVM::LLVMDialect",
  ];
  let options = [
    ListOption<"targets", "target", "std::string",
               "lowering target (hosted | freestanding | freestanding-hook) "
               "-- must be given exactly once">,
    ListOption<"hooks", "hook", "std::string",
               "trap hook symbol -- required exactly once for "
               "target=freestanding-hook, rejected for the other targets">,
  ];
}

#endif // SPINEL_CONVERSION_SPINELTOLLVM_PASSES
