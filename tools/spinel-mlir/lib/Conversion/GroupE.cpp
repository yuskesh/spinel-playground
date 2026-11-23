// Group E (E017): hash / LRU hash / per-CPU hash and per-CPU array maps, the
// LPM trie, and the globals Config / OptionalConfig / Counter. The checks and
// their order follow spinel-bpf-mlir v0.6.0 internal/frontend hash.go,
// lpm.go, globals.go and analyze.go mapDecl; record-valued classes are group D.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/RecordValue.h"
#include "spinel/Conversion/GroupEEffects.h"
#include "spinel/Conversion/Subprograms.h"
#include "llvm/ADT/StringExtras.h"
#include <map>

namespace spinel::consumer {
namespace {
struct ClassInfo {
  const char *kind, *className;
};
const std::map<std::string, ClassInfo> kHashClasses = {
    {"BPF::HashMap", {"hash", "HashMap"}},
    {"BPF::LruHashMap", {"lru_hash", "LruHashMap"}},
    {"BPF::PerCpuHashMap", {"percpu_hash", "PerCpuHashMap"}},
};
const std::map<std::string, ClassInfo> kArrayLikeClasses = {
    {"BPF::LpmTrieMap", {"lpm_trie", "LpmTrieMap"}},
    {"BPF::PerCpuArrayMap", {"percpu_array", "PerCpuArrayMap"}},
};
const std::map<std::string, std::string> kGlobalClasses = {
    {"BPF::Config", "Config"},
    {"BPF::OptionalConfig", "OptionalConfig"},
    {"BPF::Counter", "Counter"},
};
const std::map<std::string, int64_t> kErrno = {
    {"BPF::ENOENT", -2}, {"BPF::E2BIG", -7}, {"BPF::ENOMEM", -12},
    {"BPF::EEXIST", -17}};
const char *const kLpmRecord = "spinelbpf_lpm_key4";

std::optional<std::pair<unsigned, bool>> mapIntType(StringRef s) {
  if (s == "u32") return std::make_pair(32u, false);
  if (s == "u64") return std::make_pair(64u, false);
  if (s == "i32") return std::make_pair(32u, true);
  if (s == "i64") return std::make_pair(64u, true);
  return std::nullopt;
}
// recordTypes of globals.go: the 8 / 16 / 32 / 64 bit integers.
std::optional<std::pair<unsigned, bool>> globalIntType(StringRef s) {
  for (unsigned bits : {8u, 16u, 32u, 64u}) {
    if (s == "u" + std::to_string(bits)) return std::make_pair(bits, false);
    if (s == "i" + std::to_string(bits)) return std::make_pair(bits, true);
  }
  return std::nullopt;
}
std::string quoted(StringRef s) { return "\"" + s.str() + "\""; }
bool isHashKind(StringRef kind) {
  return kind == "hash" || kind == "lru_hash" || kind == "percpu_hash";
}
bool isStatusOp(StringRef name) {
  return name == "update" || name == "insert" || name == "replace" ||
         name == "delete" || name == "add_or_init";
}
size_t findMap(Consumer &c, StringRef name) {
  for (size_t i = 0; i < c.maps.size(); ++i)
    if (c.maps[i].name == name)
      return i;
  return SIZE_MAX;
}
size_t findGlobal(Consumer &c, StringRef name) {
  for (size_t i = 0; i < c.globals.size(); ++i)
    if (c.globals[i].name == name)
      return i;
  return SIZE_MAX;
}
StringRef receiverConstant(Consumer &c, Operation *node) {
  auto recv = c.ref(node, "receiver");
  return recv && text(recv, "kind") == "ConstantReadNode"
             ? field(recv, "strings", "name")
             : StringRef();
}
math::Interval widthInterval(unsigned bits, bool isSigned) {
  if (bits >= 64)
    return isSigned ? math::Interval::fullI64()
                    : math::Interval{math::Integer::from(0),
                                     math::Integer::from(INT64_MAX)};
  if (!isSigned)
    return {math::Integer::from(0),
            math::Integer::from((int64_t(1) << bits) - 1)};
  return {math::Integer::from(-(int64_t(1) << (bits - 1))),
          math::Integer::from((int64_t(1) << (bits - 1)) - 1)};
}
std::string typeName(unsigned bits, bool isSigned) {
  return (isSigned ? "i" : "u") + std::to_string(bits);
}
ExportValue intObject(unsigned bits, bool isSigned) {
  return ExportValue::write([bits, isSigned](llvm::json::OStream &j) {
    j.object([&] {
      j.attribute("kind", "int");
      j.attribute("bits", bits);
      j.attribute("signed", isSigned);
      j.attribute("endianness", "little");
      j.attribute("alignment", bits / 8);
    });
  });
}
Value castTo(OpBuilder &b, Location loc, Value v, unsigned bits,
             bool isSigned) {
  auto from = cast<IntegerType>(v.getType()).getWidth();
  auto to = b.getIntegerType(bits);
  if (from == bits)
    return v;
  if (from > bits)
    return arith::TruncIOp::create(b, loc, to, v);
  return isSigned ? arith::ExtSIOp::create(b, loc, to, v).getResult()
                  : arith::ExtUIOp::create(b, loc, to, v).getResult();
}

// -- declarations ---------------------------------------------------------
Dispatch<bool> declareHash(Consumer &c, Operation *n, const ClassInfo &hc) {
  auto call = c.ref(n, "value");
  auto constName = field(n, "strings", "name").str();
  if (findMap(c, constName) != SIZE_MAX)
    return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                              "constant " + constName + " is assigned twice"),
           Dispatch<bool>::error();
  auto as = c.args(call);
  for (auto arg : as)
    if (text(arg, "kind") == "CallNode" &&
        recordDeclarationFailed(c, c.constant(c.ref(arg, "receiver")))) {
      c.dependentDeclarationErrors.insert(c.id(n));
      return Dispatch<bool>::error();
    }
  std::string shape = "`" + constName + " = BPF::" + hc.className +
                      ".new(\"" + constName +
                      "\", key, value, max_entries)` with literal arguments — "
                      "key is :u32 / :u64 / :i32 / :i64 or a record sample "
                      "`S.new(0, …)`, value is :u32 / :u64 / :i32 / :i64";
  if (as.size() != 4 || text(as[0], "kind") != "StringNode" ||
      text(as[3], "kind") != "IntegerNode")
    return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                              "a hash map is declared as " + shape +
                                  " (P008 §1)"),
           Dispatch<bool>::error();
  auto name = c.spelling(as[0], false).str();
  if (name != constName)
    return (void)c.diagnostic(
               as[0], "SB013", "MapDeclShape",
               "the map name " + quoted(name) + " differs from its constant " +
                   constName +
                   " — both sides look the map up by this name, so they must "
                   "be the same"),
           Dispatch<bool>::error();
  MapDecl m;
  m.node = n;
  m.name = name;
  m.kind = hc.kind;
  m.className = hc.className;
  if (text(as[1], "kind") == "SymbolNode") {
    auto t = mapIntType(c.spelling(as[1], true));
    if (!t)
      return (void)c.diagnostic(
                 as[1], "SB013", "MapDeclShape",
                 "the key type must be :u32, :u64, :i32 or :i64 (8- and "
                 "16-bit keys are outside P008), got :" +
                     c.spelling(as[1], true).str()),
             Dispatch<bool>::error();
    m.keyBits = t->first;
    m.keySigned = t->second;
  } else if (text(as[1], "kind") == "CallNode") {
    auto layout = checkHashRecordSample(c, as[1]);
    if (!layout) return Dispatch<bool>::error();
    m.keyRecord = layout->name;
    m.keyType = ebpf::RecordType::get(c.ctx, layout->name, layout->size);
  } else {
    return (void)c.diagnostic(as[1], "SB013", "MapDeclShape",
                              "a hash map is declared as " + shape +
                                  " (P008 §1)"),
           Dispatch<bool>::error();
  }
  if (text(as[2], "kind") == "SymbolNode") {
    auto t = mapIntType(c.spelling(as[2], true));
    if (!t)
      return (void)c.diagnostic(
                 as[2], "SB013", "MapDeclShape",
                 "the value type must be :u32, :u64, :i32 or :i64 (8- and "
                 "16-bit values are outside P008), got :" +
                     c.spelling(as[2], true).str()),
             Dispatch<bool>::error();
    m.bits = t->first;
    m.isSigned = t->second;
  } else {
    std::string counterpart = std::string(hc.className) == "HashMap"
                                  ? "RecordHashMap"
                              : std::string(hc.className) == "LruHashMap"
                                  ? "LruRecordHashMap"
                                  : "PerCpuRecordHashMap";
    return (void)c.diagnostic(as[2], "SB013", "MapDeclShape",
                              std::string("BPF::") + hc.className +
                                  " takes an integer type as its value — "
                                  "record values use BPF::" +
                                  counterpart + " (P008 §1)"),
           Dispatch<bool>::error();
  }
  auto entries = c.integer(as[3]);
  if (failed(entries))
    return Dispatch<bool>::error();
  if (*entries <= 0 || uint64_t(*entries) > UINT32_MAX)
    return (void)c.diagnostic(as[3], "SB013", "MapDeclShape",
                              "max_entries must be a positive integer below "
                              "2^32, got " +
                                  std::to_string(*entries)),
           Dispatch<bool>::error();
  if (StringRef(name).starts_with("spinelbpf_"))
    return (void)c.diagnostic(n, "SB007", "ReservedName",
                              "map name " + quoted(name) +
                                  " uses the reserved prefix spinelbpf_"),
           Dispatch<bool>::error();
  if (failed(c.known(call, true)))
    return Dispatch<bool>::error();
  m.entries = *entries;
  c.maps.push_back(std::move(m));
  return Dispatch<bool>::handled(true);
}

