#pragma once
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/Support/Error.h"
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <limits>
#include <map>
#include <string>
#include <vector>

namespace spinel::math {
enum class Failure {
  WidthLimit,
  InvalidInteger,
  DivisionZero,
  EmptyInterval,
  NegativeBitBound,
  ShiftCount,
  Nonliteral,
  WideValue,
  SignedDivisor,
  Overflow,
  UnknownOperation,
  InvalidCondition,
  Nonfinite,
  CycleNotSupported,
  MissingEvidence,
  SolverFailure,
  InvalidTransfer
};
inline const char *failureName(Failure f) {
  switch (f) {
  case Failure::WidthLimit:
    return "integer-width-limit";
  case Failure::InvalidInteger:
    return "invalid-integer";
  case Failure::DivisionZero:
    return "division-zero";
  case Failure::EmptyInterval:
    return "empty-interval";
  case Failure::NegativeBitBound:
    return "negative-bit-bound";
  case Failure::ShiftCount:
    return "shift-count";
  case Failure::Nonliteral:
    return "nonliteral";
  case Failure::WideValue:
    return "wide-value";
  case Failure::SignedDivisor:
    return "signed-divisor";
  case Failure::Overflow:
    return "overflow";
  case Failure::UnknownOperation:
    return "unknown-operation";
  case Failure::InvalidCondition:
    return "invalid-condition";
  case Failure::Nonfinite:
    return "nonfinite-interval";
  case Failure::CycleNotSupported:
    return "cycle-not-supported";
  case Failure::MissingEvidence:
    return "missing-interval-evidence";
  case Failure::SolverFailure:
    return "interval-solver-failed";
  case Failure::InvalidTransfer:
    return "invalid-interval-transfer";
  }
  llvm_unreachable("exhaustive failure enum");
}
class DomainError : public llvm::ErrorInfo<DomainError> {
public:
  inline static char ID;
  Failure code;
  explicit DomainError(Failure f) : code(f) {}
  void log(llvm::raw_ostream &os) const override { os << failureName(code); }
  std::error_code convertToErrorCode() const override {
    return llvm::inconvertibleErrorCode();
  }
};
inline llvm::Error fail(Failure f) { return llvm::make_error<DomainError>(f); }

// Every fallible arithmetic operation returns Expected. Allocation width is
// widened BEFORE the operation; no i64 or fixed-128-bit intermediate exists.
class Integer {
  llvm::APInt bits;
  explicit Integer(llvm::APInt b) : bits(std::move(b)) {
    bits = bits.sextOrTrunc(std::max(2u, bits.getSignificantBits()));
  }
  static llvm::Expected<unsigned> widthFor(uint64_t w) {
    if (w > 1048576)
      return fail(Failure::WidthLimit);
    return static_cast<unsigned>(std::max<uint64_t>(2, w));
  }

public:
  Integer() : bits(2, 0) {}
  static Integer from(int64_t n) { return Integer(llvm::APInt(64, n, true)); }
  static Integer fromUnsigned(uint64_t n) {
    return Integer(llvm::APInt(65, n));
  }
  static llvm::Expected<Integer> parse(const std::string &s) {
    bool negative = !s.empty() && s[0] == '-';
    auto mag = negative ? s.substr(1) : s;
    if (mag.empty() || mag.find_first_not_of("0123456789") != std::string::npos)
      return fail(Failure::InvalidInteger);
    auto w = widthFor(uint64_t(mag.size()) * 4 + 2);
    if (!w)
      return w.takeError();
    llvm::APInt n(*w, mag, 10);
    return Integer(negative ? -n : n);
  }
  bool negative() const { return bits.isNegative(); }
  bool zero() const { return bits.isZero(); }
  unsigned width() const { return bits.getBitWidth(); }
  std::string str() const {
    llvm::SmallString<40> s;
    bits.toStringSigned(s);
    return std::string(s);
  }
  friend int compare(const Integer &a, const Integer &b) {
    unsigned w = std::max(a.width(), b.width());
    auto x = a.bits.sext(w), y = b.bits.sext(w);
    return x.slt(y) ? -1 : x.sgt(y) ? 1 : 0;
  }
  friend bool operator==(const Integer &a, const Integer &b) {
    return compare(a, b) == 0;
  }
  friend bool operator!=(const Integer &a, const Integer &b) {
    return !(a == b);
  }
  friend bool operator<(const Integer &a, const Integer &b) {
    return compare(a, b) < 0;
  }
  friend bool operator<=(const Integer &a, const Integer &b) {
    return compare(a, b) <= 0;
  }
  static llvm::Expected<Integer> binary(char op, const Integer &a,
                                        const Integer &b) {
    auto w = widthFor(op == '*' ? uint64_t(a.width()) + b.width()
                                : uint64_t(std::max(a.width(), b.width())) + 1);
    if (!w)
      return w.takeError();
    auto x = a.bits.sext(*w), y = b.bits.sext(*w);
    switch (op) {
    case '+':
      return Integer(x + y);
    case '-':
      return Integer(x - y);
    case '*':
      return Integer(x * y);
    default:
      return fail(Failure::UnknownOperation);
    }
  }
  llvm::Expected<Integer> neg() const {
    auto w = widthFor(uint64_t(width()) + 1);
    if (!w)
      return w.takeError();
    return Integer(-bits.sext(*w));
  }
  llvm::Expected<Integer> shl(unsigned n) const {
    auto w = widthFor(uint64_t(width()) + n);
    if (!w)
      return w.takeError();
    return Integer(bits.sext(*w).shl(n));
  }
  static llvm::Expected<Integer> divide(const Integer &a, const Integer &d,
                                        bool floor = true) {
    if (d.zero())
      return fail(Failure::DivisionZero);
    auto w = widthFor(uint64_t(std::max(a.width(), d.width())) + 1);
    if (!w)
      return w.takeError();
    auto x = a.bits.sext(*w), y = d.bits.sext(*w);
    auto q = x.sdiv(y);
    if (floor && x.isNegative() != y.isNegative() && !x.srem(y).isZero())
      q -= 1;
    return Integer(q);
  }
  bool powerOfTwoMagnitude() const {
    // APInt negation of the minimum signed value still encodes its unsigned
    // magnitude, so no precision is lost for this bit-pattern predicate.
    return (negative() ? -bits : bits).isPowerOf2();
  }
  llvm::Expected<Integer> onesThroughTopBit() const {
    if (negative())
      return fail(Failure::NegativeBitBound);
    auto top = from(1).shl(bits.getActiveBits());
    if (!top)
      return top.takeError();
    return binary('-', *top, from(1));
  }
  // Only called after a consumer has proved count in [0,63].
  unsigned shiftCount() const {
    assert(!negative() && bits.getActiveBits() <= 6);
    return bits.getZExtValue();
  }
};

struct Interval {
  Integer lo, hi;
  Interval(Integer l, Integer h) : lo(std::move(l)), hi(std::move(h)) {
    assert(lo <= hi);
  }
  static llvm::Expected<Interval> create(Integer l, Integer h) {
    if (h < l)
      return fail(Failure::EmptyInterval);
    return Interval(l, h);
  }
  static Interval point(Integer n) { return {n, n}; }
  static Interval fullI64() {
    return {Integer::from(INT64_MIN), Integer::from(INT64_MAX)};
  }
  bool nonNeg() const { return !lo.negative(); }
  bool isPoint() const { return lo == hi; }
  bool within(const Interval &b) const { return b.lo <= lo && hi <= b.hi; }
  bool fitsI64() const { return within(fullI64()); }
  bool literal() const {
    return within({Integer::from(INT64_MIN + 1), Integer::from(INT64_MAX)});
  }
  bool operator==(const Interval &b) const { return lo == b.lo && hi == b.hi; }
  std::string str() const { return "[" + lo.str() + ", " + hi.str() + "]"; }
};
inline Interval hull(const Interval &a, const Interval &b) {
  return {std::min(a.lo, b.lo), std::max(a.hi, b.hi)};
}
inline llvm::Expected<Interval> pair(llvm::Expected<Integer> l,
                                     llvm::Expected<Integer> h) {
  if (!l) {
    auto e = l.takeError();
    if (!h)
      llvm::consumeError(h.takeError());
    return std::move(e);
  }
  if (!h)
    return h.takeError();
  return Interval::create(*l, *h);
}
inline llvm::Expected<Interval> add(const Interval &a, const Interval &b) {
  return pair(Integer::binary('+', a.lo, b.lo),
              Integer::binary('+', a.hi, b.hi));
}
inline llvm::Expected<Interval> sub(const Interval &a, const Interval &b) {
  return pair(Integer::binary('-', a.lo, b.hi),
              Integer::binary('-', a.hi, b.lo));
}
inline llvm::Expected<Interval> mul(const Interval &a, const Interval &b) {
  std::vector<Integer> v;
  for (const auto &x : {a.lo, a.hi})
    for (const auto &y : {b.lo, b.hi}) {
      auto p = Integer::binary('*', x, y);
      if (!p)
        return p.takeError();
      v.push_back(*p);
    }
  return Interval(*std::min_element(v.begin(), v.end()),
                  *std::max_element(v.begin(), v.end()));
}
inline llvm::Expected<Interval> neg(const Interval &a) {
  return pair(a.hi.neg(), a.lo.neg());
}
inline llvm::Expected<Interval> bitNot(const Interval &a) {
  auto n = neg(a);
  if (!n)
    return n.takeError();
  return sub(*n, Interval::point(Integer::from(1)));
}
inline llvm::Expected<Interval> bit(const std::string &op, const Interval &a,
                                    const Interval &b) {
  auto z = Integer::from(0);
  if (op == "&") {
    if (a.nonNeg() && b.nonNeg())
      return Interval(z, std::min(a.hi, b.hi));
    if (a.nonNeg())
      return Interval(z, a.hi);
    if (b.nonNeg())
      return Interval(z, b.hi);
  } else if (op == "|" || op == "^") {
    if (a.nonNeg() && b.nonNeg()) {
      auto hi = std::max(a.hi, b.hi).onesThroughTopBit();
      if (!hi)
        return hi.takeError();
      return Interval(z, *hi);
    }
  } else
    return fail(Failure::UnknownOperation);
  return Interval::fullI64();
}
enum class State { Uninitialized, Finite, Overdefined };
class MathInterval {
  State state = State::Uninitialized;
  Interval value = Interval::point(Integer::from(0));

public:
  MathInterval() = default;
  explicit MathInterval(Interval v)
      : state(State::Finite), value(std::move(v)) {}
  static MathInterval unknown() {
    MathInterval r;
    r.state = State::Overdefined;
    return r;
  }
  State getState() const { return state; }
  void print(llvm::raw_ostream &os) const {
    if (state == State::Uninitialized)
      os << "uninitialized";
    else if (state == State::Overdefined)
      os << "overdefined";
    else
      os << value.str();
  }
  // A checked query: callers must handle non-finite states explicitly.
  llvm::Expected<Interval> finite() const {
    if (state != State::Finite)
      return fail(Failure::Nonfinite);
    return value;
  }
  bool operator==(const MathInterval &b) const {
    return state == b.state && (state != State::Finite || value == b.value);
  }
  static MathInterval join(const MathInterval &a, const MathInterval &b) {
    if (a.state == State::Uninitialized)
      return b;
    if (b.state == State::Uninitialized)
      return a;
    if (a.state == State::Overdefined || b.state == State::Overdefined)
      return unknown();
    return MathInterval(hull(a.value, b.value));
  }
};

inline llvm::Expected<Interval> consume(const std::string &op,
                                        const Interval &a, const Integer &d,
                                        bool literal = true,
                                        bool wide = false) {
  auto z = Integer::from(0), one = Integer::from(1);
  if (!literal)
    return fail(Failure::Nonliteral);
  bool shift = op == "shl" || op == "shr";
  if (shift && (d.negative() || Integer::from(63) < d))
    return fail(Failure::ShiftCount);
  if (wide) {
    if (op == "&" && !d.negative())
      return Interval(z, d);
    if (op == "shr" && z < d) {
      auto factor = one.shl(d.shiftCount());
      if (!factor)
        return factor.takeError();
      return pair(z,
                  Integer::divide(Integer::fromUnsigned(UINT64_MAX), *factor));
    }
    return fail(Failure::WideValue);
  }
  llvm::Expected<Interval> result = Interval::point(z);
  if (shift) {
    auto factor = one.shl(d.shiftCount());
    if (!factor)
      return factor.takeError();
    result = op == "shl" ? mul(a, Interval::point(*factor))
                         : pair(Integer::divide(a.lo, *factor),
                                Integer::divide(a.hi, *factor));
  } else if (op == "div" || op == "rem") {
    if (d.zero())
      return fail(Failure::DivisionZero);
    if (a.nonNeg() && !d.negative()) {
      if (op == "div")
        result = pair(Integer::divide(a.lo, d, false),
                      Integer::divide(a.hi, d, false));
      else {
        auto hi = Integer::binary('-', d, one);
        if (!hi)
          return hi.takeError();
        result = Interval(z, std::min(a.hi, *hi));
      }
    } else if (d.powerOfTwoMagnitude()) {
      if (op == "div") {
        auto l = Integer::divide(a.lo, d), h = Integer::divide(a.hi, d);
        if (!l) {
          auto e = l.takeError();
          if (!h)
            llvm::consumeError(h.takeError());
          return std::move(e);
        }
        if (!h)
          return h.takeError();
        result = Interval(std::min(*l, *h), std::max(*l, *h));
      } else if (d.negative())
        result = pair(Integer::binary('+', d, one), z);
      else
        result = pair(z, Integer::binary('-', d, one));
    } else
      return fail(Failure::SignedDivisor);
  } else
    return fail(Failure::UnknownOperation);
  if (!result)
    return result.takeError();
  if (!result->fitsI64())
    return fail(Failure::Overflow);
  return *result;
}

using Environment = std::map<std::string, Interval>;
struct Condition {
  std::string op, left, right;
  Interval leftValue = Interval::point(Integer::from(0)),
           rightValue = leftValue;
  bool eligible = true;
  std::vector<Condition> children;
};
inline llvm::Expected<bool> narrowInto(Environment &env, const Condition &c,
                                       bool positive) {
  if (!c.eligible)
    return true;
  if (c.op == "not") {
    if (c.children.size() != 1)
      return fail(Failure::InvalidCondition);
    return narrowInto(env, c.children[0], !positive);
  }
  if (c.op == "and") {
    if (c.children.size() != 2)
      return fail(Failure::InvalidCondition);
    if (!positive)
      return true;
    auto a = narrowInto(env, c.children[0], true);
    if (!a)
      return a.takeError();
    if (!*a)
      return false;
    return narrowInto(env, c.children[1], true);
  }
  if (c.op == "or")
    return true;
  auto op = c.op;
  if (!positive) {
    static const std::map<std::string, std::string> flip = {
        {"<", ">="}, {"<=", ">"},  {">", "<="},
        {">=", "<"}, {"==", "!="}, {"!=", "=="}};
    auto f = flip.find(op);
    if (f == flip.end())
      return true;
    op = f->second;
  }
  if ((!c.left.empty() && !env.count(c.left)) ||
      (!c.right.empty() && !env.count(c.right)))
    return true;
  if (c.left.empty() && c.right.empty())
    return true;
  auto L = c.left.empty() ? c.leftValue : env.at(c.left),
       R = c.right.empty() ? c.rightValue : env.at(c.right);
  auto ll = L.lo, lh = L.hi, rl = R.lo, rh = R.hi, one = Integer::from(1);
  if (op == "<" || op == ">") {
    auto x =
        Integer::binary(op == "<" ? '-' : '+', op == "<" ? R.hi : R.lo, one);
    if (!x)
      return x.takeError();
    auto y =
        Integer::binary(op == "<" ? '+' : '-', op == "<" ? L.lo : L.hi, one);
    if (!y)
      return y.takeError();
    if (op == "<") {
      lh = std::min(lh, *x);
      rl = std::max(rl, *y);
    } else {
      ll = std::max(ll, *x);
      rh = std::min(rh, *y);
    }
  } else if (op == "<=") {
    lh = std::min(lh, R.hi);
    rl = std::max(rl, L.lo);
  } else if (op == ">=") {
    ll = std::max(ll, R.lo);
    rh = std::min(rh, L.hi);
  } else if (op == "==") {
    ll = rl = std::max(ll, rl);
    lh = rh = std::min(lh, rh);
  } else
    return true;
  if (lh < ll || rh < rl)
    return false;
  if (!c.left.empty())
    env.insert_or_assign(c.left, Interval{ll, lh});
  if (!c.right.empty() && c.right != c.left)
    env.insert_or_assign(c.right, Interval{rl, rh});
  return true;
}
inline llvm::Expected<Environment>
narrow(const Environment &env, const Condition &c, bool positive = true) {
  auto out = env;
  auto ok = narrowInto(out, c, positive);
  if (!ok)
    return ok.takeError();
  return *ok ? out : env;
}
} // namespace spinel::math
