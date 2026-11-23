# TableGen declarations for the conversion pass.
set(LLVM_TARGET_DEFINITIONS Passes.td)
mlir_tablegen(Passes.h.inc -gen-pass-decls -name SpinelConversion)
add_public_tablegen_target(MLIRSpinelConversionIncGen)
