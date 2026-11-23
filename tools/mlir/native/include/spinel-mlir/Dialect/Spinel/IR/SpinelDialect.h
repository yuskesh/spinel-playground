// Spinel dialect entry, collecting generated declarations. Include enums before attrdefs before
// ops: EnumParameter needs enums and op getters need attrdefs.
#ifndef SPINEL_MLIR_DIALECT_SPINEL_IR_SPINELDIALECT_H
#define SPINEL_MLIR_DIALECT_SPINEL_IR_SPINELDIALECT_H

#include "mlir/Bytecode/BytecodeOpInterface.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsDialect.h.inc"
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsEnums.h.inc"

#define GET_ATTRDEF_CLASSES
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsAttributes.h.inc"

#define GET_OP_CLASSES
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOps.h.inc"

#endif // SPINEL_MLIR_DIALECT_SPINEL_IR_SPINELDIALECT_H
