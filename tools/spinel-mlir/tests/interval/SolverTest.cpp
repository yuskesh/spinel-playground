#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Diagnostics.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Analysis/MathIntervalAnalysis.h"
#include <iostream>
using namespace spinel::math;
using namespace mlir;
int main() {
  MLIRContext context;
  context.allowUnregisteredDialects();
  context.loadDialect<func::FuncDialect, cf::ControlFlowDialect>();
  auto module = parseSourceString<ModuleOp>(R"mlir(
 module {
 func.func private @external() -> i64
 func.func @fixture(%arg: i64) {
  %a = "math_fixture.constant"() {lo="-7",hi="-7",id="a"} : () -> i64
  %b = "math_fixture.constant"() {lo="2",hi="2"} : () -> i64
  %q = "math_fixture.div"(%a,%b) {id="floor"} : (i64,i64) -> i64
  %h = "math_fixture.join"(%a,%b) {id="hull"} : (i64,i64) -> i64
  %s = "math_fixture.add"(%a,%b) {id="sum"} : (i64,i64) -> i64
  %u = "math_fixture.unhandled"(%a) {id="unknown"} : (i64) -> i64
  %v = "math_fixture.add"(%u,%b) {id="top-propagation"} : (i64,i64) -> i64
  %x = func.call @external() {id="external"} : () -> i64
  %entry = "math_fixture.add"(%arg,%b) {id="entry"} : (i64,i64) -> i64
  return
 }
 func.func @cfg(%cond: i1) {
  cf.cond_br %cond, ^left, ^right
 ^left:
  %l = "math_fixture.constant"() {lo="2",hi="2"} : () -> i64
  cf.br ^join(%l : i64)
 ^right:
  %r = "math_fixture.constant"() {lo="8",hi="8"} : () -> i64
  cf.br ^join(%r : i64)
 ^join(%merged: i64):
  %out = "math_fixture.copy"(%merged) {id="cfg-join"} : (i64) -> i64
  return
 }
 })mlir",
                                            &context);
  if (!module)
    return 2;
  unsigned checks = 0, failed = 0;
  auto check = [&](const char *n, bool pass) {
    ++checks;
    std::cout << n << "=" << (pass ? "ok" : "FAIL") << '\n';
    failed += !pass;
  };
  DataFlowSolver solver;
  auto error = runMathIntervalAnalysis(*module, solver);
  if (error) {
    std::cout << "solver-run=" << llvm::toString(std::move(error)) << '\n';
    return 1;
  }
  std::map<std::string, std::string> expected = {
      {"a", "[-7, -7]"},           {"floor", "[-4, -4]"},
      {"hull", "[-7, 2]"},         {"sum", "[-5, -5]"},
      {"unknown", "overdefined"},  {"top-propagation", "overdefined"},
      {"external", "overdefined"}, {"entry", "overdefined"},
      {"cfg-join", "[2, 8]"}};
  module->walk([&](Operation *op) {
    if (auto id = op->getAttrOfType<StringAttr>("id")) {
      auto result = queryMathInterval(solver, op->getResult(0));
      if (!result) {
        std::cout << llvm::toString(result.takeError());
        check(id.getValue().str().c_str(), false);
        return;
      }
      std::string text;
      llvm::raw_string_ostream stream(text);
      result->print(stream);
      check(id.getValue().str().c_str(),
            text == expected.at(id.getValue().str()));
    }
  });
  auto cycle = parseSourceString<ModuleOp>(
      R"mlir(module {func.func @cycle() {cf.br ^loop ^loop: cf.br ^loop}})mlir",
      &context);
  if (!cycle)
    return 2;
  DataFlowSolver cycleSolver;
  auto cycleError = runMathIntervalAnalysis(*cycle, cycleSolver);
  bool cycleRejected = bool(cycleError);
  std::string cycleText =
      cycleError ? llvm::toString(std::move(cycleError)) : "success";
  check("cycle-before-solver",
        cycleRejected && cycleText == "cycle-not-supported");
  auto invalid = parseSourceString<ModuleOp>(
      R"mlir(module {func.func @bad() {%x = "math_fixture.constant"() {lo="bad",hi="1"} : () -> i64 return}})mlir",
      &context);
  if (!invalid)
    return 2;
  DataFlowSolver badSolver;
  auto badError = runMathIntervalAnalysis(*invalid, badSolver);
  std::string badText =
      badError ? llvm::toString(std::move(badError)) : "success";
  check("invalid-transfer-loud", badText == "invalid-integer");
  Value first;
  module->walk([&](Operation *op) {
    if (!first && op->getNumResults())
      first = op->getResult(0);
  });
  DataFlowSolver unloaded;
  auto missing = queryMathInterval(unloaded, first);
  check("missing-query-loud", !missing);
  if (!missing)
    llvm::consumeError(missing.takeError());
  std::cout << "solver-checks=" << checks << " failures=" << failed << '\n';
  return failed ? 1 : 0;
}