Dispatch<bool> declareArrayLike(Consumer &c, Operation *n,
                                const ClassInfo &ac) {
  bool lpm = StringRef(ac.kind) == "lpm_trie";
  std::string shown = lpm ? ac.className : "ArrayMap";
  auto call = c.ref(n, "value");
  auto constName = field(n, "strings", "name").str();
  if (findMap(c, constName) != SIZE_MAX)
    return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                              "constant " + constName + " is assigned twice"),
           Dispatch<bool>::error();
  auto as = c.args(call);
  if (as.size() == 3 && text(as[1], "kind") == "IntegerNode")
    return (void)c.diagnostic(
               as[1], "SB013", "MapDeclShape",
               "the value type is a Symbol since P002 — write `:u32`, `:u64`, "
               "`:i32` or `:i64` (e.g. `BPF::" +
                   shown + ".new(\"" + constName + "\", " +
                   (lpm ? ":u32" : ":u64") + ", n)`)"),
           Dispatch<bool>::error();
  if (as.size() != 3 || text(as[0], "kind") != "StringNode" ||
      text(as[1], "kind") != "SymbolNode" ||
      text(as[2], "kind") != "IntegerNode")
    return (void)c.diagnostic(
               n, "SB013", "MapDeclShape",
               "a map is declared as `" + constName + " = BPF::" + shown +
                   ".new(\"" + constName + "\", " +
                   (lpm ? ":u32|:i32" : ":u32|:u64|:i32|:i64") +
                   ", max_entries)` with literal arguments"),
           Dispatch<bool>::error();
  auto name = c.spelling(as[0], false).str();
  if (name != constName)
    return (void)c.diagnostic(
               as[0], "SB013", "MapDeclShape",
               "the map name " + quoted(name) + " differs from its constant " +
                   constName +
                   " — both sides look the map up by this name, so they must "
                   "be the same"),
           Dispatch<bool>::error();
  auto valueName = c.spelling(as[1], true).str();
  auto vt = mapIntType(valueName);
  if (lpm && vt && vt->first == 64)
    return (void)c.diagnostic(as[1], "SB013", "MapDeclShape",
                              "the value type of an lpm_trie map is :u32 or "
                              ":i32, got :" +
                                  valueName +
                                  " — 64-bit values are not accepted yet "
                                  "(E121)"),
           Dispatch<bool>::error();
  if (!vt)
    return (void)c.diagnostic(as[1], "SB013", "MapDeclShape",
                              std::string("the value type must be ") +
                                  (lpm ? ":u32 or :i32"
                                       : ":u32, :u64, :i32 or :i64") +
                                  ", got :" + valueName),
           Dispatch<bool>::error();
  auto entries = c.integer(as[2]);
  if (failed(entries))
    return Dispatch<bool>::error();
  if (*entries <= 0 || uint64_t(*entries) > UINT32_MAX)
    return (void)c.diagnostic(as[2], "SB013", "MapDeclShape",
                              "max_entries must be a positive integer below "
                              "2^32, got " +
                                  std::to_string(*entries)),
           Dispatch<bool>::error();
  if (StringRef(name).starts_with("spinelbpf_"))
    return (void)c.diagnostic(n, "SB007", "ReservedName",
                              "map name " + quoted(name) +
                                  " uses the reserved prefix spinelbpf_"),
           Dispatch<bool>::error();
  if (failed(c.known(call, true)))
    return Dispatch<bool>::error();
  MapDecl m;
  m.node = n;
  m.name = name;
  m.kind = ac.kind;
  m.className = ac.className;
  m.bits = vt->first;
  m.isSigned = vt->second;
  m.entries = *entries;
  if (lpm) {
    m.flags = 1;
    m.keyRecord = kLpmRecord;
    m.keyType = ebpf::RecordType::get(c.ctx, kLpmRecord, 8);
    // The library owns this record; usedRecordOrder exports it only when a
    // used LPM map refers to it. It has no synthetic Spinel source node.
    if (llvm::none_of(c.records, [](const RecordDecl &r) {
          return r.name == kLpmRecord;
        })) {
      auto shape = record::layout(kLpmRecord, {"prefixlen", "addr"},
          {{"prefixlen", "u32", {}}, {"addr", "u8", int64_t(4)}});
      if (shape.issue)
        return (void)c.error(n, "invalid library LPM key record layout"),
               Dispatch<bool>::error();
      auto layout = std::make_shared<const record::Layout>(std::move(shape.layout));
      c.records.push_back({n, kLpmRecord, false, {}, std::move(layout)});
    }
  }
  c.maps.push_back(std::move(m));
  return Dispatch<bool>::handled(true);
}

