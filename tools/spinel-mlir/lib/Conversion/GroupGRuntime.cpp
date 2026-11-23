#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGRuntime.h"
namespace spinel::consumer {
namespace {
Dispatch<Expr> runtimeCall(Consumer &c, Operation *node) {
  if (field(node,"strings","name") != "pid_tgid" ||
      c.constant(c.ref(node,"receiver")) != "BPF")
    return Dispatch<Expr>::declined();
  CalleePolicy policy;
  policy.expected = "BPF.pid_tgid";
  policy.requireCallee = false;
  if (failed(c.known(node,policy))) return Dispatch<Expr>::error();
  auto callee = text(c.evidence[c.id(node)].front(),"callee");
  auto arguments = c.args(node);
  if (callee != "BPF.pid_tgid" || !arguments.empty()) {
    std::string quoted;
    llvm::raw_string_ostream os(quoted);
    os << llvm::json::Value(callee.str());
    (void)c.diagnostic(node,"SB011","ShadowedName",
      "`BPF.pid_tgid` resolves to " + quoted + " (with " +
      std::to_string(arguments.size()) + " arguments), not the library's BPF.pid_tgid",true);
    return Dispatch<Expr>::error();
  }
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  e->kind = "gkernel.pid_tgid";
  e->range = {math::MathInterval(math::Interval(math::Integer::from(0),
                 math::Integer::fromUnsigned(UINT64_MAX))), false, true,
              range::Form::PidTgid};
  return Dispatch<Expr>::handled(std::move(e));
}
Dispatch<Value> emitPid(Consumer &c,const Expr &e) {
  return Dispatch<Value>::handled(ebpf::TaskPidTgidOp::create(
      c.builder,outputLoc(e->node),c.builder.getI64Type()).getResult());
}
} // namespace
void registerGroupGRuntime(Registry &r) {
  r.addExpression("CallNode",runtimeCall);
  r.addEmitter("gkernel.pid_tgid",emitPid);
}
} // namespace spinel::consumer
