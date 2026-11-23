#include "spinel/Conversion/RecordValue.h"
#include "spinel/Conversion/KernelRecordAccess.h"
#include "spinel/Conversion/TracepointRecordAccess.h"
#include "spinel/Conversion/Subprograms.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include <algorithm>

namespace spinel::consumer {
namespace {
struct FieldValue : Payload {
  record::FieldLayout field;
  std::string reference, path;
  Expr index;
};
struct Access {
  std::string reference;
  size_t map;
  RecordLayoutPtr layout;
  Operation *load;
  bool present;
};
std::optional<Access> access(Consumer &c, Operation *load) {
  if (!load || text(load, "kind") != "CallNode" ||
      field(load, "strings", "name") != "load") return std::nullopt;
  auto receiver = c.ref(load, "receiver");
  if (text(receiver, "kind") != "LocalVariableReadNode") return std::nullopt;
  auto reference = field(receiver, "strings", "name").str();
  auto borrow = c.borrows.find(reference);
  if (borrow != c.borrows.end()) {
    auto index = borrow->second.map;
    auto layout = lookupRecordLayout(c, c.maps[index].valueRecord);
    if (layout) return Access{reference, index, layout, load, true};
    return std::nullopt;
  }
  // Recognize an out-of-region record reference to diagnose its use; this
  // never creates a borrow, a Value, or codegen evidence.
  for (const auto &entry : c.nodes) {
    auto write = entry.second;
    if (text(write, "kind") != "LocalVariableWriteNode" ||
        field(write, "strings", "name") != reference) continue;
    auto call = c.ref(write, "value");
    if (field(call, "strings", "name") != "lookup") continue;
    auto constant = c.constant(c.ref(call, "receiver"));
    for (size_t i = 0; i < c.maps.size(); ++i) {
      if (c.maps[i].name != constant) continue;
      auto layout = lookupRecordLayout(c, c.maps[i].valueRecord);
      if (layout) return Access{reference, i, layout, load, false};
    }
  }
  return std::nullopt;
}
LogicalResult reject(Consumer &c, Operation *node, StringRef code,
                      const std::string &message) {
  StringRef name = code == "SB005" ? "RefCheckShape" : code == "SB024" ? "RecordShape"
      : code == "SB019" ? "SharedReadModifyWrite" : code == "SB031" ? "IndexRange"
      : code == "SB011" ? "ShadowedName" : "UnsupportedCall";
  return c.diagnostic(node, code, name, message, true);
}
LogicalResult alias(Consumer &c, const Access &a, bool local = false) {
  if (local)
    return reject(c, a.load, "SB005", "`" + a.reference +
        ".load` of a record is not a value — read a member (`" + a.reference +
        ".load.<member>`) (P006 §2)");
  return reject(c, c.ref(a.load, "receiver"), "SB005", "`" + a.reference +
      "` may be read only as `if " + a.reference + "`, `" + a.reference +
      ".load.<member>` / `" + a.reference + ".load.<member> = e` and `" +
      a.reference + ".atomic_add(:member, d)` inside it — `" + a.reference +
      ".load` is not a value (no local, dup, comparison or argument: the kernel side writes the map entry directly) (P006 §2)");
}
const record::FieldLayout *member(const record::Layout &layout, StringRef name) {
  for (const auto &field : layout.fields) if (field.name == name) return &field;
  return nullptr;
}
LogicalResult loadKnown(Consumer &c, const Access &a) {
  if (!a.present) return alias(c, a);
  return c.known(a.load, CalleePolicy{"RecordRef#load"});
}
FailureOr<int64_t> literalIndex(Consumer &c, Operation *node,
                                 const Access &a, const record::FieldLayout &f) {
  if (text(node, "kind") != "IntegerNode")
    return (void)c.error(node, "record variable index handler is not connected yet"), failure();
  auto parsed = math::Integer::parse(text(node, "literal_decimal").str());
  if (!parsed) return (void)c.rangeFailure(parsed.takeError(), node), failure();
  if (*parsed < math::Integer::from(0) ||
      !( *parsed < math::Integer::from(*f.count)))
    return (void)reject(c, node, "SB031", "the index " + parsed->str() +
        " is outside [0, " + std::to_string(*f.count - 1) + "] of " +
        a.reference + ".load." + f.name +
        " (Ruby reads nil past the end and counts a negative index from the end; BPF has neither) (P016 E066)"), failure();
  int64_t index;
  if (text(node, "literal_decimal").getAsInteger(10, index))
    return (void)c.error(node, "checked record index is not representable"), failure();
  return index;
}
FailureOr<Expr> variableIndex(Consumer &c, Operation *node,
                              const Access &a, const record::FieldLayout &f) {
  auto value = c.scalar(node);
  if (failed(value)) return failure();
  auto prefix = "the index of " + a.reference + ".load." + f.name;
  if ((*value)->range.isBool || (*value)->range.wide)
    return (void)reject(c, node, "SB031", prefix +
        " must be an Integer (not a bool, not an unnarrowed u64 value) (P016)"), failure();
  auto interval = (*value)->range.interval.finite();
  if (!interval) return (void)c.rangeFailure(interval.takeError(), node), failure();
  auto n = *f.count;
  if (!interval->within({math::Integer::from(0), math::Integer::from(n - 1)})) {
    std::string hint = "narrow it into [0, " + std::to_string(n - 1) + "] (e.g. ";
    if ((n & (n - 1)) == 0)
      hint += "`i & " + std::to_string(n - 1) + "`, `i % " + std::to_string(n) +
          "` or inside `if i >= 0 && i < " + std::to_string(n) + "`)";
    else {
      unsigned mask = 1; while (mask < n) mask *= 2; --mask;
      hint += "inside `if i >= 0 && i < " + std::to_string(n) + "`, or `i % " +
          std::to_string(n) + "` for a non-negative i — " + std::to_string(n) +
          " is not a power of two, so no mask `i & M` covers exactly [0, " +
          std::to_string(n - 1) + "]: `i & " + std::to_string(mask) + "` can reach " + std::to_string(mask) + ")";
    }
    return (void)reject(c, node, "SB031", prefix + " has range " + interval->str() +
        ", not inside [0, " + std::to_string(n - 1) + "]" +
        (interval->lo < math::Integer::from(0) ? " — a negative index counts from the end in Ruby, BPF has no such index" : "") +
        "; " + hint + " (P016 E068)"), failure();
  }
  return *value;
}
Dispatch<Expr> readMember(Consumer &c, Operation *node) {
  auto name = field(node, "strings", "name");
  if (name == "load") {
    auto a = access(c, node);
    if (!a) return Dispatch<Expr>::declined();
    auto parent = c.parents.lookup(node);
    (void)alias(c, *a, text(parent, "kind") == "LocalVariableWriteNode");
    return Dispatch<Expr>::error();
  }
  bool indexed = name == "[]";
  auto fieldNode = indexed ? c.ref(node, "receiver") : node;
  auto a = access(c, c.ref(fieldNode, "receiver"));
  if (!a) return Dispatch<Expr>::declined();
  auto fieldName = field(fieldNode, "strings", "name");
  auto f = member(*a->layout, fieldName);
  if (!f) {
    static const std::vector<std::string> objects = {"dup", "clone", "freeze", "frozen?",
        "to_a", "to_h", "deconstruct", "members", "values", "each", "hash",
        "eql?", "equal?", "inspect", "to_s", "size", "length", "tap", "then"};
    auto lower = [](char ch) { return ch >= 'a' && ch <= 'z'; };
    bool identifier = !fieldName.empty() && (lower(fieldName.front()) || fieldName.front() == '_') &&
        llvm::all_of(fieldName, [&](char ch) { return lower(ch) || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'; });
    if (!identifier || llvm::is_contained(objects, fieldName.str()))
      (void)alias(c, *a);
    else (void)reject(c, node, "SB002", "record " + a->layout->name + " has no member `" + fieldName.str() + "`");
    return Dispatch<Expr>::error();
  }
  if (f->padding)
    return (void)reject(c, node, "SB024", "`" + f->name +
        "` is padding — it is neither read nor written on the eBPF side (P006 §2)"), Dispatch<Expr>::error();
  if (failed(loadKnown(c, *a))) return Dispatch<Expr>::error();
  if (!c.args(fieldNode).empty() || c.ref(fieldNode, "block"))
    return (void)reject(c, node, "SB002", "a member read takes no arguments"), Dispatch<Expr>::error();
  auto payload = std::make_shared<FieldValue>();
  payload->field = *f; payload->reference = a->reference; payload->path = f->name;
  if (indexed) {
    if (!f->count)
      return (void)reject(c, node, "SB002", "member " + f->name + " of record " +
          a->layout->name + " is not an array — `[]` is for array members (P016)"), Dispatch<Expr>::error();
    auto args = c.args(node);
    if (args.size() != 1 || c.ref(node, "block"))
      return (void)reject(c, node, "SB002", "an element read is `" + a->reference +
          ".load." + f->name + "[k]` with one index (P016)"), Dispatch<Expr>::error();
    if (text(args[0], "kind") == "IntegerNode") {
      auto index = literalIndex(c, args[0], *a, *f);
      if (failed(index)) return Dispatch<Expr>::error();
      payload->path += "[" + std::to_string(*index) + "]";
    } else {
      auto index = variableIndex(c, args[0], *a, *f);
      if (failed(index)) return Dispatch<Expr>::error();
      payload->index = *index;
    }
  } else if (f->count)
    return (void)reject(c, node, "SB024", "the array member " + f->name +
        " is read by element (`" + a->reference + ".load." + f->name +
        "[k]`) — the array itself is not a value on the eBPF side (P016 E066)"), Dispatch<Expr>::error();
  // Accessor dispatch may be switch/boxed. Its meaning follows the declared
  // Struct member; only the RecordRef#load call requires a direct callee.
  if (failed(c.known(node))) return Dispatch<Expr>::error();
  auto result = std::make_shared<ScalarExpr>();
  result->node = node; result->kind = "record.field"; result->map = a->map;
  result->payload = payload;
  result->range.form = range::Form::Load;
  result->range.wide = f->bits == 64 && !f->isSigned;
  math::Interval interval = f->isSigned
      ? (f->bits == 64 ? math::Interval::fullI64()
          : math::Interval{math::Integer::from(-(int64_t(1) << (f->bits - 1))),
                           math::Integer::from((int64_t(1) << (f->bits - 1)) - 1)})
      : math::Interval{math::Integer::from(0), math::Integer::fromUnsigned(
          f->bits == 64 ? UINT64_MAX : (uint64_t(1) << f->bits) - 1)};
  result->range.interval = math::MathInterval(interval);
  result->reads = {{a->map, c.borrows.at(a->reference).key, a->reference}};
  c.records[std::find_if(c.records.begin(), c.records.end(),
      [&](const auto &r) { return r.name == a->layout->name; }) - c.records.begin()].used = true;
  return Dispatch<Expr>::handled(result);
}
Value index32(Consumer &c, Value index, Location loc) {
  if (auto ext = index.getDefiningOp<arith::ExtUIOp>()) {
    if (auto iv = dyn_cast<BlockArgument>(ext.getIn()))
      if (iv.getArgNumber() == 0 && iv.getType().isInteger(32) &&
          isa<ebpf::LoopOp>(iv.getOwner()->getParentOp())) return iv;
  }
  return arith::TruncIOp::create(c.builder, loc, c.builder.getI32Type(), index);
}
Dispatch<Value> emitField(Consumer &c, const Expr &expr, unsigned width = 0) {
  auto value = std::static_pointer_cast<const FieldValue>(expr->payload);
  if (!value) return (void)c.error(expr->node, "record field payload missing"), Dispatch<Value>::error();
  if (width && width != value->field.bits) return Dispatch<Value>::declined();
  auto found = c.borrows.find(value->reference);
  if (found == c.borrows.end() || !found->second.value)
    return (void)c.error(expr->node, "record field emitted outside present region"), Dispatch<Value>::error();
  const Borrow borrow = found->second;
  auto loc = outputLoc(expr->node);
  Value raw;
  if (value->index) {
    Value index = c.emitScalar(value->index);
    if (!index) return Dispatch<Value>::error();
    index = index32(c, index, loc);
    auto type = c.builder.getIntegerType(value->field.bits);
    auto op = ebpf::RefIndexOp::create(c.builder, loc, TypeRange{type},
        borrow.value, value->field.name, ValueRange{index});
    {
      OpBuilder::InsertionGuard guard(c.builder);
      auto *yes = new Block(); op.getInRange().push_back(yes);
      auto elem = yes->addArgument(ebpf::ElemType::get(c.ctx, type), c.builder.getUnknownLoc());
      c.builder.setInsertionPointToStart(yes);
      Value loaded = ebpf::ElemLoadOp::create(c.builder, loc, type, elem, false);
      ebpf::YieldOp::create(c.builder, loc, ValueRange{loaded});
      auto *no = new Block(); op.getOutOfRange().push_back(no);
      c.builder.setInsertionPointToStart(no);
      Value zero = arith::ConstantIntOp::create(c.builder, loc, type, 0);
      ebpf::YieldOp::create(c.builder, loc, ValueRange{zero});
    }
    raw = op.getResult(0);
  } else raw = ebpf::RefFieldLoadOp::create(c.builder, loc,
      c.builder.getIntegerType(value->field.bits), borrow.value,
      value->path, false);
  for (auto &record : c.records)
    if (record.name == c.maps[expr->map].valueRecord) record.used = true;
  if (width || value->field.bits == 64) return Dispatch<Value>::handled(raw);
  Value widened = value->field.isSigned
      ? arith::ExtSIOp::create(c.builder, loc, c.builder.getI64Type(), raw).getResult()
      : arith::ExtUIOp::create(c.builder, loc, c.builder.getI64Type(), raw).getResult();
  return Dispatch<Value>::handled(widened);
}
bool sameReferenceRead(Consumer &c, Operation *rhs, const Access &a) {
  for (const auto &origin : c.origins(rhs))
    if (origin.domain == ReadOrigin::Domain::Map && origin.ref == a.reference &&
        !c.rmwExempt(origin, a.map)) return true;
  return false;
}
Dispatch<StatementResult> perCPUAdd(Consumer &c, Operation *node,
                                     const Access &a) {
  if (text(node, "kind") != "CallOperatorWriteNode" || !a.present)
    return Dispatch<StatementResult>::declined();
  const Borrow borrow = c.borrows.at(a.reference);
  if (!c.rmwExempt(ReadOrigin{a.map, borrow.key, a.reference}, a.map))
    return Dispatch<StatementResult>::declined();
  auto name = field(node, "strings", "name").str();
  auto op = field(node, "strings", "binary_operator");
  if (op != "+" && op != "-")
    return (void)c.diagnostic(node, "SB001", "UnsupportedConstruct",
        "`." + name + " " + op.str() +
        "= …` is not accepted on a per-CPU record member — only `+=` and `-=` (P009 §2)",
        true), Dispatch<StatementResult>::error();
  if (failed(loadKnown(c, a))) return Dispatch<StatementResult>::error();
  auto f = member(*a.layout, name);
  if (!f)
    return (void)reject(c, node, "SB002", "record " + a.layout->name +
        " has no member `" + name + "`"), Dispatch<StatementResult>::error();
  if (f->padding)
    return (void)reject(c, node, "SB024", "`" + f->name +
        "` is padding — it is neither read nor written on the eBPF side (P006 §2)"),
        Dispatch<StatementResult>::error();
  auto rhs = c.ref(node, "value");
  // Go hash.go perCPUAdd calls noteFlow here. E019 owns interprocedural
  // flow summaries; this path keeps the existing local reference provenance.
  for (const auto &origin : c.origins(rhs))
    if (origin.domain == ReadOrigin::Domain::Map && origin.ref == a.reference)
      return (void)reject(c, node, "SB019", "the delta of `" + a.reference +
          ".load." + f->name + " " + op.str() +
          "= …` reads the same entry — use a delta that does not read `" +
          a.reference + "` (P009 §2)"), Dispatch<StatementResult>::error();
  auto checked = checkRecordMemberValue(c, rhs, *a.layout, *f);
  if (failed(checked)) return Dispatch<StatementResult>::error();
  if (c.probing) return Dispatch<StatementResult>::handled({1});
  auto loc = outputLoc(node);
  auto type = c.builder.getIntegerType(f->bits);
  Value before = ebpf::RefFieldLoadOp::create(c.builder, loc, type,
      borrow.value, f->name, false);
  auto delta = emitRecordMemberValue(c, *checked, *f);
  if (failed(delta)) return Dispatch<StatementResult>::error();
#ifdef SPINEL_E041_TEST_ADD_AS_SUB
  bool subtract = true;
#else
  bool subtract = op == "-";
#endif
  Value after = subtract
      ? arith::SubIOp::create(c.builder, loc, before, *delta).getResult()
      : arith::AddIOp::create(c.builder, loc, before, *delta).getResult();
  ebpf::RefFieldStoreOp::create(c.builder, loc, borrow.value, f->name, after, false);
  for (auto &record : c.records)
    if (record.name == a.layout->name) record.used = true;
  return Dispatch<StatementResult>::handled({1});
}
Dispatch<StatementResult> statement(Consumer &c, ArrayRef<Operation *> list,
                                    size_t at, unsigned) {
  auto node = list[at];
  auto name = field(node, "strings", "name");
  auto receiver = c.ref(node, "receiver");
if(name.ends_with("=")) {
  auto cur=receiver;unsigned depth=0;
  while(text(cur,"kind")=="CallNode"&&field(cur,"strings","name")!="load"){++depth;cur=c.ref(cur,"receiver");}
  auto variable=c.ref(cur,"receiver");
  if(depth&&text(cur,"kind")=="CallNode"&&field(cur,"strings","name")=="load"&&text(variable,"kind")=="LocalVariableReadNode"&&c.bindings.count("gkernel.ptr:"+field(variable,"strings","name").str()))
    return (void)c.diagnostic(node,"SB033","KernelTypeShape","`"+name.str()+" v` writes a kernel struct member through a member path — a member path is read only (E154)",true),Dispatch<StatementResult>::error();
}
  bool atomic = name == "atomic_add" && text(receiver, "kind") == "LocalVariableReadNode";
  bool indexed = name == "[]=";
  auto fieldNode = indexed ? receiver : node;
  auto a = atomic ? std::optional<Access>{} : access(c, c.ref(fieldNode, "receiver"));
  if (atomic) {
    auto ref = field(receiver, "strings", "name").str();
    auto found = c.borrows.find(ref);
    if (found != c.borrows.end()) {
      auto layout = lookupRecordLayout(c, c.maps[found->second.map].valueRecord);
      if (layout) a = Access{ref, found->second.map, layout, nullptr, true};
    }
  }
  if (!a) return Dispatch<StatementResult>::declined();
  auto kind = text(node, "kind");
  auto perCPU = perCPUAdd(c, node, *a);
  if (perCPU.state != Disposition::Declined) return perCPU;
  if (kind == "CallOperatorWriteNode" || kind == "CallOrWriteNode" || kind == "CallAndWriteNode")
    return (void)reject(c, node, "SB019", "`." + name.str() + " " +
        field(node, "strings", "binary_operator").str() +
        "= …` on a record member reads and writes the map value — concurrent CPUs lose updates; use `p.atomic_add(:" + name.str() + ", d)` (P006 §2)"), Dispatch<StatementResult>::error();
  if (!atomic && !indexed && !name.ends_with("=")) return Dispatch<StatementResult>::declined();
  auto args = c.args(node);
  if (atomic && ((args.size() != 2 && args.size() != 3) || text(args[0], "kind") != "SymbolNode"))
    return (void)reject(c, node, "SB002", "`" + a->reference +
        ".atomic_add` takes a member Symbol literal and a delta (`" + a->reference +
        ".atomic_add(:member, d)` — an array member also takes the index: `" +
        a->reference + ".atomic_add(:member, k, d)`) (P006 §2・P016)"), Dispatch<StatementResult>::error();
  std::string fieldName = atomic ? c.spelling(args[0], true).str()
      : indexed ? field(fieldNode, "strings", "name").str() : name.drop_back().str();
  auto f = member(*a->layout, fieldName);
  if (!f || (atomic && f->padding))
    return (void)reject(c, atomic ? args[0] : node, "SB002", "record " + a->layout->name +
        " has no member `" + fieldName + (atomic ? "` to add to" : "`")), Dispatch<StatementResult>::error();
  if (f->padding)
    return (void)reject(c, node, "SB024", "`" + f->name +
        "` is padding — it is neither read nor written on the eBPF side (P006 §2)"), Dispatch<StatementResult>::error();
  if (atomic && failed(c.known(node, CalleePolicy{"RecordRef#atomic_add"}))) return Dispatch<StatementResult>::error();
  if (!atomic && failed(loadKnown(c, *a))) return Dispatch<StatementResult>::error();
  if (atomic && f->bits != 32 && f->bits != 64)
    return (void)reject(c, args[0], "SB024", "member " + f->name + " is " + f->type +
        " — atomic_add needs a 32- or 64-bit member (BPF has no narrower atomic add) (P006 §2)"), Dispatch<StatementResult>::error();
  if ((!atomic && args.size() != (indexed ? 2 : 1)))
    return (void)reject(c, node, "SB002", indexed ? "an element write is `" +
        a->reference + ".load." + f->name + "[k] = v` (P016)" : "a member write takes one value"), Dispatch<StatementResult>::error();
  std::string path = f->name;
  Expr variable;
  bool element = indexed || (atomic && f->count);
  if (element) {
    if (!f->count)
      return (void)reject(c, node, "SB002", "member " + f->name + " of record " +
          a->layout->name + " is not an array — `[]=` is for array members (P016)"), Dispatch<StatementResult>::error();
    if (atomic && args.size() != 3)
      return (void)reject(c, node, "SB002", "an array atomic add needs a literal index and delta"), Dispatch<StatementResult>::error();
    auto indexNode = args[atomic ? 1 : 0];
    if (text(indexNode, "kind") == "IntegerNode") {
      auto index = literalIndex(c, indexNode, *a, *f);
      if (failed(index)) return Dispatch<StatementResult>::error();
      path += "[" + std::to_string(*index) + "]";
    } else if (atomic) {
      return (void)reject(c, indexNode, "SB031", "`" + a->reference +
          ".atomic_add(:" + f->name + ", k, d)` needs a literal index — bpf-mlir has no atomic add on a variable-index element; use a per-CPU record map (`BPF::PerCpuRecordMap`, then `" +
          a->reference + ".load." + f->name + "[i] += …` is not shared) or a literal index (P016)"), Dispatch<StatementResult>::error();
    } else {
      auto index = variableIndex(c, indexNode, *a, *f);
      if (failed(index)) return Dispatch<StatementResult>::error();
      variable = *index;
    }
  } else {
    auto copy = checkKernelRecordCopy(c, args.back(), *a->layout, *f, false, node);
    if (copy.state == Disposition::Declined)
      copy = checkTracepointRecordCopy(c, args.back(), *a->layout, *f, false, node);
    if (copy.state == Disposition::Error) return Dispatch<StatementResult>::error();
    if (copy.state == Disposition::Handled) {
      if (!c.probing) {
        auto checked = *copy.value;
        auto dest = c.borrows.at(a->reference).value;
        auto emitted = checked->kind == "gprobe.record-copy"
            ? emitTracepointRecordCopy(c, checked, dest, f->name, outputLoc(node))
            : emitKernelRecordCopy(c, checked, dest, f->name, outputLoc(node));
        if (failed(emitted)) return Dispatch<StatementResult>::error();
      }
      for (auto &record : c.records)
        if (record.name == a->layout->name) record.used = true;
      return Dispatch<StatementResult>::handled({1});
    }
    if (f->count) return (void)reject(c, node, "SB024", "the array member " + f->name +
        " is written by element (`" + a->reference + ".load." + f->name +
        "[k] = v`) — not as a whole (P016 E066)"), Dispatch<StatementResult>::error();
  }
  auto rhs = args.back();
  if (sameReferenceRead(c, rhs, *a)) {
    std::string message = atomic ? "`" + a->reference + ".atomic_add(:" + f->name +
        ", …)` adds a value read from the same entry — concurrent CPUs interleave the read and the add; use a delta that does not read `" + a->reference + "` (P015 E063)"
      : "`" + a->reference + ".load." + f->name +
        (element ? "[…] = …` stores a value read from the same map entry — concurrent CPUs lose updates; use `" + a->reference + ".atomic_add(:" + f->name + ", k, d)` (P016)"
                 : " = …` stores a value read from the same map entry — concurrent CPUs lose updates; use `" + a->reference + ".atomic_add(:" + f->name + ", d)` (P006 §2)");
    return (void)reject(c, node, "SB019", message), Dispatch<StatementResult>::error();
  }
  auto checked = checkRecordMemberValue(c, rhs, *a->layout, *f);
  if (failed(checked)) return Dispatch<StatementResult>::error();
  if (failed(noteSubprogramWrite(c, node,
          {a->map, std::nullopt, a->reference, ReadOrigin::Domain::Map}, c.origins(rhs))))
    return Dispatch<StatementResult>::error();
  if (c.probing) return Dispatch<StatementResult>::handled({1});
  Value index;
  if (variable) { index = c.emitScalar(variable); if (!index) return Dispatch<StatementResult>::error(); }
  auto value = emitRecordMemberValue(c, *checked, *f);
  if (failed(value)) return Dispatch<StatementResult>::error();
  auto borrowed = c.borrows.at(a->reference).value;
  if (variable) {
    auto loc = outputLoc(node);
    index = index32(c, index, loc);
    auto op = ebpf::RefIndexOp::create(c.builder, loc, TypeRange{}, borrowed, f->name, ValueRange{index});
    OpBuilder::InsertionGuard guard(c.builder);
    auto *yes = new Block(); op.getInRange().push_back(yes);
    auto elem = yes->addArgument(ebpf::ElemType::get(c.ctx, c.builder.getIntegerType(f->bits)), c.builder.getUnknownLoc());
    c.builder.setInsertionPointToStart(yes);
    ebpf::ElemStoreOp::create(c.builder, loc, elem, *value, false);
    ebpf::YieldOp::create(c.builder, loc, ValueRange{});
    auto *no = new Block(); op.getOutOfRange().push_back(no);
    c.builder.setInsertionPointToStart(no);
    ebpf::YieldOp::create(c.builder, loc, ValueRange{});
  } else if (atomic) ebpf::RefFieldAtomicAddOp::create(c.builder, outputLoc(node), borrowed, path, *value);
  else ebpf::RefFieldStoreOp::create(c.builder, outputLoc(node), borrowed, path, *value, false);
  for (auto &record : c.records)
    if (record.name == a->layout->name) record.used = true;
  return Dispatch<StatementResult>::handled({1});
}
} // namespace
void registerRecordMembers(Registry &registry) {
  registry.operatorChecks.push_back([](Consumer &c, Operation *node) {
    static const std::vector<std::string> operators = {"+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>", "==", "!=", "<", "<=", ">", ">=", "-@", "~", "!"};
    auto name = field(node, "strings", "name");
    if (!llvm::is_contained(operators, name.str())) return Dispatch<bool>::declined();
    auto receiver = c.ref(node, "receiver");
    if (text(receiver, "kind") != "CallNode" || !c.args(receiver).empty() || c.ref(receiver, "block")) return Dispatch<bool>::declined();
    auto load = c.ref(receiver, "receiver");
    auto a = access(c, load);
    if (!a || !a->present || !c.args(load).empty() || c.ref(load, "block")) return Dispatch<bool>::declined();
    auto f = member(*a->layout, field(receiver, "strings", "name"));
    if (!f || f->padding) return Dispatch<bool>::declined();
    if (failed(c.known(node, false))) return Dispatch<bool>::error();
    auto &items = c.evidence[c.id(node)];
    if (items.size() != 1 || text(items.front(), "name") != name)
      return (void)c.error(node, "record-member operator needs a single matching call evidence"), Dispatch<bool>::error();
    auto callee = text(items.front(), "callee");
    if (!callee.empty())
      return (void)c.diagnostic(node, "SB009", "OperatorRedefined", "operator `" + name.str() +
          "` resolves to the user definition " + callee.str() + " — redefined operators are refused", true), Dispatch<bool>::error();
    auto dispatch = text(items.front(), "dispatch");
    if (dispatch != "direct" && dispatch != "boxed")
      return (void)c.error(node, "record-member operator dispatch is neither direct nor boxed"), Dispatch<bool>::error();
    return Dispatch<bool>::handled(true);
  });
  registry.addExpression("CallNode", readMember);
  registry.addEmitter("record.field", [](Consumer &c, const Expr &e) { return emitField(c, e); });
  for (unsigned bits : {8u, 16u, 32u, 64u})
    registry.addEmitter("record.field.i" + std::to_string(bits),
        [bits](Consumer &c, const Expr &e) { return emitField(c, e, bits); });
  for (auto kind : {"CallNode", "CallOperatorWriteNode", "CallOrWriteNode", "CallAndWriteNode"})
    registry.addStatement(kind, statement);
}
} // namespace spinel::consumer
