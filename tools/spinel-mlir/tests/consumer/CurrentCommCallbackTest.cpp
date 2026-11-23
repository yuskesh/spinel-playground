// Synthetic checked-kernel-pointer unit, not a Go-oracle case.
#include "spinel/Conversion/Ring.h"
#include "spinel/Conversion/KernelRecordAccess.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void check(bool yes, const char *name) {
  if (!yes) { llvm::errs() << "FAIL " << name << '\n'; std::exit(1); }
  llvm::outs() << "PASS " << name << '\n';
}
int main() {
  MLIRContext context;
  context.allowUnregisteredDialects();
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  auto input = ModuleOp::create(UnknownLoc::get(&context));
  auto output = ModuleOp::create(UnknownLoc::get(&context));
  Consumer c(input);
  c.useIsolatedRegistryForTesting();
  registerGroupRing(c.registry);
  c.activeKind = "kprobe";
  int64_t next = 1;
  auto node = [&](StringRef kind, StringRef name, StringRef decimal,
                  ArrayRef<NamedAttribute> refs = {}, ArrayRef<NamedAttribute> arrays = {}) {
    OperationState s(UnknownLoc::get(&context), "unit.node");
    s.addAttribute("id", c.builder.getI64IntegerAttr(next++));
    s.addAttribute("kind", c.builder.getStringAttr(kind));
    s.addAttribute("strings", c.builder.getDictionaryAttr({
      c.builder.getNamedAttr("name", c.builder.getStringAttr(name)),
      c.builder.getNamedAttr("unescaped", c.builder.getStringAttr(name))}));
    s.addAttribute("literal_decimal", c.builder.getStringAttr(decimal));
    s.addAttribute("refs", c.builder.getDictionaryAttr(refs));
    s.addAttribute("arrays", c.builder.getDictionaryAttr(arrays));
    auto *op = Operation::create(s); input.getBody()->push_back(op);
    c.nodes[c.id(op)] = op; c.analyzed[c.id(op)] = op;
    return op;
  };
  auto link = [&](StringRef name, Operation *op) { return c.builder.getNamedAttr(name, c.builder.getI64IntegerAttr(c.id(op))); };
  auto args = [&](ArrayRef<Operation *> values) {
    SmallVector<Attribute> ids;
    for (auto *v : values) ids.push_back(c.builder.getI64IntegerAttr(c.id(v)));
    return node("ArgumentsNode", "", "", {}, {c.builder.getNamedAttr("arguments", c.builder.getArrayAttr(ids))});
  };
  auto zero = node("IntegerNode", "", "0");
  auto size = node("IntegerNode", "", "16");
  auto array = node("ConstantReadNode", "Array", "");
  auto zeroArray = node("CallNode", "new", "", {link("receiver", array), link("arguments", args({size, zero}))});
  auto pointer = node("LocalVariableReadNode", "ptr", "");
  auto copy = node("CallNode", "copy", "", {link("receiver", pointer)});
  auto ev = node("ConstantReadNode", "Ev", "");
  auto make = node("CallNode", "new", "", {link("receiver", ev), link("arguments", args({zeroArray, zero, copy}))});
  auto ring = node("ConstantReadNode", "Events", "");
  auto comm = node("SymbolNode", "comm", "");
  auto status = node("SymbolNode", "status", "");
  auto call = node("CallNode", "output_comm", "", {link("receiver", ring), link("arguments", args({make, comm, status}))});
  auto write = node("LocalVariableWriteNode", "_", "", {link("value", call)});
  c.types[c.id(call)].push_back(node("obj_OutputStr", "", ""));
  OperationState es(UnknownLoc::get(&context), "unit.evidence");
  for (auto [name, value] : {std::pair{"dispatch", "direct"}, {"name", "output_comm"}, {"callee", "RingBuf#output_comm"}})
    es.addAttribute(name, c.builder.getStringAttr(value));
  auto *evidence = Operation::create(es); input.getBody()->push_back(evidence);
  c.evidence[c.id(call)].push_back(evidence);
  auto layout = spinel::record::layout("Ev", {"comm", "status", "other"},
      {{"comm", "u8", 16}, {"status", "i64", {}}, {"other", "u8", 16}});
  check(!layout.issue, "unit layout valid");
  c.rings.push_back({"Events", "Events", std::make_shared<const spinel::record::Layout>(layout.layout), 4096});
  c.registry.addExpression("IntegerNode", [](Consumer &, Operation *n) {
    auto e = std::make_shared<ScalarExpr>(); e->node = n; e->kind = "literal";
    if (text(n, "literal_decimal").getAsInteger(10, e->literal)) return Dispatch<Expr>::error();
    e->range.interval = spinel::math::MathInterval(spinel::math::Interval::point(spinel::math::Integer::from(e->literal)));
    return Dispatch<Expr>::handled(e);
  });
  c.registry.addExpression("KernelRecordAccess", [](Consumer &, Operation *n) {
    auto p = std::make_shared<KernelRecordAccess>();
    p->variable = "ptr"; p->structure = "task_struct"; p->typeConstant = "Task"; p->field = "comm"; p->count = 16;
    auto e = std::make_shared<ScalarExpr>(); e->node = n; e->kind = "gkernel.record-copy"; e->payload = p;
    return Dispatch<Expr>::handled(e);
  });
  c.builder.setInsertionPointToStart(output.getBody());
  auto z = arith::ConstantIntOp::create(c.builder, c.builder.getUnknownLoc(), 0, 64);
  auto ptr = UnrealizedConversionCastOp::create(c.builder, c.builder.getUnknownLoc(),
      TypeRange{ebpf::KPtrType::get(&context, "task_struct")}, ValueRange{z}).getResult(0);
  c.bindings["gkernel.ptr:ptr"] = {nullptr, nullptr, ptr};
  SmallVector<Operation *> statements{write};
  auto result = c.dispatchStatement("LocalVariableWriteNode", statements, 0, 0);
  check(result.state == Disposition::Handled, "comm record checked and emitted");
  unsigned copies = 0, comms = 0;
  Operation *copyOp = nullptr, *commOp = nullptr;
  output.walk([&](Operation *op) {
    if (isa<ebpf::KFieldCopyOp>(op)) { ++copies; copyOp = op; }
    if (isa<ebpf::TaskCommOp>(op)) { ++comms; commOp = op; }
  });
  output.print(llvm::outs()); llvm::outs() << '\n';
  check(copies == 1, "existing kernel-copy callback emitted");
  check(comms == 1, "comm retained with other-member kernel-copy callback");
  check(copyOp->getBlock() == commOp->getBlock() && copyOp->isBeforeInBlock(commOp), "kernel copy precedes task.comm in present region");
  output.erase(); input.erase();
}
