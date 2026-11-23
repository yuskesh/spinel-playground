#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
// Synchronous callbacks only. No generated SSA may escape the temporary IR.
using ArgvArrayEmitter = std::function<mlir::FailureOr<mlir::Value>(Consumer &, mlir::Location)>;
using ArgvSlotEmitter = std::function<mlir::LogicalResult(Consumer &, mlir::Value, int64_t, mlir::Location)>;
mlir::LogicalResult emitArgvSlots(Consumer &, mlir::Location,
                                const ArgvArrayEmitter &, const ArgvSlotEmitter &);
}