Dispatch<bool> declareGlobal(Consumer &c, Operation *n, StringRef cls) {
  auto call = c.ref(n, "value");
  auto constName = field(n, "strings", "name").str();
  if (findGlobal(c, constName) != SIZE_MAX)
    return (void)c.diagnostic(n, "SB029", "GlobalShape",
                              "constant " + constName + " is assigned twice"),
           Dispatch<bool>::error();
  auto as = c.args(call);
  if (as.size() != 2 || text(as[0], "kind") != "StringNode" ||
      text(as[1], "kind") != "SymbolNode")
    return (void)c.diagnostic(
               n, "SB029", "GlobalShape",
               "a global is declared as `" + constName + " = BPF::" +
                   cls.str() + ".new(\"" + constName +
                   "\", :u16)` with a String and a Symbol literal (P014)"),
           Dispatch<bool>::error();
  auto name = c.spelling(as[0], false).str();
  if (name != constName)
    return (void)c.diagnostic(
               as[0], "SB029", "GlobalShape",
               "the global name " + quoted(name) + " differs from its constant " +
                   constName +
                   " — both sides look the global up by this name (P014)"),
           Dispatch<bool>::error();
  auto typeText = c.spelling(as[1], true).str();
  auto t = globalIntType(typeText);
  if (!t)
    return (void)c.diagnostic(as[1], "SB029", "GlobalShape",
                              "the global's type must be one of :u8 … :u64 / "
                              ":i8 … :i64, got :" +
                                  typeText + " (P014)"),
           Dispatch<bool>::error();
  if (cls == "Counter" && t->first != 32 && t->first != 64)
    return (void)c.diagnostic(as[1], "SB029", "GlobalShape",
                              "a Counter is :u32, :u64, :i32 or :i64 (the "
                              "widths of ebpf.global.atomic_add), got :" +
                                  typeText + " (P014)"),
           Dispatch<bool>::error();
  if (StringRef(name).starts_with("spinelbpf_"))
    return (void)c.diagnostic(n, "SB007", "ReservedName",
                              "global name " + quoted(name) +
                                  " uses the reserved prefix spinelbpf_"),
           Dispatch<bool>::error();
  if (failed(c.known(call, true)))
    return Dispatch<bool>::error();
  GlobalDecl g;
  g.node = n;
  g.name = name;
  g.className = cls.str();
  g.section = cls == "Counter" ? "bss" : "rodata";
  g.bits = t->first;
  g.isSigned = t->second;
  c.globals.push_back(std::move(g));
  return Dispatch<bool>::handled(true);
}

// -- expressions ----------------------------------------------------------
// Reads of a Counter's value reaching a node directly or through locals
// (globals.go derivedRefs with the `@g<Const>` mark, E093).
bool readsGlobal(Consumer &c, Operation *node, size_t global) {
  if (!node)
    return false;
  if (text(node, "kind") == "LocalVariableReadNode") {
    auto found = c.locals.find(field(node, "strings", "name").str());
    return found != c.locals.end() &&
           llvm::any_of(found->second.expr->reads, [&](const ReadOrigin &r) {
             return r.domain == ReadOrigin::Domain::Global && r.map == global;
           });
  }
  if (text(node, "kind") == "CallNode" &&
      field(node, "strings", "name") == "value" &&
      receiverConstant(c, node) == c.globals[global].name)
    return true;
  for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
    auto v = cast<IntegerAttr>(attr.getValue()).getInt();
    if (v >= 0 && readsGlobal(c, c.nodes.lookup(v), global))
      return true;
  }
  for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
    for (auto v : cast<ArrayAttr>(attr.getValue()))
      if (readsGlobal(c, c.nodes.lookup(cast<IntegerAttr>(v).getInt()), global))
        return true;
  return false;
}

LogicalResult calleeIs(Consumer &c, Operation *node, StringRef expected,
                       StringRef sb011) {
  CalleePolicy policy;
  policy.expected = expected.str();
  policy.requireCallee = false;
  if (failed(c.known(node, policy)))
    return failure();
  auto callee = text(c.evidence[c.id(node)].front(), "callee");
  if (callee != expected)
    return c.diagnostic(node, "SB011", "ShadowedName",
                        sb011.str() + " resolves to " + quoted(callee) +
                            ", not BPF::" + expected.str());
  return success();
}

Dispatch<Expr> globalRead(Consumer &c, Operation *node, size_t gi) {
  auto &g = c.globals[gi];
  auto name = field(node, "strings", "name");
  bool counter = g.className == "Counter";
  if (name == "add")
    return (void)c.diagnostic(
               node, "SB029", "GlobalShape",
               counter ? "`" + g.name +
                             ".add(d)` is a statement, not a value "
                             "(ebpf.global.atomic_add returns nothing) (P014)"
                       : g.name + " is a " + g.className +
                             " (.rodata — set at load) and has no `add` — "
                             "only a Counter (.bss) adds (P014)",
               true),
           Dispatch<Expr>::error();
  if (name != "value" || !c.args(node).empty())
    return (void)c.diagnostic(node, "SB029", "GlobalShape",
                              "a global is read as `" + g.name +
                                  ".value` (and a Counter adds with `" +
                                  g.name + ".add(d)`), not `" + name.str() +
                                  "` (P014)",
                              true),
           Dispatch<Expr>::error();
  if (failed(calleeIs(c, node, g.className + "#value",
                      "`" + g.name + ".value`")))
    return Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  e->kind = "e017.gload";
  e->name = g.name;
  e->map = gi;
  bool wide = g.bits == 64 && !g.isSigned;
  math::Interval iv = widthInterval(g.bits, g.isSigned);
  if (wide) {
    auto max = math::Integer::parse("18446744073709551615");
    if (!max)
      return (void)c.rangeFailure(max.takeError(), node), Dispatch<Expr>::error();
    iv = {math::Integer::from(0), *max};
  }
  e->range = {math::MathInterval(iv), false, wide, range::Form::Gload};
  e->reads.push_back({gi, std::nullopt, "@g" + g.name,
                      ReadOrigin::Domain::Global});
  return Dispatch<Expr>::handled(e);
}

// The status placement of hash.go statusParentOK: a comparison operand
// (assignments are statements, handled below).
bool statusParentOK(Consumer &c, Operation *node) {
  auto p = c.parent(node);
  if (p && text(p, "kind") == "ArgumentsNode")
    p = c.parent(p);
  if (!p || text(p, "kind") != "CallNode")
    return false;
  auto op = field(p, "strings", "name");
  return op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" ||
         op == ">=";
}

LogicalResult hashRmw(Consumer &c, Operation *call, Operation *value,
                      size_t mi, const Expr &key, StringRef op) {
  auto &m = c.maps[mi];
  std::vector<ReadOrigin> reads = c.origins(value);
  std::sort(reads.begin(), reads.end(),
            [](const ReadOrigin &a, const ReadOrigin &b) { return a.ref < b.ref; });
  for (const auto &r : reads) {
    if (r.domain != ReadOrigin::Domain::Map || r.map != mi)
      continue;
    if (c.rmwExempt(r, mi))
      continue;
    if (r.key && key && key->kind == "literal" && *r.key != key->literal)
      continue;
    std::string msg =
        op == "add_or_init"
            ? "`" + m.name + ".add_or_init` adds a value read from the same "
                             "map (`" + r.ref + ".load`) — concurrent CPUs "
                             "interleave the read and the add; use a delta "
                             "that does not read " + m.name + " (P015 E063)"
            : "`" + m.name + "." + op.str() +
                  "` stores a value read from the same map (`" + r.ref +
                  ".load`) — concurrent CPUs lose updates; use `" + m.name +
                  ".add_or_init` or `" + r.ref + ".atomic_add` inside `if " +
                  r.ref + "` (P008 §2)";
    return c.diagnostic(call, "SB019", "SharedReadModifyWrite", msg, true);
  }
  return noteSubprogramWrite(c, call,
      {mi, std::nullopt, {}, ReadOrigin::Domain::Map}, reads);
}

