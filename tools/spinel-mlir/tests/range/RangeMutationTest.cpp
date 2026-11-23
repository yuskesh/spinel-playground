// Test-only incorrect algorithms; production range API has no mutation hook.
#include "spinel/Analysis/GroupARange.h"
#include <iostream>
using namespace spinel;
using namespace spinel::range;
static RangeValue span(int64_t l, int64_t h) {
  return {math::MathInterval(
              math::Interval{math::Integer::from(l), math::Integer::from(h)}),
          false, false, Form::Local};
}
int main() {
  unsigned detected = 0;
  auto observe = [&](const char *name, std::string original,
                     std::string mutant) {
    bool differs = original != mutant;
    detected += differs;
    std::cout << name << " baseline=" << original << " mutant=" << mutant
              << " detected=" << differs << '\n';
  };
  auto key =
      llvm::cantFail(checkArrayKey(span(4, 4), {"U", 32, false, 4}, {1, 2}));
  // The mutant checks only the lower bound and omits the upper bound.
  auto badKey = span(4, 4);
  bool lowerSafe = !llvm::cantFail(badKey.interval.finite()).lo.negative();
  observe("drop-key-upper", key ? key->code : "ok", lowerSafe ? "ok" : "SB020");
  auto literalValue = span(4294967296LL, 4294967296LL);
  literalValue.form = Form::Literal;
  auto store = llvm::cantFail(
      checkStoreValue(literalValue, {"B", 32, false, 2}, {1, 2}, "delta"));
  observe("drop-store-check", store ? store->code : "ok", "ok");
  Environment env{{"x", span(-10, 20)}};
  math::Condition low;
  low.op = ">=";
  low.left = "x";
  low.rightValue = math::Interval::point(math::Integer::from(0));
  math::Condition high;
  high.op = "<";
  high.left = "x";
  high.rightValue = math::Interval::point(math::Integer::from(4));
  math::Condition both;
  both.op = "and";
  both.children = {low, high};
  auto refined = llvm::cantFail(refineEnvironment(env, both));
  auto original = llvm::cantFail(
      checkArrayKey(refined.at("x"), {"A", 32, false, 4}, {1, 2}));
  auto unrefined =
      llvm::cantFail(checkArrayKey(env.at("x"), {"A", 32, false, 4}, {1, 2}));
  observe("drop-refinement", original ? original->code : "ok",
          unrefined ? unrefined->code : "ok");
  // SB019-before-range belongs to the real E010 consumer and is checked there.
  return detected == 3 ? 0 : 1;
}
