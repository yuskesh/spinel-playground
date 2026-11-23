#pragma once
#include "spinel/Analysis/MathInterval.h"
namespace spinel::math::test {
inline Integer integer(const std::string &s) {
  return llvm::cantFail(Integer::parse(s));
}
inline std::string printed(llvm::Expected<Interval> r) {
  return r ? r->str() : "reject:" + llvm::toString(r.takeError());
}
inline std::string evaluate(const std::string &op, const std::string &al,
                            const std::string &ah, const std::string &bl,
                            const std::string &bh, const std::string &arg) {
  Interval a{integer(al), integer(ah)}, b{integer(bl), integer(bh)};
  if (op == "add")
    return printed(add(a, b));
  if (op == "sub")
    return printed(sub(a, b));
  if (op == "mul")
    return printed(mul(a, b));
  if (op == "join")
    return hull(a, b).str();
  if (op == "neg")
    return printed(neg(a));
  if (op == "not")
    return printed(bitNot(a));
  if (op == "&" || op == "|" || op == "^")
    return printed(bit(op, a, b));
  auto boolean = [](bool x) { return x ? "true" : "false"; };
  if (op == "fits")
    return boolean(a.fitsI64());
  if (op == "literal")
    return boolean(a.literal());
  if (op == "point")
    return boolean(a.isPoint());
  if (op == "floor")
    return llvm::cantFail(Integer::divide(a.lo, integer(arg))).str();
  if (op == "narrow") {
    auto colon = arg.find(':');
    auto cmp = [&](std::string code, std::string n) {
      Condition c;
      c.op = code;
      c.left = "x";
      c.rightValue = Interval::point(integer(n));
      return c;
    };
    Condition c = cmp(arg.substr(0, colon), arg.substr(colon + 1));
    if (c.op == "and") {
      c.children = {cmp("<", "2"), cmp(">", "4")};
    }
    return llvm::cantFail(narrow({{"x", a}}, c)).at("x").str();
  }
  return printed(consume(op, a, integer(arg)));
}
} // namespace spinel::math::test
