#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "llvm/Support/raw_ostream.h"
namespace spinel::consumer {
namespace {
Dispatch<Expr> ktime(Consumer &c,Operation *node) {
  if(text(node,"kind")!="CallNode")return Dispatch<Expr>::declined();
  bool syntax=field(node,"strings","name")=="ktime_ns" &&
              c.constant(c.ref(node,"receiver"))=="BPF";
  auto found=c.evidence.find(c.id(node));
  bool observed=found!=c.evidence.end() && llvm::any_of(found->second,[](Operation *ev){
    return text(ev,"callee")=="BPF.ktime_ns";
  });
  if(!syntax&&!observed)return Dispatch<Expr>::declined();
  if(failed(c.known(node,true)))return Dispatch<Expr>::error();
  auto callee=text(c.evidence[c.id(node)].front(),"callee");
  auto args=c.args(node);
  if(!syntax || callee!="BPF.ktime_ns" || !args.empty()) {
    std::string quoted;llvm::raw_string_ostream stream(quoted);
    stream<<llvm::json::Value(callee);
    (void)c.diagnostic(node,"SB011","ShadowedName",
      "`BPF.ktime_ns` resolves to "+quoted+" (with "+std::to_string(args.size())+
      " arguments), not the library's BPF.ktime_ns");
    return Dispatch<Expr>::error();
  }
  auto max=math::Integer::parse("18446744073709551615");
  if(!max)return (void)c.rangeFailure(max.takeError(),node),Dispatch<Expr>::error();
  auto e=std::make_shared<ScalarExpr>();e->node=node;e->kind="helper.ktime_ns";
  e->range={math::MathInterval(math::Interval{math::Integer::from(0),*max}),
            false,true,range::Form::Ktime};
  return Dispatch<Expr>::handled(e);
}
}
void registerHelpers(Registry &registry) {
  registry.addExpression("CallNode",ktime);
  registry.addEmitter("helper.ktime_ns",[](Consumer &c,const Expr &e){
    auto loc=outputLoc(e->node);
#ifdef SPINEL_E033_TEST_UNKNOWN_LOC
    loc=c.builder.getUnknownLoc();
#endif
    return Dispatch<Value>::handled(ebpf::KtimeOp::create(c.builder,loc,c.builder.getI64Type()));
  });
}
} // namespace spinel::consumer
