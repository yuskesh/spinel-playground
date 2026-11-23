#include "spinel/Conversion/RecordValue.h"
#include "spinel/Conversion/KernelRecordAccess.h"
#include "spinel/Conversion/TracepointRecordAccess.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/Support/Error.h"

namespace spinel::consumer {
namespace {
LogicalResult shape(Consumer &c, Operation *node, const std::string &message) {
  return c.diagnostic(node, "SB024", "RecordShape", message,
                      c.activeDef != nullptr);
}
std::optional<math::Integer> literal(Operation *node) {
  if (!node || text(node, "kind") != "IntegerNode") return std::nullopt;
  auto parsed = math::Integer::parse(text(node, "literal_decimal").str());
  if (!parsed) { llvm::consumeError(parsed.takeError()); return std::nullopt; }
  return *parsed;
}
bool zero(Operation *node) {
  auto n = literal(node);
  return n && *n == math::Integer::from(0);
}
bool zeroArray(Consumer &c, Operation *node, int64_t count) {
  auto args = c.args(node);
  if (text(node, "kind") != "CallNode" ||
      field(node, "strings", "name") != "new" ||
      c.constant(c.ref(node, "receiver")) != "Array" || args.size() != 2)
    return false;
  auto n = literal(args[0]);
  return n && *n == math::Integer::from(count) && zero(args[1]);
}
math::Interval memberRange(const record::FieldLayout &f) {
  if (!f.isSigned)
    return {math::Integer::from(0), math::Integer::fromUnsigned(
        f.bits == 64 ? UINT64_MAX : (uint64_t(1) << f.bits) - 1)};
  return {math::Integer::from(f.bits == 64 ? INT64_MIN : -(int64_t(1) << (f.bits - 1))),
          math::Integer::from(f.bits == 64 ? INT64_MAX : (int64_t(1) << (f.bits - 1)) - 1)};
}
bool directWide(range::Form form) {
  switch (form) {
  case range::Form::Load: case range::Form::Ktime:
  case range::Form::PidTgid: case range::Form::Retval:
  case range::Form::Kparg: case range::Form::Rawarg:
  case range::Form::Tpfield: case range::Form::Gload:
  case range::Form::Kfload: return true;
  default: return false;
  }
}
} // namespace
RecordLayoutPtr lookupRecordLayout(const Consumer &c, StringRef constant) {
  for (const auto &record : c.records)
    if (record.name == constant) return record.recordLayout;
  return {};
}
bool recordDeclarationFailed(const Consumer &c, StringRef constant) {
  return c.badRecords.count(constant.str()) != 0;
}
FailureOr<Expr> checkRecordMemberValue(Consumer &c, Operation *node,
                                      const record::Layout &layout,
                                      const record::FieldLayout &field) {
  auto value = c.scalar(node);
  if (failed(value)) return failure();
  if ((*value)->range.isBool)
    return (void)c.diagnostic(node, "SB001", "UnsupportedConstruct",
        "a bool cannot be stored in a record member", true), failure();
  if ((*value)->range.wide) {
    if (field.bits == 64 && !field.isSigned && directWide((*value)->range.form))
      return *value;
    if (failed(c.checked(range::checkIntegerUse((*value)->range, {c.id(node)}), node)))
      return failure();
    return (void)c.error(node, "wide record value has no direct-copy evidence"), failure();
  }
  auto interval = (*value)->range.interval.finite();
  if (!interval) return (void)c.rangeFailure(interval.takeError(), node), failure();
  auto target = memberRange(field);
  if (!interval->within(target))
    return (void)c.diagnostic(node, "SB014", "SemanticGap",
        "the value's range " + interval->str() + " does not fit member " +
        layout.name + "." + field.name + " (" + field.type + " " + target.str() +
        ") — the store would truncate silently; narrow it (e.g. `& 0xFF`) (P006 §2)", true), failure();
  return *value;
}
FailureOr<Value> emitRecordMemberValue(Consumer &c, const Expr &expr,
                                      const record::FieldLayout &field) {
  auto loc = outputLoc(expr->node);
  Value operand;
  if (expr->kind == "literal") {
    auto type = c.builder.getIntegerType(field.bits);
    operand = arith::ConstantOp::create(c.builder, loc, c.builder.getIntegerAttr(
        type, llvm::APInt(field.bits, static_cast<uint64_t>(expr->literal), true)));
  } else {
    auto specialized = c.dispatchEmitter(expr->kind + ".i" + std::to_string(field.bits), expr);
    if (specialized.state == Disposition::Error) return failure();
    operand = specialized.state == Disposition::Handled ? *specialized.value : c.emitScalar(expr);
  }
  if (!operand) return (void)c.error(expr->node, "checked record operand could not be emitted"), failure();
  auto width = cast<IntegerType>(operand.getType()).getWidth();
  auto type = c.builder.getIntegerType(field.bits);
  if (width > field.bits) operand = arith::TruncIOp::create(c.builder, loc, type, operand);
  else if (width < field.bits)
    operand = field.isSigned ? arith::ExtSIOp::create(c.builder, loc, type, operand).getResult()
                             : arith::ExtUIOp::create(c.builder, loc, type, operand).getResult();
  return operand;
}
LogicalResult checkRecordSample(Consumer &c, llvm::ArrayRef<Operation *> args,
                                const record::Layout &layout,
                                StringRef zeroMessage, SampleSite site) {
  if (args.size() != layout.fields.size())
    return c.error(args.empty() ? nullptr : args.front(),
                   "record sample arity was not checked by caller");
  for (size_t i = 0; i < args.size(); ++i) {
    const auto &f = layout.fields[i];
    auto node = args[i];
    if (!f.count) {
      if (!zero(node)) return shape(c, node, zeroMessage.str());
      continue;
    }
    const std::string where = site == SampleSite::RingEvent
        ? "a ring buffer event" : site == SampleSite::RecordKey
        ? "a hash map (key or value)" : "";
    if (!where.empty() && !(site == SampleSite::RingEvent &&
                           f.bits == 8 && !f.isSigned))
      return shape(c, node, "record " + layout.name + " has the array member " +
          f.name + " — " + where +
          " takes records without array members (array members are for record map values — P016 E066)");
    const auto elements = c.args(node);
    const std::string message = "the sample of the array member " + f.name +
        " is `Array.new(" + std::to_string(*f.count) + ", 0)` (P016 E066)";
    if (text(node, "kind") != "CallNode" ||
        field(node, "strings", "name") != "new" ||
        c.constant(c.ref(node, "receiver")) != "Array" || elements.size() != 2)
      return shape(c, node, message);
    auto n = literal(elements[0]);
    if (!n || !zero(elements[1])) return shape(c, node, message);
    if (*n != math::Integer::from(*f.count))
      return shape(c, elements[0], "the sample of the array member " + f.name +
          " has " + n->str() + " elements, but BPF.record declares " +
          std::to_string(*f.count) + " — they must be the same (P016 E066)");
  }
  return success();
}
FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkRecordMake(Consumer &c, Operation *make, RecordLayoutPtr layout,
                const RecordDestination &destination) {
  if (!layout) return (void)c.error(make, "record layout unavailable"), failure();
  if (!make || text(make, "kind") != "CallNode" ||
      field(make, "strings", "name") != "new" ||
      c.constant(c.ref(make, "receiver")) != layout->name)
    return (void)shape(c, make, "the value is `" + layout->name +
        ".new(…)` with every member (P006 §2)"), failure();
  auto args = c.args(make);
  for (auto node : args)
    if (text(node, "kind") == "KeywordHashNode" ||
        text(node, "kind") == "SplatNode")
      return (void)shape(c, node, layout->name +
          ".new takes positional arguments only (P006 §2)"), failure();
  if (args.size() != layout->fields.size())
    return (void)shape(c, make, layout->name + ".new must give all " +
        std::to_string(layout->fields.size()) + " members explicitly, got " +
        std::to_string(args.size()) +
        " (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5) (P006 §2)"), failure();
  auto result = std::make_shared<CheckedRecordValue>();
  result->layout = layout;
  result->node = make;
  for (size_t i = 0; i < args.size(); ++i) {
    const auto &f = layout->fields[i];
    auto node = args[i];
    if (f.padding || f.count) {
      if (f.padding && !zero(node))
        return (void)shape(c, node, "padding member " + f.name +
            " must be the literal 0 (P006 §2)"), failure();
      if (f.count && destination.kind == RecordDestination::Kind::Ring) {
        auto copy = checkKernelRecordCopy(c, node, *layout, f, true);
        if (copy.state == Disposition::Declined)
          copy = checkTracepointRecordCopy(c, node, *layout, f, true);
        if (copy.state == Disposition::Error) return failure();
        if (copy.state == Disposition::Handled) {
          auto checked = *copy.value;
          result->reservationWrites.push_back(
              [checked, name = f.name](Consumer &c, Value res, Location) {
                if (checked->kind == "gprobe.record-copy")
                  return emitTracepointRecordCopy(c, checked, res, name, outputLoc(checked->node));
                return emitKernelRecordCopy(c, checked, res, name,
                                            outputLoc(checked->node));
              });
          // The ordinary make initializes every byte before the deferred copy.
          auto value = std::make_shared<ScalarExpr>(*checked);
          value->kind = "record.zero-array";
          result->members.push_back(value);
          continue;
        }
      }
      if (f.count && !zeroArray(c, node, *f.count))
        return (void)shape(c, node, "the array member " + f.name +
            " is given as `Array.new(" + std::to_string(*f.count) + ", 0)` in " +
            layout->name + ".new — its elements are not values on the eBPF side (P016 E066, P020)"), failure();
      auto value = std::make_shared<ScalarExpr>();
      value->node = node;
      value->kind = f.count ? "record.zero-array" : "literal";
      value->range.interval = math::MathInterval(math::Interval::point(math::Integer::from(0)));
      value->range.form = range::Form::Literal;
      result->members.push_back(value);
      continue;
    }
    auto value = checkRecordMemberValue(c, node, *layout, f);
    if (failed(value)) return failure();
    result->members.push_back(*value);
  }
  return std::shared_ptr<const CheckedRecordValue>(result);
}
FailureOr<Value> emitRecordMake(Consumer &c, const CheckedRecordValue &value) {
  if (!value.layout || value.members.size() != value.layout->fields.size())
    return (void)c.error(value.node, "invalid checked record member count"), failure();
  SmallVector<Value> operands;
  SmallVector<StringRef> fields;
  std::vector<std::string> names;
  for (size_t i = 0; i < value.members.size(); ++i) {
    const auto &f = value.layout->fields[i];
    if (f.padding) continue;
    const auto &expr = value.members[i];
    auto loc = outputLoc(expr->node);
    if (f.count) {
      if (expr->kind != "record.zero-array")
        return (void)c.error(expr->node, "record array lacks checked zero initializer"), failure();
      Value zero = arith::ConstantIntOp::create(c.builder, loc, 0, f.bits);
      for (int64_t j = 0; j < *f.count; ++j) {
        names.push_back(f.name + "[" + std::to_string(j) + "]");
        operands.push_back(zero);
      }
      continue;
    }
    auto operand = emitRecordMemberValue(c, expr, f);
    if (failed(operand)) return failure();
    names.push_back(f.name);
    operands.push_back(*operand);
  }
  for (const auto &name : names) fields.push_back(name);
  for (auto &record : c.records)
    if (record.name == value.layout->name) record.used = true;
  return ebpf::RecordMakeOp::create(c.builder, outputLoc(value.node),
      ebpf::RecordType::get(c.ctx, value.layout->name, value.layout->size),
      c.builder.getStrArrayAttr(fields), operands).getResult();
}
} // namespace spinel::consumer
