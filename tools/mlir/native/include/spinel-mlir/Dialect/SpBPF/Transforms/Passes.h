// SpBPF pass entry points.
#ifndef SPINEL_MLIR_DIALECT_SPBPF_TRANSFORMS_PASSES_H
#define SPINEL_MLIR_DIALECT_SPBPF_TRANSFORMS_PASSES_H

#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

#include <memory>

namespace mlir {
namespace spbpf {

#define GEN_PASS_DECL
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h.inc"

#define GEN_PASS_REGISTRATION
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h.inc"

} // namespace spbpf
} // namespace mlir

#endif // SPINEL_MLIR_DIALECT_SPBPF_TRANSFORMS_PASSES_H
