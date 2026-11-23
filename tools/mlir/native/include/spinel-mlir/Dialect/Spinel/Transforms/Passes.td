// Spinel pass declarations.
#ifndef SPINEL_TRANSFORMS_PASSES
#define SPINEL_TRANSFORMS_PASSES

include "mlir/Pass/PassBase.td"

def CanonicalizeCheckedArithmetic
    : Pass<"canonicalize-spinel-checked-arithmetic", "mlir::ModuleOp"> {
  let summary = "canonicalize checked arithmetic to standard arith without losing its meaning";
  let description = [{
    Policy contract: wrap lowers nonconstants to flag-free arith.{addi,subi,muli}; signed two-complement overflow is defined wrapping, not undefined behavior, so no nsw. The greedy driver folds constants. none uses the same flag-free IR and constant folding. raise retains Spinel operations unless constant folding proves no overflow. Keep overflowing constants and nonconstants; never replace them with zero, saturation, wrap or poison. Target names do not belong here: conversion owns hosted/freestanding raise lowering.
  }];
  let constructor = "mlir::spinel::createCanonicalizeCheckedArithmeticPass()";
  let dependentDialects = ["mlir::arith::ArithDialect"];
}

#endif // SPINEL_TRANSFORMS_PASSES
