#ifndef SPINEL_FACTS_DIALECT_H
#define SPINEL_FACTS_DIALECT_H
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/BuiltinTypes.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOpsDialect.h.inc"
#define GET_TYPEDEF_CLASSES
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOpsTypes.h.inc"
#define GET_OP_CLASSES
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOps.h.inc"
#endif