Dispatch<Expr> statusExpr(Consumer &c, Operation *node, size_t mi) {
  auto &m = c.maps[mi];
  auto name = field(node, "strings", "name");
  // E045: Go hash.go:243 — before the callee.
  if (name == "add_or_init" && !m.valueRecord.empty())
    return (void)c.diagnostic(
               node, "SB002", "UnsupportedCall",
               "`" + m.name + ".add_or_init` takes integer values only — for "
               "a record value, `p = " + m.name + ".lookup(k)`, `if p`, "
               "`p.atomic_add(:member, d)`, with `" + m.name + ".insert(k, " +
               m.valueRecord + ".new(…))` for a new key (P008 §2)",
               true),
           Dispatch<Expr>::error();
  if (failed(calleeIs(c, node, m.className + "#" + name.str(),
                      "`" + name.str() + "`")))
    return Dispatch<Expr>::error();
  auto as = c.args(node);
  size_t want = name == "delete" ? 1 : 2;
  if (as.size() != want || c.ref(node, "block"))
    return (void)c.diagnostic(node, "SB002", "UnsupportedCall",
                              "`" + m.name + "." + name.str() +
                                  "` takes exactly " + std::to_string(want) +
                                  " argument(s)",
                              true),
           Dispatch<Expr>::error();
  auto key = c.checkedMapKey(mi, llvm::ArrayRef<Operation *>(as).take_front(1),
                             node);
  if (failed(key))
    return Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  e->kind = "e017.hstatus";
  e->op = name.str();
  e->map = mi;
  e->args = {*key};
  if (want == 2) {
    Expr integerKey = m.keyRecord.empty() ? (*key)->args.front() : Expr{};
    if (failed(hashRmw(c, node, as[1], mi, integerKey, name)))
      return Dispatch<Expr>::error();
    // E045: a record value is `S.new(…)` (Go hash.go:283 recordMake).
    if (!m.valueRecord.empty()) {
      auto value =
          checkRecordMake(c, as[1], lookupRecordLayout(c, m.valueRecord),
                          {m.name, RecordDestination::Kind::Map, ""});
      if (failed(value))
        return Dispatch<Expr>::error();
      e->payload = *value;
      for (const auto &member : (*value)->members)
        if (member)
          e->reads.insert(e->reads.end(), member->reads.begin(),
                          member->reads.end());
      e->range = {math::MathInterval(math::Interval::fullI64()), false, false,
                  range::Form::Computed};
      return Dispatch<Expr>::handled(e);
    }
    auto v = c.scalar(as[1]);
    if (failed(v))
      return Dispatch<Expr>::error();
    if (failed(c.checked(
            range::checkStoreValue((*v)->range, c.rangeMap(mi), {c.id(as[1])},
                                   name == "add_or_init" ? "delta" : "value"),
            as[1])))
      return Dispatch<Expr>::error();
    e->args.push_back(*v);
    e->reads = (*v)->reads;
  }
  e->range = {math::MathInterval(math::Interval::fullI64()), false, false,
              range::Form::Computed};
  return Dispatch<Expr>::handled(e);
}

Dispatch<Expr> expressionCall(Consumer &c, Operation *node) {
  auto recv = receiverConstant(c, node);
  if (recv.empty())
    return Dispatch<Expr>::declined();
  auto gi = findGlobal(c, recv);
  if (gi != SIZE_MAX)
    return globalRead(c, node, gi);
  auto mi = findMap(c, recv);
  auto name = field(node, "strings", "name");
  if (mi != SIZE_MAX && isHashKind(c.maps[mi].kind) && isStatusOp(name)) {
    if (!statusParentOK(c, node))
      return (void)c.diagnostic(
                 node, "SB026", "StatusIgnored",
                 "the status of `" + c.maps[mi].name + "." + name.str() +
                     "` is accepted only as `st = " + c.maps[mi].name + "." +
                     name.str() + "(…)` (read later), as an operand of a "
                     "comparison, or as `_ = " + c.maps[mi].name + "." +
                     name.str() + "(…)` — not as an argument, an arithmetic "
                     "operand or another value (P008 §2)",
                 true),
             Dispatch<Expr>::error();
    return statusExpr(c, node, mi);
  }
  return Dispatch<Expr>::declined();
}

Dispatch<Expr> expressionConstant(Consumer &c, Operation *node) {
  auto found = kErrno.find(c.constant(node));
  if (found == kErrno.end())
    return Dispatch<Expr>::declined();
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  e->kind = "literal";
  e->literal = found->second;
  auto out = c.outcome(e, range::literal(math::Integer::from(found->second),
                                         {c.id(node)}));
  if (failed(out))
    return Dispatch<Expr>::error();
  return Dispatch<Expr>::handled(*out);
}

// -- statements -----------------------------------------------------------
std::string statusIgnored(const MapDecl &m, StringRef op) {
  return "the status of `" + m.name + "." + op.str() +
         "` (0 or a negative errno such as BPF::EEXIST) is dropped — receive "
         "it as `st = " + m.name + "." + op.str() +
         "(…)` and read `st`, compare it (`if " + m.name + "." + op.str() +
         "(…) != 0`), or drop it explicitly with `_ = " + m.name + "." +
         op.str() + "(…)` (P008 §2)";
}

Dispatch<Expr> checkCounterImpl(Consumer &c, Operation *node, size_t gi) {
  auto &g = c.globals[gi];
  if (g.className != "Counter")
    return (void)c.diagnostic(node, "SB029", "GlobalShape",
                              g.name + " is a " + g.className +
                                  " (.rodata — set at load) and has no `add` "
                                  "— only a Counter (.bss) adds (P014)",
                              true),
           Dispatch<Expr>::error();
  auto as = c.args(node);
  if (as.size() != 1)
    return (void)c.diagnostic(node, "SB029", "GlobalShape",
                              "`" + g.name + ".add(d)` takes one Integer (P014)",
                              true),
           Dispatch<Expr>::error();
  if (failed(calleeIs(c, node, "Counter#add", "`" + g.name + ".add`")))
    return Dispatch<Expr>::error();
  if (readsGlobal(c, as[0], gi))
    return (void)c.diagnostic(
               node, "SB019", "SharedReadModifyWrite",
               "`" + g.name + ".add` adds a value read from " + g.name +
                   " itself (`" + g.name +
                   ".value`) — concurrent CPUs read the same old value and "
                   "lose updates; use a delta that does not read " + g.name +
                   " (E093)",
               true),
           Dispatch<Expr>::error();
  auto e = c.scalar(as[0]);
  if (failed(e))
    return Dispatch<Expr>::error();
  if ((*e)->range.isBool)
    return (void)c.diagnostic(as[0], "SB001", "UnsupportedConstruct",
                              "`" + g.name + ".add` takes an Integer, not a "
                                             "boolean",
                              true),
           Dispatch<Expr>::error();
  if ((*e)->range.wide && !(g.bits == 64 && !g.isSigned))
    return (void)c.diagnostic(
               as[0], "SB014", "SemanticGap",
               "a u64 value does not fit Ruby's Integer — add it only to a "
               ":u64 Counter, or narrow it first (`x & M` or `x >> K`) (P014)",
               true),
           Dispatch<Expr>::error();
  auto effect=std::make_shared<ScalarExpr>();
  effect->node=node;effect->kind="e017.counteradd";effect->map=gi;
  effect->args={*e};effect->reads=(*e)->reads;
  if (failed(noteSubprogramWrite(c, node,
          {gi, std::nullopt, {}, ReadOrigin::Domain::Global}, (*e)->reads)))
    return Dispatch<Expr>::error();
  return Dispatch<Expr>::handled(std::move(effect));
}
Dispatch<StatementResult> counterAdd(Consumer &c,Operation *node,size_t) {
  auto effect=checkCounterAdd(c,node);
  if(effect.state!=Disposition::Handled)
    return effect.state==Disposition::Error ? Dispatch<StatementResult>::error()
                                           : Dispatch<StatementResult>::declined();
  if(c.probing)return Dispatch<StatementResult>::handled({1});
  return failed(emitCounterAdd(c,*effect.value))
      ? Dispatch<StatementResult>::error()
      : Dispatch<StatementResult>::handled({1});
}

