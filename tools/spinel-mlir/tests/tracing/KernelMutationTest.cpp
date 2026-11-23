#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
using namespace mlir;
using namespace spinel;
using namespace spinel::consumer;

// Mutations live only in this executable's isolated registry. Production code
// has no flag, environment variable, or alternate transfer function.
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  StringRef mode = argv[2];
  bool field = mode == "signed-base" || mode == "signed-unsigned";
  bool argument = mode == "u16-base" || mode == "u16-full-i64";
  bool presence = mode == "presence-base" || mode == "presence-omitted";
  if (!field && !argument && !presence) return 2;
  bool mutant = mode == "signed-unsigned" || mode == "u16-full-i64" ||
                mode == "presence-omitted";
  MLIRContext ctx;
  ctx.loadDialect<ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  auto module = parseSourceFile<ModuleOp>(argv[1], &ctx);
  if (!module) return 2;
  Consumer c(*module);
  c.useIsolatedRegistryForTesting();
  registerConsumerGroups(c.registry);
  std::string observed;
  unsigned hits = 0;
  if (field || argument) {
    for (auto &entry : c.registry.expressions) {
      auto original = entry.second;
      entry.second = [&, original](Consumer &running, Operation *node) {
        auto result = original(running, node);
        if (result.state != Disposition::Handled || hits) return result;
        auto e = *result.value;
        if ((field && e->kind != "gkernel.field") ||
            (argument && e->kind != "gprobe.arg")) return result;
        auto interval = e->range.interval.finite();
        if (!interval) { llvm::consumeError(interval.takeError()); return result; }
        std::string expected = field ? "[-2147483648, 2147483647]" : "[0, 65535]";
        if (interval->str() != expected) return result;
        ++hits;
        auto copy = std::make_shared<ScalarExpr>(*e);
        if (mutant) copy->range.interval = math::MathInterval(field
            ? math::Interval(math::Integer::from(0), math::Integer::from(4294967295LL))
            : math::Interval::fullI64());
        observed = llvm::cantFail(copy->range.interval.finite()).str();
        return Dispatch<Expr>::handled(copy);
      };
    }
  }
  auto lowered = c.run();
  if (field || argument) {
    const std::string expected = field ? "[-2147483648, 2147483647]" : "[0, 65535]";
    const std::string changed = field ? "[0, 4294967295]" : "[-9223372036854775808, 9223372036854775807]";
    if (hits != 1 || observed != (mutant ? changed : expected) ||
        (!mutant && failed(lowered))) return 2;
    llvm::outs() << mode << " expected=" << expected << " observed=" << observed
                 << " range-difference=" << (observed != expected) << '\n';
    return mutant ? 1 : 0;
  }
  if (failed(lowered)) return 2;
  SmallVector<ebpf::KPtrCheckOp> checks;
  module->walk([&](ebpf::KPtrCheckOp op) { checks.push_back(op); });
  if (checks.size() != 1 || checks.front()->getNumResults()) return 2;
  if (mutant) {
    auto check = checks.front();
    auto &yes = check->getRegion(0).front();
    if (yes.getNumArguments() != 1 || !isa<ebpf::YieldOp>(yes.back())) return 2;
    // Deliberately use the nullable value without its conditional presence
    // check. The cast makes the test-only malformed semantic path explicit.
    OpBuilder b(check);
    auto unchecked = UnrealizedConversionCastOp::create(b, check.getLoc(),
        TypeRange{yes.getArgument(0).getType()}, check->getOperands());
    yes.getArgument(0).replaceAllUsesWith(unchecked.getResult(0));
    yes.back().erase();
    check->getBlock()->getOperations().splice(check->getIterator(), yes.getOperations());
    check.erase();
  }
  unsigned remaining = 0, casts = 0;
  module->walk([&](ebpf::KPtrCheckOp) { ++remaining; });
  module->walk([&](UnrealizedConversionCastOp) { ++casts; });
  if (remaining != (mutant ? 0u : 1u) || casts != (mutant ? 1u : 0u)) return 2;
  llvm::outs() << mode << " expected-checks=1 observed-checks=" << remaining
               << " unchecked-casts=" << casts << " structure-difference=" << mutant << '\n';
  return mutant ? 1 : 0;
}
