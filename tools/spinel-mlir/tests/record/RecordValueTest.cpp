#include "spinel/Conversion/RecordValue.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/Support/SaveAndRestore.h"
#include <cstdlib>
#include <cstdio>
using namespace spinel::consumer;
namespace math = spinel::math;
namespace range = spinel::range;
static void require(bool yes, const char *name) {
  if (!yes) { std::fprintf(stderr, "FAIL %s\n", name); std::exit(1); }
}
int main() {
  MLIRContext context;
  context.allowUnregisteredDialects();
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = ModuleOp::create(UnknownLoc::get(&context));
  Consumer c(module);
  c.useIsolatedRegistryForTesting();
  std::shared_ptr<const CheckedRecordValue> checkedRecord;
  {
  llvm::SaveAndRestore<bool> probe(c.probing, true);
  int64_t next = 1;
  auto node = [&](StringRef kind, StringRef name, StringRef decimal,
                  ArrayRef<NamedAttribute> refs,
                  ArrayRef<NamedAttribute> arrays) {
    OperationState state(FileLineColLoc::get(&context, "unit.rb", 1, 1),
                         "unit.node");
    state.addAttribute("id", c.builder.getI64IntegerAttr(next++));
    state.addAttribute("kind", c.builder.getStringAttr(kind));
    state.addAttribute("strings", c.builder.getDictionaryAttr({
        c.builder.getNamedAttr("name", c.builder.getStringAttr(name))}));
    state.addAttribute("literal_decimal", c.builder.getStringAttr(decimal));
    state.addAttribute("refs", c.builder.getDictionaryAttr(refs));
    state.addAttribute("arrays", c.builder.getDictionaryAttr(arrays));
    auto op = Operation::create(state);
    module.getBody()->push_back(op);
    c.nodes[c.id(op)] = op;
    return op;
  };
  auto link = [&](StringRef name, Operation *op) {
    return c.builder.getNamedAttr(name, c.builder.getI64IntegerAttr(c.id(op)));
  };
  auto arguments = [&](ArrayRef<Operation *> values) {
    SmallVector<Attribute> ids;
    for (auto op : values) ids.push_back(c.builder.getI64IntegerAttr(c.id(op)));
    return node("ArgumentsNode", "", "", {}, {
        c.builder.getNamedAttr("arguments", c.builder.getArrayAttr(ids))});
  };
  auto call = [&](StringRef type, ArrayRef<Operation *> values) {
    auto recv = node("ConstantReadNode", type, "", {}, {});
    auto args = arguments(values);
    return node("CallNode", "new", "", {link("receiver", recv),
        link("arguments", args)}, {});
  };
  auto zero = node("IntegerNode", "", "0", {}, {});
  auto one = node("IntegerNode", "", "1", {}, {});
  auto two = node("IntegerNode", "", "2", {}, {});
  auto four = node("IntegerNode", "", "4", {}, {});
  c.registry.addExpression("IntegerNode", [](Consumer &c, Operation *op) {
    auto result = std::make_shared<ScalarExpr>();
    result->node = op; result->kind = "literal";
    if (text(op, "literal_decimal").getAsInteger(10, result->literal))
      return Dispatch<Expr>::error();
    result->range.interval = math::MathInterval(math::Interval::point(
        math::Integer::from(result->literal)));
    result->range.form = range::Form::Literal;
    return Dispatch<Expr>::handled(result);
  });
  auto p = spinel::record::layout("P", {"a", "_pad0", "b"},
      {{"a", "u8", {}}, {"_pad0", "u8", {}}, {"b", "i16", {}}});
  auto layout = std::make_shared<const spinel::record::Layout>(p.layout);
  RecordDecl decl; decl.name = "P"; decl.recordLayout = layout;
  c.records.push_back(decl); c.badRecords.insert("Bad");
  require(lookupRecordLayout(c, "P") == layout &&
      !lookupRecordLayout(c, "Missing") && recordDeclarationFailed(c, "Bad") &&
      !recordDeclarationFailed(c, "P"), "record lookup/failed declaration");
  require(succeeded(checkRecordSample(c, {zero, zero, zero}, *layout,
      "zero required", SampleSite::RecordMap)), "scalar sample zero");
  require(failed(checkRecordSample(c, {one, zero, zero}, *layout,
      "zero required", SampleSite::RecordMap)) &&
      c.probeIssues.back().message == "zero required", "sample probe diagnostic");
  auto highByte = node("IntegerNode", "", "255", {}, {});
  auto negative = node("IntegerNode", "", "-2", {}, {});
  auto make = call("P", {highByte, zero, negative});
  auto checked = checkRecordMake(c, make, layout,
      {"Events", RecordDestination::Kind::Ring, ""});
  require(succeeded(checked) && (*checked)->members.size() == 3,
      "record make checked declaration order");
  auto badPad = checkRecordMake(c, call("P", {one, one, two}), layout,
      {"Events", RecordDestination::Kind::Ring, ""});
  require(failed(badPad) && c.probeIssues.back().message ==
      "padding member _pad0 must be the literal 0 (P006 §2)", "padding diagnosis");
  auto tooBig = node("IntegerNode", "", "256", {}, {});
  auto badRange = checkRecordMake(c, call("P", {tooBig, zero, two}), layout,
      {"Events", RecordDestination::Kind::Ring, ""});
  require(failed(badRange) && c.probeIssues.back().code == "SB014",
      "member range rejects truncation with probe issue");
  auto bytes = spinel::record::layout("Bytes", {"data"}, {{"data", "u8", 4}});
  require(succeeded(checkRecordSample(c, {call("Array", {four, zero})},
      bytes.layout, "zero", SampleSite::RingEvent)), "ring u8 array sample");
  require(failed(checkRecordSample(c, {call("Array", {two, zero})},
      bytes.layout, "zero", SampleSite::RingEvent)) &&
      c.probeIssues.back().message.find("has 2 elements") != std::string::npos,
      "array sample length diagnosis");
  checkedRecord = *checked;
  }
  require(!c.probing, "probe state restored before emit");
  auto output = ModuleOp::create(UnknownLoc::get(&context));
  c.builder.setInsertionPointToEnd(output.getBody());
  auto emitted = emitRecordMake(c, *checkedRecord);
  require(succeeded(emitted), "record emit");
  auto makeOp = emitted->getDefiningOp<ebpf::RecordMakeOp>();
  require(makeOp && makeOp.getFields().size() == 2 &&
      cast<StringAttr>(makeOp.getFields()[0]).getValue() == "a" &&
      cast<StringAttr>(makeOp.getFields()[1]).getValue() == "b" &&
      makeOp.getValues()[0].getType().isInteger(8) &&
      makeOp.getValues()[1].getType().isInteger(16),
      "record emitted fields omit padding and retain widths/order");
  auto a = makeOp.getValues()[0].getDefiningOp<arith::ConstantOp>();
  auto b = makeOp.getValues()[1].getDefiningOp<arith::ConstantOp>();
  require(a && b &&
      cast<IntegerAttr>(a.getValue()).getValue().getSExtValue() == -1 &&
      cast<IntegerAttr>(b.getValue()).getValue().getSExtValue() == -2 &&
      output.getOps<arith::TruncIOp>().empty(),
      "literal members are direct width constants, unsigned high bit and signed negative");
  return 0;
}
