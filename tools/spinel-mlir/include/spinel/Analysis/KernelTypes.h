#pragma once
#include "spinel/Analysis/GroupARange.h"
namespace spinel::tracing {
enum class IntegerSource {
  KernelField, KernelRead, Argument, FexitReturn, KprobeReturn, RawArgument,
  TracepointField, ContextField
};
// Only integer reads: pointer/array/strptr are separate checked kinds.
llvm::Expected<range::RangeValue> integerRange(unsigned bits, bool isSigned,
                                              IntegerSource source);
range::RangeValue readStatusRange();
} // namespace spinel::tracing
