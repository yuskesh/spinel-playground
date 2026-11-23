#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include <cstdlib>
#include <unistd.h>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok, const char *label) {
  if (!ok) { llvm::errs() << "FAIL " << label << '\n'; std::exit(1); }
}
int main(int argc, char **argv) {
  require(argc == 2, "fixture argument");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  enum Mode { Normal, Empty, TrailingIf, TrailingMap, CallbackFailure, CallbackBlocking, BodyFailure };
  for (auto mode : {Normal, Empty, TrailingIf, TrailingMap, CallbackFailure, CallbackBlocking, BodyFailure}) {
    const char *names[] = {"Normal", "Empty", "TrailingIf", "TrailingMap", "CallbackFailure", "CallbackBlocking", "BodyFailure"};
    llvm::outs() << "mode=" << names[mode] << '\n';
    llvm::outs().flush();
    auto module = parseSourceFile<ModuleOp>(argv[1], &ctx);
    require(bool(module), "parse handwritten fixture");
    // Mutate a test fixture before constructing Consumer, never during run.
    module->walk([&](Operation *op) {
      if (op->getName().getStringRef() != "spinel_facts.node") return;
      if (mode == BodyFailure && op->getAttrOfType<IntegerAttr>("id").getInt() == 16) {
        op->setAttr("arrays", DictionaryAttr::get(&ctx, {NamedAttribute(StringAttr::get(&ctx,"arguments"), ArrayAttr::get(&ctx, {}))}));
      }
      if (op->getAttrOfType<IntegerAttr>("id").getInt() != 13) return;
      auto attrs = op->getAttrOfType<DictionaryAttr>("arrays");
      auto old = attrs.getAs<ArrayAttr>("body");
      SmallVector<Attribute> body(old.begin(), old.end());
      if (mode == Empty) body.clear();
      if (mode == TrailingIf) body.pop_back();
      if (mode == TrailingMap) body.resize(1);
      op->setAttr("arrays", DictionaryAttr::get(&ctx, {NamedAttribute(StringAttr::get(&ctx,"body"), ArrayAttr::get(&ctx, body))}));
    });
    Consumer c(*module);
    c.useIsolatedRegistryForTesting();
    int calls = 0;
    if (mode != Normal) {
      c.registry.addRoot("xdp", [&](Consumer &, Operation *) {
        ProgramDecl p;
        p.finalizeBody = [&](Consumer &running) -> LogicalResult {
          ++calls;
          if (mode == CallbackFailure) return failure();
          if (mode == CallbackBlocking) { running.blocking = true; return success(); }
          auto *block = running.builder.getInsertionBlock();
          require(block && running.builder.getInsertionPoint() == block->end(), "program-end insertion point");
          if (block->empty() || !block->back().hasTrait<OpTrait::IsTerminator>())
            ebpf::VerdictOp::create(running.builder, outputLoc(running.activeDef), "pass");
          return success();
        };
        return Dispatch<ProgramDecl>::handled(std::move(p));
      });
    }
    int capture[2] = {-1, -1}, saved = -1;
    if (mode == BodyFailure) {
      require(pipe(capture) == 0, "diagnostic pipe");
      llvm::errs().flush();
      saved = dup(STDERR_FILENO);
      require(saved >= 0 && dup2(capture[1], STDERR_FILENO) >= 0, "redirect diagnostic");
      close(capture[1]);
    }
    auto result = c.run();
    if (mode == BodyFailure) {
      llvm::errs().flush();
      require(dup2(saved, STDERR_FILENO) >= 0, "restore stderr");
      close(saved);
      char buffer[4096];
      auto length = read(capture[0], buffer, sizeof(buffer));
      close(capture[0]);
      std::string diagnostic = length > 0 ? std::string(buffer, length) : "";
      require(diagnostic == "xdpcount.rb:6:3: rejected SB001 (UnsupportedConstruct): atomic_add requires two arguments\n", "named body shape diagnostic");
      llvm::outs() << diagnostic;
    }
    bool reject = mode == CallbackFailure || mode == CallbackBlocking || mode == BodyFailure;
    require(succeeded(result) != reject, "result / artifact availability");
    require(calls == ((mode == Normal || mode == BodyFailure) ? 0 : 1), "exact callback count");
    if (!reject) require(!result->schema.empty() && !result->maps.empty(), "successful artifacts nonempty");
  }
  llvm::outs() << "finalizer: seven modes, call counts and artifact boundaries passed\n";
}
