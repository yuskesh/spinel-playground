#include "spinel/Analysis/GroupARange.h"
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
using namespace spinel;
using namespace spinel::range;
static math::Integer number(const std::string &s) {
  return llvm::cantFail(math::Integer::parse(s));
}
static RangeValue value(const std::string &lo, const std::string &hi,
                        Form form = Form::Computed, bool wide = false) {
  return {math::MathInterval(math::Interval{number(lo), number(hi)}), false,
          wide, form};
}
static std::optional<RangeIssue> issue(llvm::Expected<RangeOutcome> out) {
  if (!out) {
    llvm::errs() << llvm::toString(out.takeError()) << '\n';
    return std::nullopt;
  }
  return out->issue;
}
static std::optional<RangeIssue> issue(Check out) {
  if (!out) {
    llvm::errs() << llvm::toString(out.takeError()) << '\n';
    return std::nullopt;
  }
  return *out;
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  std::ifstream input(argv[1]);
  if (!input)
    return 2;
  unsigned checks = 0, failed = 0;
  auto check = [&](std::string n, bool ok) {
    ++checks;
    if (!ok) {
      ++failed;
      std::cerr << n << " failed\n";
    }
  };
  // E146: checking the arithmetic of a raw signed pointer value precedes keys.
  auto ptrPlusOne = transferBinary("+",
      value("-9223372036854775808", "9223372036854775807", Form::Kparg),
      value("1", "1", Form::Literal), Site{67, 68});
  check("ptr-plus-one-overflow-before-array-key",
      ptrPlusOne && ptrPlusOne->issue && ptrPlusOne->issue->code == "SB014" &&
      ptrPlusOne->issue->message.find(
          "[-9223372036854775807, 9223372036854775808]") != std::string::npos);
  if (!ptrPlusOne) llvm::consumeError(ptrPlusOne.takeError());
  std::string line;
  std::set<std::string> oracleNames;
  while (std::getline(input, line)) {
    std::stringstream row(line);
    std::vector<std::string> fields;
    std::string cell;
    while (std::getline(row, cell, '\t'))
      fields.push_back(cell);
    if (fields.size() != 7)
      return 2;
    auto name = fields[0];
    if (!oracleNames.insert(name).second)
      return 2;
    std::optional<RangeIssue> actual;
    if (name == "key_2p32")
      actual =
          issue(checkArrayKey(value("4294967296", "4294967296", Form::Literal),
                              {"Counts", 64, false, 2}, {10, 20}));
    if (name == "value32_2p32")
      actual = issue(
          checkStoreValue(value("4294967296", "4294967296", Form::Literal),
                          {"B", 32, false, 2}, {10, 20}, "delta"));
    if (name == "op_plus")
      actual = issue(transferBinary(
          "+",
          value("9223372036854775807", "9223372036854775807", Form::Literal),
          value("1", "1", Form::Literal), {10, 20}));
    if (name == "rmw_distinct_keys_overflow")
      actual = issue(checkIntegerUse(
          value("0", "18446744073709551615", Form::Load, true), {10, 20}));
    if (name == "p2_key_range")
      actual = issue(checkArrayKey(value("4", "4", Form::Literal),
                                   {"U", 32, false, 4}, {10, 20}));
    check(name, actual && actual->node == 10 && actual->code == fields[1] &&
                    actual->message == fields[2]);
  }
  check("oracle-five-nonempty", oracleNames.size() == 5);
  RangeValue x = value("-10", "20", Form::Local);
  Environment env{{"x", x}};
  math::Condition nonneg;
  nonneg.op = ">=";
  nonneg.left = "x";
  nonneg.rightValue = math::Interval::point(number("0"));
  math::Condition limit;
  limit.op = "<";
  limit.left = "x";
  limit.rightValue = math::Interval::point(number("4"));
  math::Condition both;
  both.op = "and";
  both.children = {nonneg, limit};
  auto refined = refineEnvironment(env, both);
  check("refinement-success", bool(refined));
  if (refined) {
    auto key = checkArrayKey(refined->at("x"), {"A", 32, false, 4}, {10, 20});
    check("refined-key", key && !key->has_value());
    if (!key)
      llvm::consumeError(key.takeError());
  } else
    llvm::consumeError(refined.takeError());
  auto raw = checkArrayKey(x, {"A", 32, false, 4}, {10, 20});
  check("unrefined-key-reject",
        raw && raw->has_value() && (**raw).code == "SB020");
  if (!raw)
    llvm::consumeError(raw.takeError());
  auto local = asLocal(value("3", "3", Form::Literal));
  check("point-not-literal", local.form == Form::Local);
  auto copy =
      checkStoreValue(value("0", "18446744073709551615", Form::Load, true),
                      {"A", 64, false, 1}, {10, 20});
  check("wide-copy-u64", copy && !copy->has_value());
  if (!copy)
    llvm::consumeError(copy.takeError());
  auto unrelated =
      joinEnvironment({{"x", value("0", "2")}, {"leftOnly", value("1", "1")}},
                      {{"x", value("3", "5")}});
  check("join-common-only", unrelated && unrelated->size() == 1);
  if (!unrelated)
    llvm::consumeError(unrelated.takeError());
  auto computed = transferBinary("/", value("-7", "7"),
                                 value("2", "2", Form::Literal), {10, 20});
  check("floor-mode",
        computed && !computed->issue && computed->divMode == "floor" &&
            llvm::cantFail(computed->value.interval.finite()).str() ==
                "[-4, 3]");
  if (!computed)
    llvm::consumeError(computed.takeError());
  auto unsignedMode = transferBinary("%", value("0", "2"),
                                     value("7", "7", Form::Literal), {10, 20});
  check("unsigned-mode",
        unsignedMode && !unsignedMode->issue && unsignedMode->divMode == "u" &&
            llvm::cantFail(unsignedMode->value.interval.finite()).str() ==
                "[0, 2]");
  if (!unsignedMode)
    llvm::consumeError(unsignedMode.takeError());
  auto shift = transferBinary("<<", value("0", "1"),
                              value("64", "64", Form::Literal), {10, 20});
  check("shift-rhs-location",
        shift && shift->issue && shift->issue->node == 20 &&
            shift->issue->message.find("shift count 64") != std::string::npos);
  if (!shift)
    llvm::consumeError(shift.takeError());
  auto zero = transferBinary("/", value("1", "1"),
                             value("0", "0", Form::Literal), {10, 20});
  check("zero-rhs-location",
        zero && zero->issue && zero->issue->node == 20 &&
            zero->issue->message ==
                "division by zero (Ruby raises ZeroDivisionError) (P002 §2.3)");
  if (!zero)
    llvm::consumeError(zero.takeError());
  auto notLiteral = transferBinary(
      "/", value("1", "1"), asLocal(value("2", "2", Form::Literal)), {10, 20});
  check("point-does-not-imply-literal", !notLiteral);
  if (!notLiteral)
    llvm::consumeError(notLiteral.takeError());
  auto minLiteral = literal(number("-9223372036854775808"), {10, 20});
  check("min-literal-refused",
        minLiteral && minLiteral->issue && minLiteral->issue->code == "SB014");
  if (!minLiteral)
    llvm::consumeError(minLiteral.takeError());
  auto minNeg = transferUnary(
      "-@", value("-9223372036854775808", "-9223372036854775808"), {10, 20});
  check("unary-overflow",
        minNeg && minNeg->issue &&
            minNeg->issue->message.find(
                "[9223372036854775808, 9223372036854775808]") !=
                std::string::npos);
  if (!minNeg)
    llvm::consumeError(minNeg.takeError());
  auto mask =
      transferBinary("&", value("0", "18446744073709551615", Form::Load, true),
                     value("255", "255", Form::Literal), {10, 20});
  check("wide-mask",
        mask && !mask->issue && !mask->value.wide &&
            llvm::cantFail(mask->value.interval.finite()).str() == "[0, 255]");
  if (!mask)
    llvm::consumeError(mask.takeError());
  auto minusMask =
      transferBinary("&", value("0", "18446744073709551615", Form::Load, true),
                     value("-1", "-1", Form::Literal), {10, 20});
  check("wide-negative-mask-location",
        minusMask && minusMask->issue && minusMask->issue->node == 20);
  if (!minusMask)
    llvm::consumeError(minusMask.takeError());
  auto manufactured =
      checkStoreValue(value("0", "18446744073709551615", Form::Computed, true),
                      {"A", 64, false, 1}, {10, 20});
  check("wide-form-gate", manufactured && manufactured->has_value());
  if (!manufactured)
    llvm::consumeError(manufactured.takeError());
  RangeValue boolean;
  boolean.isBool = true;
  auto boolKey = checkArrayKey(boolean, {"A", 32, false, 4}, {10, 20});
  check("bool-caller-shape-required", !boolKey);
  if (!boolKey)
    llvm::consumeError(boolKey.takeError());
  auto absent = checkIntegerUse(RangeValue{}, {10, 20});
  check("missing-evidence-blocks", !absent);
  if (!absent)
    llvm::consumeError(absent.takeError());
  math::Condition empty;
  empty.op = ">";
  empty.left = "x";
  empty.rightValue = math::Interval::point(number("30"));
  math::Condition contradiction;
  contradiction.op = "and";
  contradiction.children = {nonneg, empty};
  auto rolled = refineEnvironment(env, contradiction);
  check("whole-and-rollback",
        rolled && llvm::cantFail(rolled->at("x").interval.finite()) ==
                      llvm::cantFail(x.interval.finite()));
  if (!rolled)
    llvm::consumeError(rolled.takeError());
  auto boolMismatch = joinEnvironment({{"x", boolean}}, {{"x", x}});
  check("bool-kind-join", boolMismatch && boolMismatch->empty());
  if (!boolMismatch)
    llvm::consumeError(boolMismatch.takeError());
  std::cout << "range-checks=" << checks << " failures=" << failed << '\n';
  return failed ? 1 : 0;
}