Dispatch<StatementResult> statementCall(Consumer &c,
                                        llvm::ArrayRef<Operation *> list,
                                        size_t i, unsigned) {
  auto node = list[i];
  auto name = field(node, "strings", "name");
  auto recv = c.ref(node, "receiver");
  if (recv && text(recv, "kind") == "LocalVariableReadNode" &&
      name == "atomic_add") {
    auto ref = field(recv, "strings", "name").str();
    auto found = c.borrows.find(ref);
    if (found != c.borrows.end() &&
        c.maps[found->second.map].kind == "lpm_trie")
      return (void)c.diagnostic(
                 node, "SB002", "UnsupportedCall",
                 "`" + ref + ".atomic_add` is not accepted on lpm_trie " +
                     c.maps[found->second.map].name +
                     " — an lpm_trie is read-only on the eBPF side (read the "
                     "value with `" + ref +
                     ".load`; user space writes it with `obj.lpm_put`) (E121)",
                 true),
             Dispatch<StatementResult>::error();
    return Dispatch<StatementResult>::declined();
  }
  auto constName = receiverConstant(c, node);
  if (constName.empty())
    return Dispatch<StatementResult>::declined();
  auto gi = findGlobal(c, constName);
  if (gi != SIZE_MAX && name == "add")
    return counterAdd(c, node, gi);
  auto mi = findMap(c, constName);
  if (mi == SIZE_MAX)
    return Dispatch<StatementResult>::declined();
  auto &m = c.maps[mi];
  if (m.kind == "lpm_trie" && name != "lookup" && name != "check")
    return (void)c.diagnostic(
               node, "SB002", "UnsupportedCall",
               "`" + m.name + "." + name.str() +
                   "` is not accepted — an lpm_trie is read-only on the eBPF "
                   "side (look it up with `p = " + m.name +
                   ".lookup(a0, a1, a2, a3)` then `if p`; user space writes it "
                   "with `obj.lpm_put`) (E121)",
               true),
           Dispatch<StatementResult>::error();
  // E054: map kinds without a plain atomic_add, before the callee check (Go
  // program.go:1550-1561).
#ifndef SPINEL_E054_TEST_NO_HASH_ATOMIC
  if (name == "atomic_add" && isHashKind(m.kind))
    return (void)c.diagnostic(
               node, "SB002", "UnsupportedCall",
               "`" + m.name + ".atomic_add(k, d)` is not accepted on a hash "
               "map — a missing key makes it do nothing silently; use `st = " +
                   m.name + ".add_or_init(k, d)` (adds, or creates the entry), "
                   "or `p.atomic_add(d)` inside `if p` after `p = " + m.name +
                   ".lookup(k)` (P008 §2)",
               true),
           Dispatch<StatementResult>::error();
#endif
  if (name == "atomic_add" && !m.valueRecord.empty())
    return (void)c.diagnostic(
               node, "SB002", "UnsupportedCall",
               "`" + m.name + ".atomic_add` is not accepted on a record map — "
               "add to a member with `p = " + m.name + ".lookup(k)`, `if p`, "
               "`p.atomic_add(:member, d)` (P006 §2)",
               true),
           Dispatch<StatementResult>::error();
  if (isHashKind(m.kind) && isStatusOp(name))
    return (void)c.diagnostic(node, "SB026", "StatusIgnored",
                              statusIgnored(m, name), true),
           Dispatch<StatementResult>::error();
  return Dispatch<StatementResult>::declined();
}

// hash.go statusLocalOK: the local holding a status is assigned once in the
// def and read at least once.
LogicalResult statusLocalOK(Consumer &c, Operation *write, const MapDecl &m,
                            StringRef op) {
  auto name = field(write, "strings", "name").str();
  unsigned writes = 0, reads = 0;
  llvm::DenseSet<Operation *> seen;
  auto walk = [&](auto &&self, Operation *n) -> void {
    if (!n || !seen.insert(n).second)
      return;
    if (field(n, "strings", "name") == name) {
      auto k = text(n, "kind");
      if (k == "LocalVariableWriteNode" || k == "LocalVariableOperatorWriteNode" ||
          k == "LocalVariableOrWriteNode" || k == "LocalVariableAndWriteNode")
        ++writes;
      else if (k == "LocalVariableReadNode")
        ++reads;
    }
    for (auto attr : n->getAttrOfType<DictionaryAttr>("refs")) {
      auto v = cast<IntegerAttr>(attr.getValue()).getInt();
      if (v >= 0)
        self(self, c.nodes.lookup(v));
    }
    for (auto attr : n->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto v : cast<ArrayAttr>(attr.getValue()))
        self(self, c.nodes.lookup(cast<IntegerAttr>(v).getInt()));
  };
  walk(walk, c.activeDef);
  if (writes != 1)
    return c.diagnostic(write, "SB026", "StatusIgnored",
                        "`" + name + "` holds the status of `" + m.name + "." +
                            op.str() + "` but is assigned " +
                            std::to_string(writes) +
                            " times — a status local is assigned once (give "
                            "each status its own name, so none is overwritten "
                            "before it is read) (P008 §2)",
                        true);
  if (reads == 0)
    return c.diagnostic(write, "SB026", "StatusIgnored",
                        "`" + name + "` holds the status of `" + m.name + "." +
                            op.str() + "` but is never read — check it (e.g. "
                            "`if " + name + " != 0`) or drop it explicitly "
                            "with `_ = " + m.name + "." + op.str() +
                            "(…)` (P008 §2)",
                        true);
  return success();
}

Dispatch<StatementResult> statementWrite(Consumer &c,
                                         llvm::ArrayRef<Operation *> list,
                                         size_t i, unsigned) {
  auto node = list[i];
  auto local = field(node, "strings", "name").str();
  auto e = checkStatusWrite(c, node);
  if (e.state != Disposition::Handled)
    return e.state == Disposition::Error ? Dispatch<StatementResult>::error()
                                         : Dispatch<StatementResult>::declined();
  // A probe checks only: emitScalar yields no value there by design (E028).
  Value v;
  if (!c.probing) {
    v = c.emitScalar(*e.value);
    if (!v)
      return Dispatch<StatementResult>::error();
  }
  if (local != "_")
    c.locals[local] = {*e.value, v};
  return Dispatch<StatementResult>::handled({1});
}

