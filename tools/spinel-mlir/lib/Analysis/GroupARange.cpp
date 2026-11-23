#include "spinel/Analysis/GroupARange.h"
namespace spinel::range {
namespace {
using math::Integer;
using math::Interval;
RangeIssue sb14(int64_t node, std::string message) {
  return {node, "SB014", std::move(message)};
}
RangeOutcome rejected(RangeIssue issue) {
  RangeOutcome out;
  out.issue = std::move(issue);
  return out;
}
RangeOutcome accepted(Interval iv, Form form = Form::Computed,
                      std::string mode = {}) {
  return {{math::MathInterval(iv), false, false, form},
          std::nullopt,
          std::move(mode)};
}
llvm::Expected<Interval> numeric(const RangeValue &v) {
  if (v.isBool)
    return math::fail(math::Failure::InvalidTransfer);
  return v.interval.finite();
}
llvm::Expected<Integer> literalOperand(const RangeValue &v) {
  if (v.form != Form::Literal)
    return math::fail(math::Failure::Nonliteral);
  auto range = numeric(v);
  if (!range)
    return range.takeError();
  if (v.wide || !range->isPoint())
    return math::fail(math::Failure::InvalidTransfer);
  return range->lo;
}
RangeIssue overflow(const std::string &op, const Interval &r, Site site) {
  return sb14(site.node,
              "`" + op + "` may overflow: its value range " + r.str() +
                  " does not fit a 64-bit Integer (Ruby grows / Spinel raises "
                  "RangeError, BPF wraps) — narrow the operands (e.g. `x & "
                  "0xFFFF_FFFF`) (P002 §2.1)");
}
llvm::Expected<RangeOutcome> finish(const std::string &op,
                                    llvm::Expected<Interval> r, Site site,
                                    std::string mode = {}) {
  if (!r)
    return r.takeError();
  if (!r->fitsI64())
    return rejected(overflow(op, *r, site));
  return accepted(*r, Form::Computed, mode);
}
llvm::Expected<Interval> typeRange(const MapType &m) {
  if (m.valueBits == 32)
    return m.isSigned
               ? Interval{Integer::from(INT32_MIN), Integer::from(INT32_MAX)}
               : Interval{Integer::from(0), Integer::from(UINT32_MAX)};
  if (m.valueBits == 64)
    return m.isSigned ? Interval::fullI64()
                      : Interval{Integer::from(0), Integer::from(INT64_MAX)};
  return math::fail(math::Failure::InvalidTransfer);
}
bool directWide(Form form) {
  switch (form) {
  case Form::Load:
  case Form::Ktime:
  case Form::PidTgid:
  case Form::Retval:
  case Form::Kparg:
  case Form::Rawarg:
  case Form::Tpfield:
  case Form::Gload:
  case Form::Kfload:
    return true;
  default:
    return false;
  }
}
std::string typeName(const MapType &m) {
  return std::string(m.isSigned ? "i" : "u") + std::to_string(m.valueBits);
}
llvm::Expected<RangeOutcome> requireInteger(const RangeValue &v, Site site) {
  auto diagnostic = checkIntegerUse(v, site);
  if (!diagnostic)
    return diagnostic.takeError();
  if (*diagnostic)
    return rejected(**diagnostic);
  return math::fail(math::Failure::InvalidTransfer); // only called for Wide
}
} // namespace

llvm::Expected<RangeOutcome> literal(Integer v, Site site) {
  if (v == Integer::from(INT64_MIN))
    return rejected(
        sb14(site.node, "integer literal " + v.str() +
                            " is Spinel's nil marker (−2^63) — literals must "
                            "be within [−2^63+1, 2^63−1] (P001 §3.8)"));
  // The source/backend reconciliation and its exact source spelling belong to
  // E010. Values outside the backend's Integer domain are invalid API input.
  auto r = Interval::point(v);
  if (!r.literal())
    return math::fail(math::Failure::InvalidTransfer);
  return accepted(r, Form::Literal);
}

Check checkIntegerUse(const RangeValue &v, Site site) {
  if (v.isBool)
    return math::fail(math::Failure::InvalidTransfer);
  auto iv = numeric(v);
  if (!iv)
    return iv.takeError();
  if (v.wide)
    return std::optional<RangeIssue>(
        sb14(site.node,
             "a u64 value " + iv->str() +
                 " (a u64 map value or BPF.ktime_ns) does not fit Ruby's "
                 "Integer — narrow it first (`x & M` or `x >> K`), or pass it "
                 "straight to a u64 map or record member (P002 §1.4)"));
  return std::optional<RangeIssue>{};
}
llvm::Expected<RangeOutcome> transferUnary(const std::string &op,
                                           const RangeValue &v, Site site) {
  if (v.wide)
    return requireInteger(v, site);
  auto iv = numeric(v);
  if (!iv)
    return iv.takeError();
  if (op == "-@")
    return finish(op, math::neg(*iv), site);
  if (op == "~")
    return finish(op, math::bitNot(*iv), site);
  return math::fail(math::Failure::UnknownOperation);
}
llvm::Expected<RangeOutcome> transferBinary(const std::string &op,
                                            const RangeValue &l,
                                            const RangeValue &r, Site site) {
  auto a = numeric(l);
  if (!a)
    return a.takeError();
  auto b = numeric(r);
  if (!b)
    return b.takeError();
  auto z = Integer::from(0), one = Integer::from(1);
  if (op == "&") {
    if (l.wide) {
      auto mask = literalOperand(r);
      if (!mask)
        return mask.takeError();
      if (mask->negative())
        return rejected(sb14(
            site.rhsNode,
            "a u64 map value may be masked only with a non-negative literal"));
      return accepted(
          Interval{z, *mask}); // Go returns here, before generic fits.
    }
    if (r.wide)
      return rejected(
          sb14(site.node, "write the u64 map value on the left of `&` with a "
                          "literal mask (`p.load & M`)"));
    return finish(op, math::bit(op, *a, *b), site);
  }
  if (op == "|" || op == "^") {
    if (l.wide || r.wide)
      return requireInteger(l.wide ? l : r, site);
    return finish(op, math::bit(op, *a, *b), site);
  }
  if (op == "<<" || op == ">>") {
    if (r.wide)
      return requireInteger(r, site);
    auto count = literalOperand(r);
    if (!count)
      return count.takeError();
    if (count->negative() || Integer::from(63) < *count)
      return rejected(sb14(site.rhsNode,
                           "shift count " + count->str() +
                               " is outside [0, 63] (Ruby shifts the other way "
                               "/ to 0 or −1, BPF is poison) (P002 §2.4)"));
    auto factor = one.shl(count->shiftCount());
    if (!factor)
      return factor.takeError();
    if (l.wide) {
      if (op != ">>" || count->zero())
        return requireInteger(l, site);
      auto hi = Integer::divide(Integer::fromUnsigned(UINT64_MAX), *factor);
      if (!hi)
        return hi.takeError();
      return accepted(Interval{z, *hi});
    }
    return finish(op,
                  op == "<<" ? math::mul(*a, Interval::point(*factor))
                             : math::pair(Integer::divide(a->lo, *factor),
                                          Integer::divide(a->hi, *factor)),
                  site);
  }
  if (l.wide || r.wide)
    return requireInteger(l.wide ? l : r, site);
  if (op == "/" || op == "%") {
    auto d = literalOperand(r);
    if (!d)
      return d.takeError();
    if (d->zero())
      return rejected(
          sb14(site.rhsNode,
               "division by zero (Ruby raises ZeroDivisionError) (P002 §2.3)"));
    if (a->nonNeg() && !d->negative()) {
      if (op == "/")
        return finish(op,
                      math::pair(Integer::divide(a->lo, *d, false),
                                 Integer::divide(a->hi, *d, false)),
                      site, "u");
      auto hi = Integer::binary('-', *d, one);
      if (!hi)
        return hi.takeError();
      return accepted(Interval{z, std::min(a->hi, *hi)}, Form::Computed, "u");
    }
    if (d->powerOfTwoMagnitude()) {
      if (op == "/") {
        auto lo = Integer::divide(a->lo, *d);
        if (!lo)
          return lo.takeError();
        auto hi = Integer::divide(a->hi, *d);
        if (!hi)
          return hi.takeError();
        return finish(op, Interval{std::min(*lo, *hi), std::max(*lo, *hi)},
                      site, "floor");
      }
      auto bound = Integer::binary(d->negative() ? '+' : '-', *d, one);
      if (!bound)
        return bound.takeError();
      return accepted(d->negative() ? Interval{*bound, z} : Interval{z, *bound},
                      Form::Computed, "floor");
    }
    return rejected(sb14(
        site.node, "`" + op + " " + d->str() +
                       "` with a possibly negative dividend " + a->str() +
                       " needs a divisor of ±2^k (Ruby floors; bpf-mlir "
                       "divides i64 signed only by ±2^k — P002 §2.3 (c))"));
  }
  if (op == "+")
    return finish(op, math::add(*a, *b), site);
  if (op == "-")
    return finish(op, math::sub(*a, *b), site);
  if (op == "*")
    return finish(op, math::mul(*a, *b), site);
  return math::fail(math::Failure::UnknownOperation);
}

Check checkArrayKey(const RangeValue &v, const MapType &m, Site site) {
  if (v.isBool || v.wide || m.maxEntries == 0)
    return math::fail(math::Failure::InvalidTransfer);
  auto r = numeric(v);
  if (!r)
    return r.takeError();
  auto high = Integer::fromUnsigned(m.maxEntries - 1);
  if (r->within({Integer::from(0), high}))
    return std::optional<RangeIssue>{};
  if (v.form == Form::Literal) {
    if (!r->isPoint())
      return math::fail(math::Failure::InvalidTransfer);
    if (r->lo.negative() || Integer::from(UINT32_MAX) < r->lo)
      return std::optional<RangeIssue>(
          sb14(site.node, "the key literal " + r->lo.str() +
                              " is outside [0, 4294967295] (u32 on the eBPF "
                              "side; Ruby would not wrap it)"));
  }
  return std::optional<RangeIssue>(
      RangeIssue{site.node, "SB020",
                 "the key's range " + r->str() + " is not within [0, " +
                     high.str() + "] of map " + m.name +
                     " — an out-of-range array update fails silently; narrow "
                     "it (e.g. `k % " +
                     std::to_string(m.maxEntries) + "`, `k & M`) (P002 §1.4)"});
}
Check checkStoreValue(const RangeValue &v, const MapType &m, Site site,
                      const std::string &role) {
  if (v.isBool)
    return math::fail(math::Failure::InvalidTransfer);
  auto r = numeric(v);
  if (!r)
    return r.takeError();
  auto type = typeRange(m);
  if (!type)
    return type.takeError();
  if (v.wide) {
    if (m.valueBits == 64 && !m.isSigned && directWide(v.form))
      return std::optional<RangeIssue>{};
    return checkIntegerUse(v, site);
  }
  if (r->within(*type))
    return std::optional<RangeIssue>{};
  if (v.form == Form::Literal) {
    if (!r->isPoint())
      return math::fail(math::Failure::InvalidTransfer);
    return std::optional<RangeIssue>(
        sb14(site.node, "the " + role + " literal " + r->lo.str() +
                            " is outside " + type->str() + " (" + typeName(m) +
                            " on the eBPF side; Ruby would not wrap it)"));
  }
  return std::optional<RangeIssue>(sb14(
      site.node, "the " + role + "'s range " + r->str() + " does not fit map " +
                     m.name + "'s " + typeName(m) + " values " + type->str() +
                     " — the store would truncate silently; narrow it (e.g. `& "
                     "0xFFFF_FFFF`) (P002 §1.4)"));
}

llvm::Expected<Environment> refineEnvironment(const Environment &env,
                                              const math::Condition &condition,
                                              bool positive) {
  math::Environment numbers;
  for (const auto &entry : env) {
    if (entry.second.wide)
      return math::fail(math::Failure::InvalidTransfer);
    if (!entry.second.isBool) {
      auto iv = entry.second.interval.finite();
      if (!iv)
        return iv.takeError();
      numbers.emplace(entry.first, *iv);
    }
  }
  auto refined = math::narrow(numbers, condition, positive);
  if (!refined)
    return refined.takeError();
  auto out = env;
  for (const auto &entry : *refined)
    out.at(entry.first).interval = math::MathInterval(entry.second);
  return out;
}
llvm::Expected<Environment> joinEnvironment(const Environment &left,
                                            const Environment &right) {
  Environment out;
  for (const auto &entry : left) {
    auto other = right.find(entry.first);
    if (other == right.end() || entry.second.isBool != other->second.isBool)
      continue;
    auto v = entry.second;
    if (v.wide || other->second.wide)
      return math::fail(math::Failure::InvalidTransfer);
    if (!v.isBool) {
      auto a = numeric(v);
      if (!a)
        return a.takeError();
      auto b = numeric(other->second);
      if (!b)
        return b.takeError();
      v.interval = math::MathInterval(math::hull(*a, *b));
    }
    out.emplace(entry.first, asLocal(v));
  }
  return out;
}
RangeValue asLocal(RangeValue v) {
  v.form = Form::Local;
  return v;
}
} // namespace spinel::range
