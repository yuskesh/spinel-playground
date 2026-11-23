#pragma once
#include "spinel/Conversion/RecordValue.h"

namespace spinel::consumer {
// Checked only through the dedicated destination route, never a scalar value.
// Names are owned; SSA is resolved from the live present-region binding at emit.
struct KernelRecordAccess : Payload {
  std::string variable, structure, typeConstant, field;
  int64_t count = 0;
  bool string = false;
};
Dispatch<Expr> checkKernelRecordCopy(Consumer &, Operation *,
                                     const record::Layout &,
                                     const record::FieldLayout &, bool ring,
                                     Operation *destination = nullptr);
LogicalResult emitKernelRecordCopy(Consumer &, const Expr &, Value destination,
                                    StringRef field, Location);
FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkKernelRingString(Consumer &, Operation *call, const RingDecl &);
} // namespace spinel::consumer
