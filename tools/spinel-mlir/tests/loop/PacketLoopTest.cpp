#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/PacketLoop.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
namespace math = spinel::math;
static void require(bool ok,const char *name) {
  if(!ok){llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
int main(int argc,char **argv) {
  require(argc==2,"facts-path");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);require(bool(input),"parse");
  Consumer c(*input);
  require(bool(c.registry.packetLoop),"packet-loop-capability");
  auto hooks=c.registry.packetLoop;
  require(bool(hooks->check)&&bool(hooks->enterCheck)&&bool(hooks->emit),"packet-loop-three-operations");
  Operation *binding=nullptr;
  for(auto &[id,n]:c.nodes)
    if(text(n,"kind")=="LocalVariableWriteNode"){binding=n;break;}
  require(binding!=nullptr,"fixture-binding");
  PacketLoopWindow descriptor;
  descriptor.binding=binding;descriptor.branch=binding;descriptor.name="scope_probe";
  descriptor.length=2;descriptor.offset=std::make_shared<ScalarExpr>();
  auto original=ScopeBinding{input->getOperation(),input->getOperation(),{}};
  c.bindings["packet:scope_probe"]=original;
  auto beforeExpr=std::make_shared<ScalarExpr>();beforeExpr->name="before";
  c.locals["probe_value"]={beforeExpr,{}};
  c.maps.push_back(MapDecl{});c.globals.push_back(GlobalDecl{});
  c.records.push_back(RecordDecl{});
  c.bodyTransfer=[&](Consumer &,const BodyRequest &)->llvm::Expected<BodyResult> {
    require(c.probing,"probe-mode");

    auto scope=hooks->enterCheck(c,descriptor);
    require(bool(scope)&&bool(*scope),"packet-scope-nonnull");
    auto b=c.bindings.find("packet:scope_probe");
    require(b!=c.bindings.end()&&b->second.source==binding&&!b->second.value,
            "then-empty-SSA-binding");
    c.bindings["temporary"]={binding,binding,{}};
    scope->reset();
    require(c.bindings.size()==1&&c.bindings.at("packet:scope_probe").source==original.source,
            "probe-state-rollback");
    c.locals["probe_value"].expr=std::make_shared<ScalarExpr>(*beforeExpr);
    c.locals["probe_value"].expr->name="changed";
    c.maps[0].used=true;c.globals[0].used=true;c.records[0].used=true;
    c.usedMap=true;c.frames.push_back({});c.borrows["temporary"]={};
    return BodyResult{};
  };
  auto transferred=c.transferBody({binding,{},math::Interval::point(math::Integer::from(0)),CheckMode::Probe});
  require(bool(transferred)&&!transferred->checked&&transferred->issues.empty(),
          "probe-body-has-no-publication");
  require(c.locals.at("probe_value").expr==beforeExpr&&beforeExpr->name=="before"&&
          !c.maps[0].used&&!c.globals[0].used&&!c.records[0].used&&!c.usedMap&&
          c.frames.empty()&&c.borrows.empty()&&!c.probing,"probe-consumer-COW-restore");
  auto invalid=hooks->enterCheck(c,PacketLoopWindow{});
  require(!invalid,"invalid-descriptor-error");
  llvm::consumeError(invalid.takeError());
  Operation *nodes[]={input->getOperation()};
  auto before=c.bindings;
  auto result=hooks->check(c,nodes,0,0);
  require(result.state==Disposition::Declined&&c.bindings.size()==before.size()&&!c.blocking,
          "declined-has-no-effects");
  Block emitted;
  c.contextValue=emitted.addArgument(ebpf::ContextType::get(&ctx,"xdp"),c.builder.getUnknownLoc());
  c.builder.setInsertionPointToEnd(&emitted);
  auto integer=[&](int64_t n) {
    auto e=std::make_shared<ScalarExpr>();e->node=binding;e->kind="literal";e->literal=n;
    e->range.interval=math::MathInterval(math::Interval::point(math::Integer::from(n)));
    return e;
  };
  descriptor.offset=integer(0);
  c.locals.clear();
  c.locals["joined"]={integer(0),arith::ConstantIntOp::create(c.builder,outputLoc(binding),0,64)};
  unsigned thenCalls=0,elseCalls=0;
  auto resultEmit=hooks->emit(c,descriptor,[&]{
    ++thenCalls;
    require(bool(c.bindings.at("packet:scope_probe").value),"emit-then-has-SSA");
    c.locals["joined"]={integer(2),arith::ConstantIntOp::create(c.builder,outputLoc(binding),2,64)};
    return success();
  },[&]{
    ++elseCalls;
    require(c.bindings.at("packet:scope_probe").source==original.source,"else-restored-binding");
    c.locals["joined"]={integer(3),arith::ConstantIntOp::create(c.builder,outputLoc(binding),3,64)};
    return success();
  });
  require(succeeded(resultEmit)&&thenCalls==1&&elseCalls==1&&
      c.locals.at("joined").value.getDefiningOp<ebpf::PacketCheckOp>(),"emit-single-callback-C-owned-join");
  auto joined=c.locals.at("joined");
  auto insertion=c.builder.saveInsertionPoint();
  auto failedEmit=hooks->emit(c,descriptor,[&]{
    c.locals.clear();c.bindings.clear();c.maps[0].used=true;
    return failure();
  },[&]{++elseCalls;return success();});
  require(failed(failedEmit)&&elseCalls==1&&
      c.locals.at("joined").value==joined.value&&!c.maps[0].used&&
      c.bindings.at("packet:scope_probe").source==original.source&&
      c.builder.saveInsertionPoint().getBlock()==insertion.getBlock(),
      "early-error-restores-state-and-skips-else");
  llvm::outs()<<"PASS packet-loop-capability then-empty-SSA-binding packet-scope-full-binding-restore invalid-descriptor-error declined-has-no-effects\n";
}
