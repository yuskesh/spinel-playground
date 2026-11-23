#ifndef SPINEL_IMPORT_H
#define SPINEL_IMPORT_H
#include "mlir/IR/BuiltinOps.h"
namespace spinel {
mlir::LogicalResult verifyImport(mlir::ModuleOp module);
}
#endif
