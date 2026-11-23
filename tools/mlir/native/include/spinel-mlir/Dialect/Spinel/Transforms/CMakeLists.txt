# TableGen pass declarations, wired like SpBPF Transforms.
set(LLVM_TARGET_DEFINITIONS Passes.td)
mlir_tablegen(Passes.h.inc -gen-pass-decls -name SpinelTransforms)
add_public_tablegen_target(MLIRSpinelTransformsIncGen)
