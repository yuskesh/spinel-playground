#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace spinel::consumer;
using namespace mlir;
void registerSeparateTU(Registry &, int &);
static void require(bool ok, const char *name) {
  if (!ok) {
    llvm::errs() << "FAIL " << name << "\n";
    std::exit(1);
  }
}
int main(int argc, char **argv) {
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = ModuleOp::create(UnknownLoc::get(&context));
  Consumer consumer(module);
  require(!consumer.registry.roots.empty(), "production roots registered");
  consumer.useIsolatedRegistryForTesting();
  require(consumer.registry.roots.empty(), "isolated registry has no production roots");
  int calls = 0, fallback = 0;
  registerSeparateTU(consumer.registry, calls);
  auto result = consumer.dispatchExpression("Test", module);
  require(result.state == Disposition::Handled && result.value && calls == 1,
          "separate TU handles once");
  require(consumer.dispatchExpression("Absent", module).state ==
                  Disposition::Declined &&
              calls == 1,
          "absent declines");
  consumer.registry.addExpression(
      "Stop", [](Consumer &, Operation *) { return Dispatch<Expr>::error(); });
  consumer.registry.addExpression("Stop", [&](Consumer &, Operation *) {
    ++fallback;
    return Dispatch<Expr>::declined();
  });
  require(consumer.dispatchExpression("Stop", module).state ==
                  Disposition::Error &&
              fallback == 0,
          "error never falls back");
  consumer.blocking = false; // Start an independent dispatch scenario.
  consumer.registry.addExpression("Invalid", [](Consumer &, Operation *) {
    return Dispatch<Expr>{Disposition::Handled, std::nullopt};
  });
  require(consumer.dispatchExpression("Invalid", module).state ==
              Disposition::Error,
          "handled requires result");
  consumer.blocking = false;
  auto expr = std::make_shared<ScalarExpr>();
  expr->name = "before";
  consumer.locals["x"] = {expr, {}};
  {
    ScopeGuard scope(consumer);
    auto copy = std::make_shared<ScalarExpr>(*consumer.locals["x"].expr);
    copy->name = "inside";
    consumer.locals["x"].expr = copy;
    consumer.borrows["temporary"] = {};
    consumer.frames.push_back({});
  }
  require(consumer.locals.at("x").expr->name == "before" &&
              consumer.borrows.empty() && consumer.frames.empty(),
          "scope COW restoration");
  consumer.registry.addStatement(
      "Bad", [](Consumer &, llvm::ArrayRef<Operation *>, size_t, unsigned) {
        return Dispatch<StatementResult>::handled({0});
      });
  consumer.registry.addStatement(
      "TooMany",
      [](Consumer &c, llvm::ArrayRef<Operation *>, size_t, unsigned) {
        c.borrows["invalid-statement"] = {};
        return Dispatch<StatementResult>::handled({2});
      });
  Operation *one[] = {module};
  require(consumer.dispatchStatement("Bad", one, 0, 0).state ==
              Disposition::Error,
          "zero consumed rejected");
  consumer.blocking = false;
  require(consumer.dispatchStatement("TooMany", one, 0, 0).state ==
              Disposition::Error,
          "out of bounds consumed rejected");
  require(!consumer.borrows.count("invalid-statement"),
          "invalid consumed count rolls back scope before commit");
  int checks = 0;
  consumer.bodyTransfer =
      [&](Consumer &,
          const BodyRequest &request) -> llvm::Expected<BodyResult> {
    BodyResult out;
    if (request.mode == CheckMode::Check) {
      ++checks;
      out.checked = std::make_shared<CheckedBody>();
    }
    return out;
  };
  BodyRequest request;
  auto probe = consumer.transferBody(request);
  require(bool(probe) && !probe->checked && checks == 0,
          "probe does not publish");
  request.mode = CheckMode::Check;
  auto checked = consumer.transferBody(request);
  require(bool(checked) && checked->checked && checks == 1,
          "check owns payload once");
  consumer.bodyTransfer =
      [](Consumer &c, const BodyRequest &) -> llvm::Expected<BodyResult> {
    c.builder.setInsertionPointToEnd(c.input.getBody());
    arith::ConstantIntOp::create(c.builder, c.builder.getUnknownLoc(), 1, 64);
    return BodyResult{};
  };
  request.mode = CheckMode::Probe;
  auto invalidProbe = consumer.transferBody(request);
  require(!invalidProbe && module.getBody()->empty(),
          "probe IR rejected and rolled back");
  llvm::consumeError(invalidProbe.takeError());
  consumer.bodyTransfer =
      [](Consumer &c, const BodyRequest &) -> llvm::Expected<BodyResult> {
    (void)c.diagnostic(nullptr, "SB020", "KeyOutOfRange", "test");
    return BodyResult{};
  };
  auto diagnosticProbe = consumer.transferBody(request);
  require(!diagnosticProbe, "probe diagnostic not published");
  llvm::consumeError(diagnosticProbe.takeError());
  require(consumer.registry.addEmitter("unique",
                                       [](Consumer &, const Expr &) {
                                         return Dispatch<Value>::declined();
                                       }),
          "first emitter registration");
  require(!consumer.registry.addEmitter("unique",
                                        [](Consumer &, const Expr &) {
                                          return Dispatch<Value>::declined();
                                        }) &&
              !consumer.registry.valid,
          "duplicate emitter rejected");
  module.erase();
  if (argc >= 2) {
    auto input = parseSourceFile<ModuleOp>(argv[1], &context);
    require(bool(input), "parse real producer facts");
    OwningOpRef<ModuleOp> copy(cast<ModuleOp>(input->clone()));
    Consumer baseline(*input), hooked(*copy);
    baseline.useIsolatedRegistryForTesting();
    hooked.useIsolatedRegistryForTesting();
    int expressions = 0, statements = 0, declarations = 0, keys = 0, roots = 0,
        exports = 0;
    hooked.registry.addExpression("CallNode", [&](Consumer &, Operation *) {
      ++expressions;
      return Dispatch<Expr>::declined();
    });
    hooked.registry.addStatement(
        "LocalVariableWriteNode",
        [&](Consumer &, llvm::ArrayRef<Operation *>, size_t, unsigned) {
          ++statements;
          return Dispatch<StatementResult>::declined();
        });
    hooked.registry.addDeclaration({"BPF::ArrayMap", "new"},
                                   [&](Consumer &, Operation *) {
                                     ++declarations;
                                     return Dispatch<bool>::declined();
                                   });
    hooked.registry.addRoot("xdp", [&](Consumer &, Operation *) {
           ++roots;
           return Dispatch<ProgramDecl>::declined();
         });
    hooked.registry.addMapKey(
        "array",
        [&](Consumer &, size_t, llvm::ArrayRef<Operation *>, Operation *) {
          ++keys;
          return Dispatch<Expr>::declined();
        });
    hooked.registry.addMapExporter("array", [&](Consumer &, size_t, bool) {
      ++exports;
      return Dispatch<ExportFields>::declined();
    });
    auto a = baseline.run(), b = hooked.run();
    require(succeeded(a) && succeeded(b),
            "real pipeline succeeds with declined handlers");
    std::string x, y;
    llvm::raw_string_ostream xs(x), ys(y);
    input->print(xs, OpPrintingFlags().enableDebugInfo());
    copy->print(ys, OpPrintingFlags().enableDebugInfo());
    require(a->schema == b->schema && a->maps == b->maps && x == y,
            "declined handlers preserve pipeline bytes");
    llvm::outs() << "consumer hook counters: expressions=" << expressions
                 << " statements=" << statements
                 << " declarations=" << declarations << " keys=" << keys
                 << " roots=" << roots << " exports=" << exports << "\n";
    require(expressions && statements && declarations && keys && roots == 1 &&
                exports,
            "real pipeline reaches registered connections");
    auto errorInput = parseSourceFile<ModuleOp>(argv[1], &context);
    Consumer stopped(*errorInput);
    stopped.useIsolatedRegistryForTesting();
    int failedEmits = 0;
    stopped.registry.addEmitter("literal", [&](Consumer &c, const Expr &expr) {
      ++failedEmits;
      (void)c.error(expr->node, "test handler blocks emission");
      return Dispatch<Value>::error();
    });
    require(
        failed(stopped.run()) && failedEmits == 1,
        "emitter error stops real pipeline without null operands or fallback");
  }
  if (argc == 3) {
    auto input = parseSourceFile<ModuleOp>(argv[2], &context);
    require(bool(input), "parse saved predicate facts");
    Consumer observed(*input);
    std::map<int64_t, unsigned> counts;
    std::set<std::string> kinds;
    for (const auto &entry : observed.nodes) {
      auto node = entry.second;
      if (text(node,"kind") != "IfNode" && text(node,"kind") != "UnlessNode") continue;
      auto parent = observed.parent(node);
      while (parent && text(parent,"kind") != "DefNode") parent = observed.parent(parent);
      if (!parent || field(parent,"strings","name") != "prog") continue;
      auto predicate = observed.ref(node,"predicate");
      if (!predicate || text(predicate,"kind") == "LocalVariableReadNode") continue;
      counts.emplace(observed.id(predicate),0);
      kinds.insert(text(predicate,"kind").str());
    }
    require(!counts.empty(), "saved facts contain ordinary predicates");
    Registry fresh;
    for (const auto &kind : kinds) fresh.addExpression(kind, [&](Consumer &c, Operation *node) {
      auto found = counts.find(c.id(node));
      if (found != counts.end()) ++found->second;
      return Dispatch<Expr>::declined();
    });
    registerConsumerGroups(fresh);
    observed.useIsolatedRegistryForTesting(std::move(fresh));
    require(succeeded(observed.run()), "observed saved predicate pipeline succeeds");
    for (const auto &[id,count] : counts) {
      llvm::outs() << "predicate dispatch node=" << id << " count=" << count << "\n";
      require(count == 1, "checked predicate dispatches exactly once");
    }
  }
  llvm::outs() << "consumer hooks GREEN\n";
}