// -- map keys -------------------------------------------------------------
Dispatch<Expr> hashKey(Consumer &c, size_t mi, llvm::ArrayRef<Operation *> as,
                       Operation *site) {
  auto &m = c.maps[mi];
  if (!m.keyRecord.empty()) return Dispatch<Expr>::declined();
  if (as.size() != 1)
    return (void)c.error(site, "hash map key takes one argument"),
           Dispatch<Expr>::error();
  auto k = c.scalar(as[0]);
  if (failed(k))
    return Dispatch<Expr>::error();
  if ((*k)->range.isBool || (*k)->range.wide)
    return (void)c.diagnostic(as[0], "SB001", "UnsupportedConstruct",
                              "a map key must be an Integer (not a bool, not "
                              "an unnarrowed u64 value)",
                              true),
           Dispatch<Expr>::error();
  auto tr = widthInterval(m.keyBits, m.keySigned);
  auto iv = (*k)->range.interval.finite();
  if (!iv)
    return (void)c.rangeFailure(iv.takeError(), as[0]), Dispatch<Expr>::error();
  if (!iv->within(tr)) {
    auto type = typeName(m.keyBits, m.keySigned);
    if ((*k)->kind == "literal")
      return (void)c.diagnostic(as[0], "SB014", "SemanticGap",
                                "the key literal " + iv->lo.str() +
                                    " is outside " + tr.str() + " (the " +
                                    type + " key of " + m.name +
                                    "; Ruby would not wrap it)",
                                true),
             Dispatch<Expr>::error();
    return (void)c.diagnostic(as[0], "SB014", "SemanticGap",
                              "the key's range " + iv->str() +
                                  " does not fit the " + type + " key of " +
                                  m.name + " " + tr.str() +
                                  " — the key would be truncated silently; "
                                  "narrow it (e.g. `& 0xFFFF_FFFF`) (P008 §2)",
                              true),
           Dispatch<Expr>::error();
  }
  auto e = std::make_shared<ScalarExpr>();
  e->node = (*k)->node;
  e->kind = "e017.hkey";
  e->map = mi;
  e->args = {*k};
  e->range = (*k)->range;
  return Dispatch<Expr>::handled(e);
}

Dispatch<Expr> lpmKey(Consumer &c, size_t mi, llvm::ArrayRef<Operation *> as,
                      Operation *site) {
  auto &m = c.maps[mi];
  if (as.size() != 4)
    return (void)c.diagnostic(site, "SB002", "UnsupportedCall",
                              "`" + m.name +
                                  ".lookup` takes the 4 bytes of an IPv4 "
                                  "address (`" + m.name +
                                  ".lookup(a0, a1, a2, a3)` — e.g. `w.u8(30)` "
                                  "… `w.u8(33)`) (E121)",
                              true),
           Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>();
  e->node = site;
  e->kind = "e017.lpmkey";
  e->map = mi;
  auto byte = widthInterval(8, false);
  for (auto x : as) {
    auto v = c.scalar(x);
    if (failed(v))
      return Dispatch<Expr>::error();
    auto iv = (*v)->range.interval.finite();
    if (!iv)
      return (void)c.rangeFailure(iv.takeError(), x), Dispatch<Expr>::error();
    if ((*v)->range.wide || !iv->within(byte))
      return (void)c.diagnostic(
                 x, "SB014", "SemanticGap",
                 "the value's range " + iv->str() + " does not fit member " +
                     kLpmRecord + ".addr (u8 " + byte.str() +
                     ") — the store would truncate silently; narrow it (e.g. "
                     "`& 0xFF`) (P006 §2)",
                 true),
             Dispatch<Expr>::error();
    e->args.push_back(*v);
  }
  return Dispatch<Expr>::handled(e);
}

Dispatch<Expr> perCpuArrayKey(Consumer &c, size_t mi,
                              llvm::ArrayRef<Operation *> as, Operation *site) {
  if (as.size() != 1)
    return (void)c.error(site, "array map key takes one argument"),
           Dispatch<Expr>::error();
  auto k = c.scalar(as[0]);
  if (failed(k))
    return Dispatch<Expr>::error();
  if (failed(c.checked(range::checkArrayKey((*k)->range, c.rangeMap(mi),
                                            {c.id(as[0])}),
                       as[0])))
    return Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>();
  e->node = (*k)->node;
  e->kind = "e017.akey";
  e->map = mi;
  e->args = {*k};
  e->range = (*k)->range;
  return Dispatch<Expr>::handled(e);
}

