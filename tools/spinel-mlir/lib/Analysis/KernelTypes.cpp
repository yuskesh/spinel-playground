#include "spinel/Analysis/KernelTypes.h"
namespace spinel::tracing {
llvm::Expected<range::RangeValue> integerRange(unsigned bits, bool isSigned,
                                              IntegerSource source) {
  if (bits != 8 && bits != 16 && bits != 32 && bits != 64)
    return math::fail(math::Failure::InvalidTransfer);
  // A 65-bit mathematical value is required for the unsigned 64-bit upper end.
  auto upper = math::Integer::fromUnsigned(
      isSigned ? (uint64_t(1) << (bits - 1)) - 1
               : (bits == 64 ? UINT64_MAX : (uint64_t(1) << bits) - 1));
  auto lower = math::Integer::from(0);
  if (isSigned) {
    auto negative = math::Integer::fromUnsigned(uint64_t(1) << (bits - 1)).neg();
    if (!negative) return negative.takeError();
    lower = *negative;
  }
  range::Form form = range::Form::Computed;
  switch (source) {
  case IntegerSource::KernelField: form = range::Form::Kfload; break;
  case IntegerSource::Argument: form = range::Form::Kparg; break;
  case IntegerSource::FexitReturn: form = range::Form::Retval; break;
  case IntegerSource::RawArgument: form = range::Form::Rawarg; break;
  case IntegerSource::TracepointField: form = range::Form::Tpfield; break;
  case IntegerSource::KernelRead:
  case IntegerSource::KprobeReturn:
  case IntegerSource::ContextField: break;
  default: return math::fail(math::Failure::InvalidTransfer);
  }
  return range::RangeValue{math::MathInterval(math::Interval(lower, upper)),
      false, bits == 64 && !isSigned && source != IntegerSource::KernelRead,
      form};
}
range::RangeValue readStatusRange() {
  return {math::MathInterval(math::Interval(math::Integer::from(INT64_MIN),
                                          math::Integer::from(0))),
          false, false, range::Form::Computed};
}
} // namespace spinel::tracing
