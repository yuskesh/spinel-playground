#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/raw_ostream.h"
using namespace spinel::consumer;
using namespace mlir;
int main() {
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect>();
  OpBuilder builder(&context);
  auto module = ModuleOp::create(builder.getUnknownLoc());
  OperationState readState(FileLineColLoc::get(&context, "rmw-domain.rb", 3, 5),
                           "spinel_facts.node");
  readState.addAttribute("kind", builder.getStringAttr("LocalVariableReadNode"));
  readState.addAttribute("strings", builder.getDictionaryAttr({
      builder.getNamedAttr("name", builder.getStringAttr("v"))}));
  auto *read = Operation::create(readState);
  module.getBody()->push_back(read);
  OperationState keyState(read->getLoc(), "spinel_facts.node");
  keyState.addAttribute("kind", builder.getStringAttr("IntegerNode"));
  keyState.addAttribute("literal_decimal", builder.getStringAttr("1"));
  auto *key = Operation::create(keyState);
  module.getBody()->push_back(key);
  Consumer consumer(module);
  consumer.programName = "prog";
  MapDecl map{}; map.name = "M"; map.entries = 4;
  consumer.maps.push_back(map);
  struct Case { const char *name; ReadOrigin::Domain domain; size_t index;
                bool distinctLiteral, expectedSuccess; };
  Case cases[] = {
    {"Map0-to-Map0", ReadOrigin::Domain::Map, 0, false, false},
    {"Global0-to-Map0", ReadOrigin::Domain::Global, 0, false, true},
    {"Map1-to-Map0", ReadOrigin::Domain::Map, 1, false, true},
    {"Map0-distinct-literal", ReadOrigin::Domain::Map, 0, true, true},
  };
  unsigned failures = 0;
  for (const auto &test : cases) {
    auto expr = std::make_shared<ScalarExpr>();
    expr->reads.push_back({test.index, int64_t(0), "p", test.domain});
    consumer.locals["v"] = {expr, {}};
    consumer.blocking = false;
    bool ok = succeeded(consumer.rmwFirst(read, test.distinctLiteral ? key : nullptr,
                                         read, 0, false));
    llvm::outs() << test.name << " success=" << ok
                 << " expected=" << test.expectedSuccess << "\n";
    failures += ok != test.expectedSuccess;
  }
  module.erase();
  llvm::outs() << "rmw-domain cases=4 failures=" << failures << "\n";
  return failures ? 1 : 0;
}
