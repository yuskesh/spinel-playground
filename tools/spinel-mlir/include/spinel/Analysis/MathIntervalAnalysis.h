#pragma once
#include "mlir/Analysis/DataFlow/SparseAnalysis.h"
#include "spinel/Analysis/MathInterval.h"
namespace spinel::math {
using MathLattice = mlir::dataflow::Lattice<MathInterval>;
// E004 fixture profile, not a semantic interpretation of spinel_facts AST.
// Recognizes
// math_fixture.constant/add/sub/mul/neg/not/bit/div/rem/shl/shr/join.
// Region/CFG cycles are rejected before the solver; narrowing env is separate.
llvm::Error runMathIntervalAnalysis(mlir::Operation *root,
                                    mlir::DataFlowSolver &solver);
llvm::Expected<MathInterval>
queryMathInterval(const mlir::DataFlowSolver &solver, mlir::Value value);
} // namespace spinel::math