// -- emitters -------------------------------------------------------------
Dispatch<Value> emitGlobalLoad(Consumer &c, const Expr &e) {
  auto &g = c.globals[e->map];
  g.used = true;
  auto loc = outputLoc(e->node);
  Value v = ebpf::GlobalLoadOp::create(c.builder, loc,
                                       c.builder.getIntegerType(g.bits),
                                       FlatSymbolRefAttr::get(c.ctx, g.name));
  return Dispatch<Value>::handled(castTo(c.builder, loc, v, 64, g.isSigned));
}
Dispatch<Value> emitHashKey(Consumer &c, const Expr &e) {
  auto &m = c.maps[e->map];
  auto k = e->args.front();
  auto loc = outputLoc(k->node);
  if (k->kind == "literal")
    return Dispatch<Value>::handled(
        arith::ConstantIntOp::create(c.builder, loc, k->literal, m.keyBits));
  Value v = c.emitScalar(k);
  if (!v)
    return Dispatch<Value>::error();
  return Dispatch<Value>::handled(castTo(c.builder, loc, v, m.keyBits, m.keySigned));
}
Dispatch<Value> emitArrayKey(Consumer &c, const Expr &e) {
  Value v = c.scalarKey(e->args.front());
  return v ? Dispatch<Value>::handled(v) : Dispatch<Value>::error();
}
Dispatch<Value> emitLpmKey(Consumer &c, const Expr &e) {
  auto loc = outputLoc(e->node);
  SmallVector<Value> values;
  values.push_back(arith::ConstantIntOp::create(c.builder, loc, 32, 32));
  record::FieldLayout byte;
  byte.name = "addr";
  byte.type = "u8";
  byte.bits = 8;
  for (auto &b : e->args) {
    auto v = emitRecordMemberValue(c, b, byte);
    if (failed(v))
      return Dispatch<Value>::error();
    values.push_back(*v);
  }
  auto fields = c.builder.getStrArrayAttr(
      {"prefixlen", "addr[0]", "addr[1]", "addr[2]", "addr[3]"});
  return Dispatch<Value>::handled(ebpf::RecordMakeOp::create(
      c.builder, loc, ebpf::RecordType::get(c.ctx, kLpmRecord, 8), fields,
      values));
}
// lookup → present: atomic_add, 0 / absent: insert (noexist); −EEXIST means
// another CPU inserted the key first, so look it up again (absent: −ENOENT).
// Every op takes the call's loc (Go's lowering).
Value emitAddOrInit(Consumer &c, const MapDecl &m, Location loc, Value key,
                    Value delta) {
  auto &b = c.builder;
  auto valueType = b.getIntegerType(m.bits);
  auto i64 = b.getI64Type();
  auto addOrStatus = [&]() {
    auto lookup = ebpf::MapLookupOp::create(
        b, loc, ebpf::MaybeRefType::get(c.ctx, valueType), m.value, key);
    auto check = ebpf::RefCheckOp::create(b, loc, TypeRange{i64},
                                          lookup.getResult());
    OpBuilder::InsertionGuard guard(b);
    auto *yes = new Block();
    check.getPresentRegion().push_back(yes);
    auto ref = yes->addArgument(ebpf::BorrowedType::get(c.ctx, valueType),
                                b.getUnknownLoc());
    b.setInsertionPointToStart(yes);
    ebpf::RefAtomicAddOp::create(b, loc, ref, delta);
    ebpf::YieldOp::create(
        b, loc, ValueRange{arith::ConstantIntOp::create(b, loc, 0, 64)});
    auto *no = new Block();
    check.getAbsentRegion().push_back(no);
    b.setInsertionPointToStart(no);
    return std::make_pair(check, no);
  };
  auto [check, no] = addOrStatus();
  {
    OpBuilder::InsertionGuard guard(b);
    b.setInsertionPointToStart(no);
    Value st = ebpf::MapTryUpdateOp::create(b, loc, i64, m.value, key, delta,
                                            "noexist");
    Value eexist = arith::ConstantIntOp::create(b, loc, -17, 64);
    Value raced = arith::CmpIOp::create(b, loc, arith::CmpIPredicate::eq, st,
                                        eexist);
    auto retry = ebpf::IfOp::create(b, loc, TypeRange{i64}, raced);
    auto *then = new Block();
    retry->getRegion(0).push_back(then);
    b.setInsertionPointToStart(then);
    auto [again, againNo] = addOrStatus();
    {
      OpBuilder::InsertionGuard inner(b);
      b.setInsertionPointToStart(againNo);
      ebpf::YieldOp::create(
          b, loc, ValueRange{arith::ConstantIntOp::create(b, loc, -2, 64)});
    }
    b.setInsertionPointAfter(again);
    ebpf::IfYieldOp::create(b, loc, ValueRange{again.getResult(0)});
    auto *other = new Block();
    retry->getRegion(1).push_back(other);
    b.setInsertionPointToStart(other);
    ebpf::IfYieldOp::create(b, loc, ValueRange{st});
    b.setInsertionPointAfter(retry);
    ebpf::YieldOp::create(b, loc, ValueRange{retry->getResult(0)});
  }
  return check.getResult(0);
}
Dispatch<Value> emitHashStatus(Consumer &c, const Expr &e) {
  auto &m = c.maps[e->map];
  auto loc = outputLoc(e->node);
  Value key = c.emitMapKey(e->args[0], e->map);
  if (!key)
    return Dispatch<Value>::error();
  if (e->op == "delete")
    return Dispatch<Value>::handled(
        ebpf::MapTryDeleteOp::create(c.builder, loc, c.builder.getI64Type(), m.value, key));
  Value value;
  if (!m.valueRecord.empty()) { // E045: record.make at the status (Go lower.go:1268)
    CheckedRecordValue checked =
        *std::static_pointer_cast<const CheckedRecordValue>(e->payload);
#ifdef SPINEL_E045_TEST_STATUS_RECORD_SWAP
    if (checked.members.size() >= 2) // E045 H6 (test build only)
      std::swap(checked.members[0], checked.members[1]);
#endif
    auto made = emitRecordMake(c, checked);
    if (failed(made))
      return Dispatch<Value>::error();
    value = *made;
  } else if (e->args[1]->kind == "literal") {
    // Go valueOperand: map-width constant at the literal's location.
    value = c.scalarStore(e->args[1], e->map);
    if (!value)
      return Dispatch<Value>::error();
  } else {
    value = c.emitScalar(e->args[1]);
    if (!value)
      return Dispatch<Value>::error();
    value = castTo(c.builder, loc, value, m.bits, m.isSigned);
  }
  if (e->op == "add_or_init")
    return Dispatch<Value>::handled(emitAddOrInit(c, m, loc, key, value));
  StringRef flags = e->op == "update" ? "any"
                    : e->op == "insert" ? "noexist"
                                        : "exist";
  return Dispatch<Value>::handled(
      ebpf::MapTryUpdateOp::create(c.builder, loc, c.builder.getI64Type(), m.value, key, value, flags));
}

// -- export ---------------------------------------------------------------
Dispatch<ExportFields> exportMap(Consumer &c, size_t mi, bool schema) {
  auto &m = c.maps[mi];
  bool lpm = m.kind == "lpm_trie";
  ExportFields f;
  if (schema) {
    f.emplace_back("symbol", m.name);
    f.emplace_back("kind", m.kind);
    if (lpm)
      f.emplace_back("key", ExportValue::write([](llvm::json::OStream &j) {
                       j.object([&] {
                         j.attribute("kind", "record_ref");
                         j.attribute("symbol", kLpmRecord);
                       });
                     }));
    else
      f.emplace_back("key", intObject(m.keyBits, m.keySigned));
    f.emplace_back("value", intObject(m.bits, m.isSigned));
    f.emplace_back("max_entries", m.entries);
    f.emplace_back("flags", int64_t(m.flags));
    f.emplace_back("record", "");
    f.emplace_back("note", "Ruby constant " + m.name);
  } else {
    f.emplace_back("name", m.name);
    f.emplace_back("kind", m.kind);
    f.emplace_back("key", lpm ? std::string("record:") + kLpmRecord
                              : typeName(m.keyBits, m.keySigned));
    f.emplace_back("value", typeName(m.bits, m.isSigned));
    f.emplace_back("max_entries", m.entries);
    if (m.flags)
      f.emplace_back("flags", int64_t(m.flags));
  }
  return Dispatch<ExportFields>::handled(std::move(f));
}
Dispatch<ExportFields> exportGlobal(Consumer &c, size_t gi, bool schema) {
  auto &g = c.globals[gi];
  ExportFields f;
  f.emplace_back("name", g.name);
  f.emplace_back("section", g.section);
  if (schema) {
    f.emplace_back("type", intObject(g.bits, g.isSigned));
    f.emplace_back("note", "Ruby constant " + g.name + " (" + g.className + ")");
  } else {
    f.emplace_back("type", typeName(g.bits, g.isSigned));
  }
  return Dispatch<ExportFields>::handled(std::move(f));
}
Dispatch<bool> unusedGlobal(Consumer &c, DeclarationRef d) {
  if (d.domain != DeclarationRef::Domain::Global)
    return Dispatch<bool>::declined();
  auto &g = c.globals[d.index];
  c.conditionalDiagnostic(
                      g.node, "SB013", "MapDeclShape",
                      "global " + g.name +
                          " is declared but no eBPF program reads or adds it "
                          "— it is left out of the ELF, the schema and "
                          "maps.json");
  return Dispatch<bool>::handled(true);
}
// hash.go perCPUExempt: a per-CPU map when every root is XDP.
bool perCpuExempt(const Consumer &c, const ReadOrigin &origin, size_t target) {
  if (origin.domain != ReadOrigin::Domain::Map || target >= c.maps.size())
    return false;
  auto kind = StringRef(c.maps[target].kind);
  if (!kind.starts_with("percpu_"))
    return false;
  if (c.activeKind != "xdp")
    return false;
  return c.allRootsXdp;
}
} // namespace

