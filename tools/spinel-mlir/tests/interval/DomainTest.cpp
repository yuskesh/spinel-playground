#include "spinel/Analysis/MathInterval.h"
#include <iostream>
using namespace spinel::math;
template <class T> bool rejected(llvm::Expected<T> result, Failure expected) {
  if (result)
    return false;
  bool matched = false;
  llvm::handleAllErrors(result.takeError(), [&](const DomainError &e) {
    matched = e.code == expected;
  });
  return matched;
}
int main() {
  unsigned checks = 0, failed = 0;
  auto check = [&](const char *n, bool ok) {
    ++checks;
    if (!ok) {
      ++failed;
      std::cerr << n << " failed\n";
    }
  };
  auto p = [](int64_t n) { return Interval::point(Integer::from(n)); };
  MathInterval bottom, finite(Interval::fullI64()),
      top = MathInterval::unknown();
  check("uninitialized-identity", MathInterval::join(bottom, finite) == finite);
  check("top-not-full-i64", !(top == finite));
  check("top-absorbing", MathInterval::join(finite, top) == top);
  check("join-idempotent", MathInterval::join(finite, finite) == finite);
  check("join-commutative",
        MathInterval::join(MathInterval(p(-3)), MathInterval(p(4))) ==
            MathInterval::join(MathInterval(p(4)), MathInterval(p(-3))));
  check("nonliteral-point-rejected",
        rejected(consume("div", p(8), Integer::from(2), false),
                 Failure::Nonliteral));
  check("wide-add-rejected",
        rejected(consume("add", p(8), Integer::from(2), true, true),
                 Failure::WideValue));
  auto mask = llvm::cantFail(
      consume("&", p(0), Integer::fromUnsigned(UINT64_MAX), true, true));
  check("wide-mask-not-truncated", mask.hi.str() == "18446744073709551615");
  check("wide-shift-zero-rejected",
        rejected(consume("shr", p(0), Integer::from(0), true, true),
                 Failure::WideValue));
  check("wide-shift-oob-rejected",
        rejected(consume("shr", p(0), Integer::from(64), true, true),
                 Failure::ShiftCount));
  check("wide-shift-positive",
        llvm::cantFail(consume("shr", p(0), Integer::from(1), true, true)) ==
            Interval{Integer::from(0), Integer::from(INT64_MAX)});
  Condition c;
  c.op = "<";
  c.left = "x";
  c.rightValue = p(3);
  Environment env{{"x", {Integer::from(0), Integer::from(5)}}};
  check("false-edge", llvm::cantFail(narrow(env, c, false)).at("x") ==
                          Interval{Integer::from(3), Integer::from(5)});
  Condition n;
  n.op = "not";
  n.children = {c};
  check("not-edge", llvm::cantFail(narrow(env, n)).at("x") ==
                        llvm::cantFail(narrow(env, c, false)).at("x"));
  Condition dis;
  dis.op = "or";
  dis.children = {c, c};
  check("or-no-narrow",
        llvm::cantFail(narrow(env, dis)).at("x") == env.at("x"));
  auto updated = llvm::cantFail(narrow(env, c));
  updated.insert_or_assign("x", p(9));
  check("assignment-invalidates",
        updated.at("x") == p(9) && env.at("x").hi == Integer::from(5));
  c.right = "x";
  check("same-local-go-approximation",
        llvm::cantFail(narrow(env, c)).at("x") ==
            Interval{Integer::from(0), Integer::from(4)});
  check("empty-interval-named",
        rejected(Interval::create(Integer::from(3), Integer::from(2)),
                 Failure::EmptyInterval));
  check("width-limit-named",
        rejected(Integer::from(1).shl(1048576), Failure::WidthLimit));
  // API failures are checked by enum, without RTTI or EH.
  check("invalid-parse-named",
        rejected(Integer::parse("abc"), Failure::InvalidInteger));
  check("zero-primitive-named",
        rejected(Integer::divide(Integer::from(1), Integer::from(0)),
                 Failure::DivisionZero));
  check("nonfinite-query-named", rejected(top.finite(), Failure::Nonfinite));
  Condition malformed;
  malformed.op = "not";
  check("malformed-condition-named",
        rejected(narrow(env, malformed), Failure::InvalidCondition));
  std::cout << "domain-checks=" << checks << " failures=" << failed << '\n';
  return failed ? 1 : 0;
}
