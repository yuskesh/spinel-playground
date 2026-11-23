#pragma once
#include "spinel/Analysis/GroupARange.h"
#include "llvm/ADT/STLFunctionalExtras.h"
namespace spinel::loop {
struct Bounds {
  unsigned count = 0;
  bool runtime = false, inclusive = false, clamp = false;
};
struct BoundOutcome {
  std::optional<Bounds> bounds;
  std::optional<range::RangeIssue> issue;
};
enum class Mode { Probe, Check };
struct Step {
  range::Environment normal;
  std::vector<range::Environment> breaks, nexts;
  std::vector<range::RangeIssue> issues;
};
struct Result {
  range::Environment checkedEntry, post;
  math::Interval iv = math::Interval::point(math::Integer::from(0));
  std::vector<range::RangeIssue> issues;
};
using BodyTransfer = llvm::function_ref<llvm::Expected<Step>(
    const range::Environment &, const math::Interval &, Mode)>;
// The caller validates syntax, block identity, and literal consumption first.
// depth is the number of enclosing loops; product is their bound product.
llvm::Expected<BoundOutcome> resolveBounds(
    const range::RangeValue &count, bool inclusive, unsigned depth,
    unsigned product, range::Site site);
llvm::Expected<range::Environment> joinNormalAndNext(const Step &step);
// Probe callbacks must not publish diagnostics or mutate a checked model.
// The final Check callback runs once, even when the bound is zero.
llvm::Expected<Result> analyzeFinite(const Bounds &bounds,
    const range::Environment &pre, BodyTransfer body);
} // namespace spinel::loop