std::string discardedHashStatus(const MapDecl &map, StringRef op) {
  return statusIgnored(map, op);
}

Dispatch<Expr> checkStatusWrite(Consumer &c,Operation *node) {
  if(text(node,"kind")!="LocalVariableWriteNode")
    return Dispatch<Expr>::declined();
  auto value=c.ref(node,"value");
  if(!value || text(value,"kind")!="CallNode")
    return Dispatch<Expr>::declined();
  auto opName=field(value,"strings","name");
  auto mi=findMap(c,receiverConstant(c,value));
  if(mi==SIZE_MAX || !isHashKind(c.maps[mi].kind) || !isStatusOp(opName))
    return Dispatch<Expr>::declined();
  auto local=field(node,"strings","name");
  if(local!="_" && failed(statusLocalOK(c,node,c.maps[mi],opName)))
    return Dispatch<Expr>::error();
  return statusExpr(c,value,mi);
}
Dispatch<Expr> checkCounterAdd(Consumer &c,Operation *node) {
  ScopeGuard restore(c);
  if(text(node,"kind")!="CallNode" || field(node,"strings","name")!="add")
    return Dispatch<Expr>::declined();
  auto gi=findGlobal(c,receiverConstant(c,node));
  if(gi==SIZE_MAX)return Dispatch<Expr>::declined();
  return checkCounterImpl(c,node,gi);
}
LogicalResult emitCounterAdd(Consumer &c,const Expr &effect) {
  if(!effect || effect->kind!="e017.counteradd" ||
     effect->map>=c.globals.size() || effect->args.size()!=1)
    return c.error(effect?effect->node:nullptr,"invalid checked Counter.add effect");
  auto &g=c.globals[effect->map];
  Value v=c.emitScalar(effect->args[0]);
  if(!v)return failure();
  v=castTo(c.builder,outputLoc(effect->node),v,g.bits,g.isSigned);
  ebpf::GlobalAtomicAddOp::create(c.builder,outputLoc(effect->node),
                                FlatSymbolRefAttr::get(c.ctx,g.name),v);
  g.used=true;
  return success();
}

namespace {
// Go memberRead: `p.load.m` — a member read off a checked record borrow.
bool memberRead(Consumer &c, Operation *n) {
  if (text(n, "kind") != "CallNode" || !c.args(n).empty() || c.ref(n, "block"))
    return false;
  auto load = c.ref(n, "receiver");
  if (!load || text(load, "kind") != "CallNode" ||
      field(load, "strings", "name") != "load" || !c.args(load).empty())
    return false;
  auto local = c.ref(load, "receiver");
  return local && text(local, "kind") == "LocalVariableReadNode";
}

// Go hasMemberRead (program.go:1248): any member read in the subtree.
bool hasMemberRead(Consumer &c, Operation *n) {
  if (!n)
    return false;
  if (memberRead(c, n))
    return true;
  for (auto attr : {"receiver", "body", "left", "right"})
    if (hasMemberRead(c, c.ref(n, attr)))
      return true;
  for (auto arg : c.args(n))
    if (hasMemberRead(c, arg))
      return true;
  if (text(n, "kind") == "StatementsNode" || text(n, "kind") == "ParenthesesNode")
    for (auto s : c.array(n, "body"))
      if (hasMemberRead(c, s))
        return true;
  return false;
}

// E054: an operator whose single call evidence is not direct (Go callee,
// program.go:1300-1307 — unknown SB004). RecordMembers' check runs first and
// accepts boxed only for an operator on a member read itself (Go calleeOp).
Dispatch<bool> dynamicOperator(Consumer &c, Operation *node) {
  static const std::vector<std::string> operators = {
      "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>", "==", "!=",
      "<", "<=", ">", ">=", "-@", "~", "!"};
  auto name = field(node, "strings", "name");
  if (!llvm::is_contained(operators, name.str()))
    return Dispatch<bool>::declined();
  auto found = c.evidence.find(c.id(node));
  if (found == c.evidence.end() || found->second.size() != 1)
    return Dispatch<bool>::declined();
  auto record = found->second.front();
  auto dispatch = text(record, "dispatch");
  if (dispatch == "direct" || !text(record, "callee").empty())
    return Dispatch<bool>::declined();
  std::string candidates = "[";
  if (auto list = record->getAttrOfType<ArrayAttr>("candidates"))
    for (auto [i, v] : llvm::enumerate(list))
      if (auto s = dyn_cast<StringAttr>(v))
        candidates += (i ? " " : "") + s.getValue().str();
  candidates += "]";
  std::string hint;
#ifndef SPINEL_E054_TEST_NO_E065_HINT
  if (hasMemberRead(c, c.ref(node, "receiver")))
    hint = "; for an operator on a record member's arithmetic, assign it to "
           "a local first (`x = p.load.m & 0xFF`, then `x + 1`) (E065)";
#endif
  return (void)c.unknownDiagnostic(
             node, "SB004", "UnknownEdge",
             "`" + name.str() + "` is dispatched dynamically (" +
                 dispatch.str() + " " + candidates +
                 ") — the eBPF side needs a static call target" + hint,
             true),
         Dispatch<bool>::error();
}
} // namespace

void registerGroupE(Registry &r) {
  for (const auto &[receiver, info] : kHashClasses) {
    ClassInfo hc = info;
    r.addDeclaration({receiver, "new"}, [hc](Consumer &c, Operation *n) {
      return declareHash(c, n, hc);
    });
    r.addMapKey(hc.kind, hashKey);
    r.addMapExporter(hc.kind, exportMap);
  }
  for (const auto &[receiver, info] : kArrayLikeClasses) {
    ClassInfo ac = info;
    r.addDeclaration({receiver, "new"}, [ac](Consumer &c, Operation *n) {
      return declareArrayLike(c, n, ac);
    });
    r.addMapExporter(ac.kind, exportMap);
  }
  r.addMapKey("lpm_trie", lpmKey);
  r.addMapKey("percpu_array", perCpuArrayKey);
  for (const auto &[receiver, cls] : kGlobalClasses) {
    std::string name = cls;
    r.addDeclaration({receiver, "new"}, [name](Consumer &c, Operation *n) {
      return declareGlobal(c, n, name);
    });
  }
  r.addExpression("CallNode", expressionCall);
  r.addExpression("ConstantPathNode", expressionConstant);
  r.addStatement("CallNode", statementCall);
  // E054: after RecordMembers' operator check (ConsumerGroups.def order).
  r.operatorChecks.push_back(dynamicOperator);
  r.addStatement("LocalVariableWriteNode", statementWrite);
  r.addEmitter("e017.gload", emitGlobalLoad);
  r.addEmitter("e017.hkey", emitHashKey);
  r.addEmitter("e017.akey", emitArrayKey);
  r.addEmitter("e017.lpmkey", emitLpmKey);
  r.addEmitter("e017.hstatus", emitHashStatus);
  r.addGlobalExporter(exportGlobal);
  r.addUnusedDiagnostic(unusedGlobal);
  r.addRMWExemption(perCpuExempt);
}
} // namespace spinel::consumer
