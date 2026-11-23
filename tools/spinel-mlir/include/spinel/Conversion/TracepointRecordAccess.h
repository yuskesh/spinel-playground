#pragma once
#include "spinel/Conversion/RecordValue.h"

namespace spinel::consumer {
// Immutable source/declaration metadata. Input nodes are borrowed from the live
// module; no short-lived SSA is retained by a checked copy.
struct TracepointRecordAccess : Payload {
  std::string parameter, field, element;
  int64_t offset = 0, count = 0;
  Operation *definition = nullptr;
};
Dispatch<Expr> checkTracepointRecordCopy(Consumer &, Operation *,
    const record::Layout &, const record::FieldLayout &, bool ring,
    Operation *destination = nullptr);
LogicalResult emitTracepointRecordCopy(Consumer &, const Expr &, Value destination,
                                      StringRef member, Location);
} // namespace spinel::consumer
