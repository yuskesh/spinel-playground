#include "spinel/Conversion/Consumer.h"
using namespace spinel::consumer;
void registerSeparateTU(Registry &registry, int &calls) {
  registry.addExpression("Test", [&calls](Consumer &, mlir::Operation *) {
    ++calls;
    return Dispatch<Expr>::handled(std::make_shared<ScalarExpr>());
  });
}
