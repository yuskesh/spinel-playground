#include "spinel/Conversion/RecordValue.h"
#include "spinel/Conversion/Subprograms.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/Support/FormatVariadic.h"

namespace spinel::consumer {
namespace {
struct MapClass { const char *name, *kind; bool hash; };
const MapClass classes[] = {
    {"RecordMap", "array", false},
    {"PerCpuRecordMap", "percpu_array", false},
    {"RecordHashMap", "hash", true},
    {"LruRecordHashMap", "lru_hash", true},
    {"PerCpuRecordHashMap", "percpu_hash", true}};
std::string quote(StringRef value) {
  return llvm::formatv("{0}", llvm::json::Value(value)).str();
}
Dispatch<bool> reject(Consumer &c, Operation *node, StringRef code,
                      const std::string &message) {
  (void)c.diagnostic(node, code, code == "SB013" ? "MapDeclShape"
                                  : code == "SB007" ? "ReservedName" : "RecordShape",
                     message);
  return Dispatch<bool>::error();
}
RecordLayoutPtr sample(Consumer &c, Operation *node, bool hash) {
  auto name = c.constant(c.ref(node, "receiver"));
  auto layout = lookupRecordLayout(c, name);
  const std::string plan = hash ? "P008 §1" : "P006 §1";
  if (field(node, "strings", "name") != "new" || !layout) {
    (void)reject(c, node, "SB024",
        "the sample must be `S.new(0, …)` of a record S declared with BPF.record (" + plan + ")");
    return {};
  }
  auto args = c.args(node);
  if (args.size() != layout->fields.size()) {
    (void)reject(c, node, "SB024", "the sample must give all " +
        std::to_string(layout->fields.size()) + " members of " + name +
        (hash ? " explicitly (upstream_suspects S5) (P008 §1)"
              : " explicitly (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5)"));
    return {};
  }
  const std::string zero = hash
      ? "the sample's members must be the literal 0 — it is a sample of the type, not an initial value (P008 §1)"
      : "the sample's members must be the literal 0 — it is a sample of the type, not an initial value (array entries start as 0 in the kernel) (P006 §1)";
  if (failed(checkRecordSample(c, args, *layout, zero,
                               hash ? SampleSite::RecordKey : SampleSite::RecordMap)))
    return {};
  return layout;
}
Dispatch<bool> declare(Consumer &c, Operation *node, const MapClass &cls) {
  auto call = c.ref(node, "value");
  auto constant = field(node, "strings", "name").str();
  for (const auto &map : c.maps)
    if (map.name == constant)
      return reject(c, node, "SB013", "constant " + constant + " is assigned twice");
  auto args = c.args(call);
  for (auto arg : args)
    if (text(arg, "kind") == "CallNode" &&
        recordDeclarationFailed(c, c.constant(c.ref(arg, "receiver")))) {
      c.dependentDeclarationErrors.insert(c.id(node));
      return Dispatch<bool>::error(); // The record's own rejection takes priority.
    }
  const std::string shape = cls.hash
      ? "a hash map is declared as `" + constant + " = BPF::" + cls.name +
        ".new(\"" + constant + "\", key, value, max_entries)` with literal arguments — key is :u32 / :u64 / :i32 / :i64 or a record sample `S.new(0, …)`, value is a record sample `S.new(0, …)` (P008 §1)"
      : "a record map is declared as `" + constant + " = BPF::RecordMap.new(\"" +
        constant + "\", S.new(0, …), max_entries)` with literal arguments";
  const size_t count = cls.hash ? 4 : 3, valueIndex = cls.hash ? 2 : 1;
  if (args.size() != count || text(args[0], "kind") != "StringNode" ||
      text(args.back(), "kind") != "IntegerNode" ||
      (!cls.hash && text(args[1], "kind") != "CallNode"))
    return reject(c, node, "SB013", shape);
  auto name = c.spelling(args[0], false).str();
  if (name != constant)
    return reject(c, args[0], "SB013", "the map name " + quote(name) +
        " differs from its constant " + constant +
        " — both sides look the map up by this name, so they must be the same");
  MapDecl map;
  map.node = node; map.name = name; map.kind = cls.kind; map.className = cls.name;
  if (cls.hash) {
    auto key = args[1];
    if (text(key, "kind") == "SymbolNode") {
      auto type = c.spelling(key, true);
      if (type != "u32" && type != "u64" && type != "i32" && type != "i64")
        return reject(c, key, "SB013",
            "the key type must be :u32, :u64, :i32 or :i64 (8- and 16-bit keys are outside P008), got :" + type.str());
      map.keyBits = type.ends_with("32") ? 32 : 64;
      map.keySigned = type.starts_with("i");
    } else if (text(key, "kind") == "CallNode") {
      auto layout = sample(c, key, true);
      if (!layout) return Dispatch<bool>::error();
      map.keyRecord = layout->name;
      map.keyType = ebpf::RecordType::get(c.ctx, layout->name, layout->size);
    } else return reject(c, key, "SB013", shape);
  }
  if (text(args[valueIndex], "kind") != "CallNode") {
    const std::string other = std::string(cls.name) == "RecordHashMap" ? "HashMap"
        : std::string(cls.name) == "LruRecordHashMap" ? "LruHashMap" : "PerCpuHashMap";
    return reject(c, args[valueIndex], "SB013", "BPF::" + std::string(cls.name) +
        " takes a record sample `S.new(0, …)` as its value — integer values use BPF::" + other + " (P008 §1)");
  }
  auto layout = sample(c, args[valueIndex], cls.hash);
  if (!layout) return Dispatch<bool>::error();
  map.valueRecord = layout->name;
  map.valueType = ebpf::RecordType::get(c.ctx, layout->name, layout->size);
  uint64_t entries;
  auto raw = text(args.back(), "literal_decimal");
  if (raw.getAsInteger(10, entries) || !entries || entries > UINT32_MAX)
    return reject(c, args.back(), "SB013",
        "max_entries must be a positive integer below 2^32, got " + raw.str());
  if (StringRef(name).starts_with("spinelbpf_"))
    return reject(c, node, "SB007", "map name " + quote(name) +
        " uses the reserved prefix spinelbpf_");
  if (failed(c.known(call, true))) return Dispatch<bool>::error();
  map.entries = entries;
  c.maps.push_back(std::move(map));
  return Dispatch<bool>::handled(true);
}
ExportValue schemaType(unsigned bits, bool sign, std::string record) {
  return ExportValue::write([bits, sign, record = std::move(record)](llvm::json::OStream &j) {
    j.object([&] {
      if (!record.empty()) {
        j.attribute("kind", "record_ref");
        j.attribute("symbol", record);
      } else {
        j.attribute("kind", "int");
        j.attribute("bits", bits);
        j.attribute("signed", sign);
        j.attribute("endianness", "little");
        j.attribute("alignment", bits / 8);
      }
    });
  });
}
Dispatch<ExportFields> exportRecordMap(Consumer &c, size_t index, bool schema) {
  const auto &map = c.maps[index];
  if (map.valueRecord.empty() && map.keyRecord.empty()) return Dispatch<ExportFields>::declined();
  ExportFields fields;
  fields.emplace_back(schema ? "symbol" : "name", map.name);
  fields.emplace_back("kind", map.kind);
  if (schema) {
    fields.emplace_back("key", schemaType(map.keyBits, map.keySigned, map.keyRecord));
    fields.emplace_back("value", schemaType(map.bits, map.isSigned, map.valueRecord));
    fields.emplace_back("max_entries", map.entries);
    fields.emplace_back("flags", int64_t(map.flags));
    fields.emplace_back("record", "");
    fields.emplace_back("note", "Ruby constant " + map.name);
  } else {
    fields.emplace_back("key", map.keyRecord.empty()
        ? std::string(map.keySigned ? "i" : "u") + std::to_string(map.keyBits)
        : "record:" + map.keyRecord);
    fields.emplace_back("value", map.valueRecord.empty()
        ? std::string(map.isSigned ? "i" : "u") + std::to_string(map.bits)
        : "record:" + map.valueRecord);
    fields.emplace_back("max_entries", map.entries);
    if (map.flags) fields.emplace_back("flags", map.flags);
  }
  return Dispatch<ExportFields>::handled(std::move(fields));
}
Dispatch<Expr> recordKey(Consumer &c, size_t index,
                         ArrayRef<Operation *> args, Operation *site) {
  const auto &map = c.maps[index];
  if (map.valueRecord.empty() && map.keyRecord.empty()) return Dispatch<Expr>::declined();
  if (args.size() != 1)
    return (void)c.diagnostic(site, "SB002", "UnsupportedCall",
        "a map key takes one argument", true), Dispatch<Expr>::error();
  auto result = std::make_shared<ScalarExpr>();
  result->node = args[0]; result->map = index;
  if (!map.keyRecord.empty()) {
    auto make = args[0];
    if (text(make, "kind") != "CallNode" ||
        field(make, "strings", "name") != "new" ||
        c.constant(c.ref(make, "receiver")) != map.keyRecord)
      return (void)c.diagnostic(make, "SB024", "RecordShape",
          "the key of " + map.name + " is `" + map.keyRecord +
          ".new(…)` written in the call itself — a record key is not kept in a local or built elsewhere (bpf-mlir: a record.make result does not cross blocks) (P008 §2)", true), Dispatch<Expr>::error();
    auto value = checkRecordMake(c, args[0], lookupRecordLayout(c, map.keyRecord),
        {map.name, RecordDestination::Kind::Map, ""});
    if (failed(value)) return Dispatch<Expr>::error();
    result->kind = "record.make";
    result->payload = *value;
  } else if (map.kind == "array" || map.kind == "percpu_array") {
    auto key = c.scalar(args[0]);
    if (failed(key) || failed(c.checked(range::checkArrayKey((*key)->range,
        c.rangeMap(index), {c.id(args[0])}), args[0])))
      return Dispatch<Expr>::error();
    result->kind = "record.array-key";
    result->args = {*key};
    result->range = (*key)->range;
    result->reads = (*key)->reads;
  } else return Dispatch<Expr>::declined(); // Group E owns integer hash keys.
  for (auto &record : c.records)
    if (record.name == map.keyRecord || record.name == map.valueRecord)
      record.used = true;
  return Dispatch<Expr>::handled(result);
}
Dispatch<StatementResult> updateRecord(Consumer &c, ArrayRef<Operation *> list,
                                        size_t at, unsigned) {
  auto node = list[at];
  if (field(node, "strings", "name") != "update") return Dispatch<StatementResult>::declined();
  auto name = c.constant(c.ref(node, "receiver"));
  auto found = std::find_if(c.maps.begin(), c.maps.end(),
      [&](const auto &map) { return map.name == name && !map.valueRecord.empty(); });
  if (found == c.maps.end()) return Dispatch<StatementResult>::declined();
  auto &map = *found;
  if (map.kind != "array" && map.kind != "percpu_array") return Dispatch<StatementResult>::declined();
  size_t index = static_cast<size_t>(found - c.maps.begin());
  auto layout = lookupRecordLayout(c, map.valueRecord);
  if (!layout) return (void)c.error(node, "record map layout missing"), Dispatch<StatementResult>::error();
  auto args = c.args(node);
  auto fail = [&](Operation *where, const std::string &message) {
    (void)c.diagnostic(where, "SB024", "RecordShape", message, true);
    return Dispatch<StatementResult>::error();
  };
  if (args.size() != 2 || c.ref(node, "block"))
    return (void)c.diagnostic(node, "SB002", "UnsupportedCall",
        "`update` takes exactly two arguments (key, " + layout->name + ".new(…))", true),
        Dispatch<StatementResult>::error();
  if (failed(c.knownMap(node, index))) return Dispatch<StatementResult>::error();
  auto key = c.checkedMapKey(index, {args[0]}, node);
  if (failed(key)) return Dispatch<StatementResult>::error();
  auto make = args[1];
  if (!c.origins(make).empty() && text(make, "kind") == "CallNode" &&
      field(make, "strings", "name") != "new") {
    auto alias = c.scalar(make);
    if (failed(alias)) return Dispatch<StatementResult>::error();
  }
  if (text(make, "kind") != "CallNode" || field(make, "strings", "name") != "new" ||
      c.constant(c.ref(make, "receiver")) != layout->name)
    return fail(make, "the value of " + map.name + ".update is `" + layout->name +
        ".new(…)` with every member (P006 §2)");
  if (llvm::any_of(layout->fields, [](const auto &f) { return bool(f.count); }))
    return fail(make, "record " + layout->name + " has an array member — `" +
        layout->name + ".new(…)` is not built on the eBPF side yet; write its members with `p = " +
        map.name + ".lookup(k)`, `if p`, `p.load.m[k] = v` (P016 E066)");
  auto members = c.args(make);
  for (auto member : members)
    if (text(member, "kind") == "KeywordHashNode" || text(member, "kind") == "SplatNode")
      return fail(member, layout->name + ".new takes positional arguments only (P006 §2)");
  if (members.size() != layout->fields.size())
    return fail(make, layout->name + ".new must give all " +
        std::to_string(layout->fields.size()) + " members explicitly, got " +
        std::to_string(members.size()) +
        " (an omitted member is nil, which Spinel types as Integer — upstream_suspects S5) (P006 §2)");
  std::optional<int64_t> literalKey;
  int64_t literal;
  if (text(args[0], "kind") == "IntegerNode" &&
      !text(args[0], "literal_decimal").getAsInteger(10, literal)) literalKey = literal;
  for (const auto &read : c.origins(make)) {
    if (read.domain != ReadOrigin::Domain::Map || read.map != index || c.rmwExempt(read, index)) continue;
    if (literalKey && read.key && *literalKey != *read.key) continue;
    return (void)c.diagnostic(node, "SB019", "SharedReadModifyWrite",
        "`" + map.name + ".update` stores a value read from the same map (`" + read.ref +
        ".load`) — concurrent CPUs lose updates (keys must be different literals to accept this form) (P006 §2)", true),
        Dispatch<StatementResult>::error();
  }
  auto value = checkRecordMake(c, make, layout, {map.name, RecordDestination::Kind::Map, ""});
  if (failed(value)) return Dispatch<StatementResult>::error();
  if (failed(noteSubprogramWrite(c, node,
          {index, literalKey, {}, ReadOrigin::Domain::Map}, c.origins(make))))
    return Dispatch<StatementResult>::error();
  map.used = true; c.usedMap = true;
  for (auto &record : c.records) if (record.name == layout->name) record.used = true;
  if (c.probing) return Dispatch<StatementResult>::handled({1});
  auto keyValue = c.emitMapKey(*key, index);
  auto recordValue = emitRecordMake(c, **value);
  if (!keyValue || failed(recordValue)) return Dispatch<StatementResult>::error();
  ebpf::MapUpdateOp::create(c.builder, outputLoc(node), map.value, keyValue, *recordValue);
  return Dispatch<StatementResult>::handled({1});
}
} // namespace
RecordLayoutPtr checkHashRecordSample(Consumer &c, Operation *node) {
  return sample(c, node, true);
}
void registerRecordMaps(Registry &registry) {
  registry.addStatement("CallNode", updateRecord);
  for (const auto &cls : classes)
    registry.addDeclaration({std::string("BPF::") + cls.name, "new"},
        [cls](Consumer &c, Operation *node) { return declare(c, node, cls); });
  for (auto kind : {"array", "percpu_array", "hash", "lru_hash", "percpu_hash"}) {
    registry.addMapExporter(kind, exportRecordMap);
    if (StringRef(kind) != "array") registry.addMapKey(kind, recordKey);
  }
  registry.addEmitter("record.array-key", [](Consumer &c, const Expr &e) {
    Value value = c.scalarKey(e->args.front());
    return value ? Dispatch<Value>::handled(value) : Dispatch<Value>::error();
  });
  registry.addEmitter("record.make", [](Consumer &c, const Expr &e) {
    auto checked = std::static_pointer_cast<const CheckedRecordValue>(e->payload);
    if (!checked) return (void)c.error(e->node, "record make payload missing"), Dispatch<Value>::error();
    auto value = emitRecordMake(c, *checked);
    return succeeded(value) ? Dispatch<Value>::handled(*value) : Dispatch<Value>::error();
  });
}
} // namespace spinel::consumer
