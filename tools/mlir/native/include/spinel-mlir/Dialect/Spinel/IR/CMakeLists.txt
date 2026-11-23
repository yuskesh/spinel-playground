# Root: SpinelOps.td. Besides add_mlir_dialect outputs, generate enum/attrdef
# includes for the policy EnumAttr wrapper, following in-tree Arith. SpBPF has
# no enums and therefore does not need those two pairs.
add_mlir_dialect(SpinelOps spinel)

set(LLVM_TARGET_DEFINITIONS SpinelOps.td)
mlir_tablegen(SpinelOpsEnums.h.inc -gen-enum-decls)
mlir_tablegen(SpinelOpsEnums.cpp.inc -gen-enum-defs)
add_public_tablegen_target(MLIRSpinelOpsEnumsIncGen)

set(LLVM_TARGET_DEFINITIONS SpinelOps.td)
mlir_tablegen(SpinelOpsAttributes.h.inc -gen-attrdef-decls -attrdefs-dialect=spinel)
mlir_tablegen(SpinelOpsAttributes.cpp.inc -gen-attrdef-defs -attrdefs-dialect=spinel)
add_public_tablegen_target(MLIRSpinelOpsAttributesIncGen)
