#pragma once
#include "spinel/Analysis/RecordLayout.h"
#include "spinel/Conversion/Consumer.h"

namespace spinel::consumer {
using RecordLayoutPtr = std::shared_ptr<const record::Layout>;
enum class SampleSite { RecordMap, RingEvent, RecordKey };
struct RecordDestination {
  enum class Kind { Map, Ring };
  std::string name;
  Kind kind = Kind::Map;
  // Ring callers pass empty: E016 obtains read provenance from checked Exprs
  // and Consumer borrows. Map callers may name the active destination borrow.
  std::string refVar;
};
struct CheckedRecordValue : Payload {
  RecordLayoutPtr layout;
  // Declaration order, including explicit padding; immutable after checking.
  std::vector<Expr> members;
  Operation *node = nullptr; // Borrowed from the live input module.
  // E020: writes into a live reservation after the zero-initialized record is
  // stored and before submission. Captures own checked data, never SSA.
  std::vector<std::function<LogicalResult(Consumer &, Value, Location)>>
      reservationWrites;
};
RecordLayoutPtr lookupRecordLayout(const Consumer &, StringRef constant);
// Go hash.go sampleRecord, shared by record-valued and scalar-valued hashes.
RecordLayoutPtr checkHashRecordSample(Consumer &, Operation *);
bool recordDeclarationFailed(const Consumer &, StringRef constant);
FailureOr<Expr> checkRecordMemberValue(Consumer &, Operation *,
                                      const record::Layout &,
                                      const record::FieldLayout &);
FailureOr<Value> emitRecordMemberValue(Consumer &, const Expr &,
                                      const record::FieldLayout &);
// Caller verifies positional arity against layout.fields.size() first.
LogicalResult checkRecordSample(Consumer &, llvm::ArrayRef<Operation *> args,
                                const record::Layout &, StringRef zeroMessage,
                                SampleSite);
FailureOr<std::shared_ptr<const CheckedRecordValue>>
// Failure always records a diagnostic (or probe issue while probing).
checkRecordMake(Consumer &, Operation *make, RecordLayoutPtr,
                const RecordDestination &);
// A checked value may be copied before emission. Test-only mutations may swap
// members in the copy while preserving layout; production never mutates it.
// Called at the destination's insertion point (ring: inside present region).
// The returned SSA value is borrowed from that region, never cached in payload.
FailureOr<Value> emitRecordMake(Consumer &, const CheckedRecordValue &);
} // namespace spinel::consumer
