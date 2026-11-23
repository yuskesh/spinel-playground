// Parse/canonically serialize the three-layer schema chosen on 2026-08-25. Refuse unknown keys,
// omissions, wrong versions, duplicates, overlaps, non-power-of-two alignments and unresolved
// references. Only extensions payload is uninterpreted and preserved.
#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <functional>
#include <set>

using namespace llvm;

namespace spbpf {

// Value-type implementation helpers.
bool IntType::operator==(const IntType &o) const {
  return bits == o.bits && isSigned == o.isSigned &&
         endianness == o.endianness && alignment == o.alignment;
}

ArrayType::ArrayType(const ArrayType &o) : count(o.count) {
  if (o.element)
    element = std::make_unique<Type>(*o.element);
}
ArrayType &ArrayType::operator=(const ArrayType &o) {
  if (this != &o) {
    count = o.count;
    element = o.element ? std::make_unique<Type>(*o.element) : nullptr;
  }
  return *this;
}
bool ArrayType::operator==(const ArrayType &o) const {
  if (count != o.count)
    return false;
  if (!element || !o.element)
    return element.get() == o.element.get();
  return *element == *o.element;
}

namespace {

Error err(const Twine &msg) {
  return createStringError(inconvertibleErrorCode(), msg);
}

bool isPowerOfTwo(uint64_t v) { return v != 0 && (v & (v - 1)) == 0; }

Error requireOnlyKeys(const json::Object &obj, ArrayRef<StringRef> allowed,
                      StringRef where) {
  for (const auto &kv : obj) {
    StringRef k = kv.first;
    if (!llvm::is_contained(allowed, k)) {
      std::string known;
      raw_string_ostream os(known);
      llvm::interleaveComma(allowed, os);
      return err(where + ": unknown key \"" + k + "\" (known: " + known + ")");
    }
  }
  return Error::success();
}

Expected<StringRef> getStr(const json::Object &o, StringRef key,
                           StringRef where) {
  if (auto v = o.getString(key))
    return *v;
  return err(where + ": missing or non-string \"" + key + "\"");
}

// Optional strings such as documentation default to empty.
std::string optStr(const json::Object &o, StringRef key) {
  if (auto v = o.getString(key))
    return v->str();
  return {};
}

Expected<uint64_t> getU64(const json::Object &o, StringRef key,
                          StringRef where) {
  auto v = o.getInteger(key);
  if (!v)
    return err(where + ": missing or non-integer \"" + key + "\"");
  if (*v < 0)
    return err(where + ": \"" + key + "\" must not be negative");
  return static_cast<uint64_t>(*v);
}

Expected<bool> getBool(const json::Object &o, StringRef key, StringRef where) {
  if (auto v = o.getBoolean(key))
    return *v;
  return err(where + ": missing or non-boolean \"" + key + "\"");
}

Expected<const json::Array *> getArr(const json::Object &o, StringRef key,
                                     StringRef where) {
  if (const auto *v = o.getArray(key))
    return v;
  return err(where + ": missing or non-array \"" + key + "\"");
}

Expected<const json::Object *> getObj(const json::Object &o, StringRef key,
                                      StringRef where) {
  if (const auto *v = o.getObject(key))
    return v;
  return err(where + ": missing or non-object \"" + key + "\"");
}

//===----------------------------------------------------------------------===//
// Types
//===----------------------------------------------------------------------===//
Expected<Type> parseType(const json::Value &v, StringRef where);

Expected<IntType> parseIntBody(const json::Object &o, StringRef where) {
  IntType t;
  auto bits = getU64(o, "bits", where);
  if (!bits)
    return bits.takeError();
  t.bits = static_cast<uint32_t>(*bits);
  if (t.bits != 8 && t.bits != 16 && t.bits != 32 && t.bits != 64)
    return err(where + ": bits must be 8, 16, 32 or 64, got " + Twine(t.bits));

  auto sign = getBool(o, "signed", where);
  if (!sign)
    return sign.takeError();
  t.isSigned = *sign;

  auto endian = getStr(o, "endianness", where);
  if (!endian)
    return endian.takeError();
  if (*endian == "little")
    t.endianness = Endianness::Little;
  else if (*endian == "big")
    t.endianness = Endianness::Big;
  else
    return err(where + ": endianness must be \"little\" or \"big\", got \"" +
               *endian + "\"");

  auto align = getU64(o, "alignment", where);
  if (!align)
    return align.takeError();
  t.alignment = static_cast<uint32_t>(*align);
  if (!isPowerOfTwo(t.alignment))
    return err(where + ": alignment must be a power of two, got " +
               Twine(t.alignment));
  if (t.alignment > t.bits / 8)
    return err(where + ": alignment " + Twine(t.alignment) +
               " exceeds the width of a " + Twine(t.bits) + "-bit integer");
  return t;
}

Expected<Type> parseType(const json::Value &v, StringRef where) {
  const auto *o = v.getAsObject();
  if (!o)
    return err(where + ": type must be an object");
  auto kind = getStr(*o, "kind", where);
  if (!kind)
    return kind.takeError();

  Type t;
  if (*kind == "int") {
    if (Error e = requireOnlyKeys(
            *o, {"kind", "bits", "signed", "endianness", "alignment"}, where))
      return std::move(e);
    auto it = parseIntBody(*o, where);
    if (!it)
      return it.takeError();
    t.v = *it;
    return t;
  }
  if (*kind == "array") {
    if (Error e = requireOnlyKeys(*o, {"kind", "count", "element"}, where))
      return std::move(e);
    auto count = getU64(*o, "count", where);
    if (!count)
      return count.takeError();
    if (*count == 0)
      return err(where + ": array count must be positive");
    const json::Value *ev = o->get("element");
    if (!ev)
      return err(where + ": array is missing \"element\"");
    auto elem = parseType(*ev, (where + " element").str());
    if (!elem)
      return elem.takeError();
    ArrayType at;
    at.count = *count;
    at.element = std::make_unique<Type>(std::move(*elem));
    t.v = std::move(at);
    return t;
  }
  if (*kind == "record_ref") {
    if (Error e = requireOnlyKeys(*o, {"kind", "symbol"}, where))
      return std::move(e);
    auto sym = getStr(*o, "symbol", where);
    if (!sym)
      return sym.takeError();
    t.v = RecordRefType{sym->str()};
    return t;
  }
  return err(where + ": type kind must be \"int\", \"array\" or "
                     "\"record_ref\", got \"" +
             *kind + "\"");
}

// Telemetry AST.
const StringRef kPredOps[] = {"always", "never",   "empty", "nonempty",
                              "zero",   "nonzero", "byte_eq", "any",
                              "all",    "not",     "unexpressible"};

Expected<Operand> parseOperand(const json::Object &o, StringRef where) {
  if (Error e = requireOnlyKeys(o, {"kind", "name"}, where))
    return std::move(e);
  auto kind = getStr(o, "kind", where);
  if (!kind)
    return kind.takeError();
  if (*kind != "field" && *kind != "derived" && *kind != "constant")
    return err(where + ": operand kind must be \"field\", \"derived\" or "
                       "\"constant\", got \"" +
               *kind + "\"");
  auto name = getStr(o, "name", where);
  if (!name)
    return name.takeError();
  return Operand{kind->str(), name->str()};
}

Expected<Predicate> parsePredicate(const json::Value &v, StringRef where) {
  const auto *o = v.getAsObject();
  if (!o)
    return err(where + ": predicate must be an object");
  if (Error e = requireOnlyKeys(
          *o, {"op", "operand", "index", "bytes", "args", "detail"}, where))
    return std::move(e);
  Predicate p;
  auto op = getStr(*o, "op", where);
  if (!op)
    return op.takeError();
  p.op = op->str();
  if (!llvm::is_contained(kPredOps, p.op)) {
    std::string known;
    raw_string_ostream os(known);
    llvm::interleaveComma(kPredOps, os);
    return err(where + ": unknown predicate op \"" + p.op + "\" (known: " +
               known + ")");
  }

  if (const auto *oo = o->getObject("operand")) {
    auto operand = parseOperand(*oo, (where + " operand").str());
    if (!operand)
      return operand.takeError();
    p.operand = *operand;
  }
  if (auto idx = o->getInteger("index")) {
    if (*idx < 0)
      return err(where + ": byte index must not be negative");
    p.index = static_cast<uint64_t>(*idx);
  }
  p.detail = optStr(*o, "detail");
  if (const auto *ba = o->getArray("bytes")) {
    for (const json::Value &bv : *ba) {
      auto b = bv.getAsInteger();
      if (!b || *b < 0 || *b > 255)
        return err(where + ": bytes entries must be 0..255");
      p.bytes.push_back(static_cast<uint8_t>(*b));
    }
  }
  if (const auto *aa = o->getArray("args")) {
    for (const json::Value &av : *aa) {
      auto sub = parsePredicate(av, (where + " arg").str());
      if (!sub)
        return sub.takeError();
      p.args.push_back(std::move(*sub));
    }
  }

  // Validate which fields each operation requires or forbids.
  bool needsOperand = p.op == "empty" || p.op == "nonempty" || p.op == "zero" ||
                      p.op == "nonzero" || p.op == "byte_eq";
  bool needsArgs = p.op == "any" || p.op == "all" || p.op == "not";
  if (needsOperand && !p.operand)
    return err(where + ": predicate \"" + p.op + "\" needs an operand");
  if (!needsOperand && p.operand)
    return err(where + ": predicate \"" + p.op + "\" takes no operand");
  if (needsArgs && p.args.empty())
    return err(where + ": predicate \"" + p.op + "\" needs args");
  if (!needsArgs && !p.args.empty())
    return err(where + ": predicate \"" + p.op + "\" takes no args");
  if (p.op == "not" && p.args.size() != 1)
    return err(where + ": predicate \"not\" takes exactly one arg");
  if (p.op == "byte_eq" && p.bytes.empty())
    return err(where + ": predicate \"byte_eq\" needs bytes");
  if (p.op != "byte_eq" && !p.bytes.empty())
    return err(where + ": predicate \"" + p.op + "\" takes no bytes");
  if (p.op != "byte_eq" && p.index != 0)
    return err(where + ": predicate \"" + p.op + "\" takes no byte index");
  // Require detail so unrepresentable conditions cannot silently disappear.
  if (p.op == "unexpressible" && p.detail.empty())
    return err(where + ": predicate \"unexpressible\" must carry \"detail\" "
                       "(the condition that could not be expressed)");
  if (p.op != "unexpressible" && !p.detail.empty())
    return err(where + ": only \"unexpressible\" takes \"detail\"");
  return p;
}

Expected<Source> parseSource(const json::Object &o, StringRef where) {
  if (Error e = requireOnlyKeys(o, {"kind", "name", "from", "detail"}, where))
    return std::move(e);
  Source s;
  auto kind = getStr(o, "kind", where);
  if (!kind)
    return kind.takeError();
  s.kind = kind->str();
  if (s.kind != "field" && s.kind != "derived" && s.kind != "constant" &&
      s.kind != "runtime_extension")
    return err(where + ": source kind must be \"field\", \"derived\", "
                       "\"constant\" or \"runtime_extension\", got \"" +
               s.kind + "\"");
  auto name = getStr(o, "name", where);
  if (!name)
    return name.takeError();
  s.name = name->str();
  s.from = optStr(o, "from");
  s.detail = optStr(o, "detail");
  // Require detail for unrepresentable forms rather than dropping them.
  if (s.kind == "runtime_extension" && s.detail.empty())
    return err(where + ": a runtime_extension source must carry \"detail\" "
                       "(what could not be expressed)");
  return s;
}

// Resolve field references: telemetry body/value/attribute sources must exist in core.records.
// Follow record_ref for dotted paths such as hdr.timestamp.
const Record *findRecordBySymbol(const std::vector<Record> &recs,
                                 StringRef sym) {
  for (const Record &r : recs)
    if (r.symbol == sym)
      return &r;
  return nullptr;
}

bool hasFieldPath(const std::vector<Record> &recs, const Record &r,
                  StringRef path) {
  auto [head, rest] = path.split('.');
  for (const Field &f : r.fields) {
    if (f.name != head)
      continue;
    if (rest.empty())
      return true;
    if (const auto *rr = std::get_if<RecordRefType>(&f.type.v)) {
      const Record *inner = findRecordBySymbol(recs, rr->symbol);
      return inner && hasFieldPath(recs, *inner, rest);
    }
    return false;
  }
  return false;
}

// Canonical JSON output helpers.
void emitStr(raw_ostream &os, StringRef s) { os << json::Value(s); }

void indent(raw_ostream &os, unsigned n) { os.indent(n); }

// Generic canonical extension emitter: always sort object keys. Core does not interpret payloads,
// so their order is canonicalized rather than preserved.
void emitCanonical(raw_ostream &os, const json::Value &v, unsigned ind) {
  switch (v.kind()) {
  case json::Value::Null:
    os << "null";
    return;
  case json::Value::Boolean:
    os << (*v.getAsBoolean() ? "true" : "false");
    return;
  case json::Value::Number: {
    if (auto i = v.getAsInteger())
      os << *i;
    else
      os << *v.getAsNumber();
    return;
  }
  case json::Value::String:
    emitStr(os, *v.getAsString());
    return;
  case json::Value::Array: {
    const auto *a = v.getAsArray();
    if (a->empty()) {
      os << "[]";
      return;
    }
    os << "[\n";
    for (size_t i = 0; i < a->size(); ++i) {
      indent(os, ind + 2);
      emitCanonical(os, (*a)[i], ind + 2);
      os << (i + 1 < a->size() ? "," : "") << "\n";
    }
    indent(os, ind);
    os << "]";
    return;
  }
  case json::Value::Object: {
    const auto *o = v.getAsObject();
    std::vector<StringRef> keys;
    for (const auto &kv : *o)
      keys.push_back(kv.first);
    llvm::sort(keys);
    if (keys.empty()) {
      os << "{}";
      return;
    }
    os << "{\n";
    for (size_t i = 0; i < keys.size(); ++i) {
      indent(os, ind + 2);
      emitStr(os, keys[i]);
      os << ": ";
      emitCanonical(os, *o->get(keys[i]), ind + 2);
      os << (i + 1 < keys.size() ? "," : "") << "\n";
    }
    indent(os, ind);
    os << "}";
    return;
  }
  }
}

const char *endianName(Endianness e) {
  return e == Endianness::Little ? "little" : "big";
}

void emitType(raw_ostream &os, const Type &t, unsigned ind);

void emitTypeBody(raw_ostream &os, const IntType &t, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"kind\": \"int\",\n";
  indent(os, ind + 2); os << "\"alignment\": " << t.alignment << ",\n";
  indent(os, ind + 2); os << "\"bits\": " << t.bits << ",\n";
  indent(os, ind + 2); os << "\"endianness\": \"" << endianName(t.endianness) << "\",\n";
  indent(os, ind + 2); os << "\"signed\": " << (t.isSigned ? "true" : "false") << "\n";
  indent(os, ind); os << "}";
}

void emitTypeBody(raw_ostream &os, const ArrayType &t, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"kind\": \"array\",\n";
  indent(os, ind + 2); os << "\"count\": " << t.count << ",\n";
  indent(os, ind + 2); os << "\"element\": ";
  emitType(os, *t.element, ind + 2);
  os << "\n";
  indent(os, ind); os << "}";
}

void emitTypeBody(raw_ostream &os, const RecordRefType &t, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"kind\": \"record_ref\",\n";
  indent(os, ind + 2); os << "\"symbol\": "; emitStr(os, t.symbol); os << "\n";
  indent(os, ind); os << "}";
}

void emitType(raw_ostream &os, const Type &t, unsigned ind) {
  std::visit([&](const auto &x) { emitTypeBody(os, x, ind); }, t.v);
}

void emitOperand(raw_ostream &os, const Operand &o, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"kind\": "; emitStr(os, o.kind); os << ",\n";
  indent(os, ind + 2); os << "\"name\": "; emitStr(os, o.name); os << "\n";
  indent(os, ind); os << "}";
}

void emitPredicate(raw_ostream &os, const Predicate &p, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"op\": "; emitStr(os, p.op);
  if (p.operand) {
    os << ",\n";
    indent(os, ind + 2); os << "\"operand\": ";
    emitOperand(os, *p.operand, ind + 2);
  }
  if (!p.detail.empty()) {
    os << ",\n";
    indent(os, ind + 2); os << "\"detail\": "; emitStr(os, p.detail);
  }
  if (!p.bytes.empty()) {
    os << ",\n";
    indent(os, ind + 2); os << "\"index\": " << p.index << ",\n";
    indent(os, ind + 2); os << "\"bytes\": [";
    for (auto [i, b] : llvm::enumerate(p.bytes))
      os << (i ? ", " : "") << unsigned(b);
    os << "]";
  }
  if (!p.args.empty()) {
    os << ",\n";
    indent(os, ind + 2); os << "\"args\": [\n";
    for (auto [i, a] : llvm::enumerate(p.args)) {
      indent(os, ind + 4);
      emitPredicate(os, a, ind + 4);
      os << (i + 1 < p.args.size() ? "," : "") << "\n";
    }
    indent(os, ind + 2); os << "]";
  }
  os << "\n";
  indent(os, ind); os << "}";
}

void emitSource(raw_ostream &os, const Source &s, unsigned ind) {
  os << "{\n";
  indent(os, ind + 2); os << "\"kind\": "; emitStr(os, s.kind); os << ",\n";
  indent(os, ind + 2); os << "\"name\": "; emitStr(os, s.name); os << ",\n";
  indent(os, ind + 2); os << "\"from\": "; emitStr(os, s.from); os << ",\n";
  indent(os, ind + 2); os << "\"detail\": "; emitStr(os, s.detail); os << "\n";
  indent(os, ind); os << "}";
}

} // namespace

// Single source of spellings, outside the anonymous namespace for verify-schema reuse.
const char *mapKindName(MapKind k) {
  switch (k) {
  case MapKind::Hash:
    return "hash";
  case MapKind::Array:
    return "array";
  case MapKind::RingBuf:
    return "ringbuf";
  case MapKind::PerCpuArray:
    return "percpu_array";
  }
  return "hash";
}

//===----------------------------------------------------------------------===//
// sizeOf
//===----------------------------------------------------------------------===//
static Expected<uint64_t> sizeOfImpl(const Schema &s, const Type &t,
                                     std::set<std::string> &visiting);

static Expected<uint64_t> recordSize(const Schema &s, StringRef symbol,
                                     std::set<std::string> &visiting) {
  if (!visiting.insert(symbol.str()).second)
    return err("record \"" + symbol + "\" is cyclic");
  for (const Record &r : s.records())
    if (r.symbol == symbol) {
      visiting.erase(symbol.str());
      return r.size;
    }
  visiting.erase(symbol.str());
  return err("record_ref \"" + symbol + "\" is not declared in the schema");
}

static Expected<uint64_t> sizeOfImpl(const Schema &s, const Type &t,
                                     std::set<std::string> &visiting) {
  if (const auto *i = std::get_if<IntType>(&t.v))
    return i->bits / 8;
  if (const auto *a = std::get_if<ArrayType>(&t.v)) {
    auto e = sizeOfImpl(s, *a->element, visiting);
    if (!e)
      return e.takeError();
    return *e * a->count;
  }
  const auto &r = std::get<RecordRefType>(t.v);
  return recordSize(s, r.symbol, visiting);
}

Expected<uint64_t> Schema::sizeOf(const Type &t) const {
  std::set<std::string> visiting;
  return sizeOfImpl(*this, t, visiting);
}

bool Schema::operator==(const Schema &o) const {
  if (!(coverage_ == o.coverage_ &&
        programs_ == o.programs_ && maps_ == o.maps_ && records_ == o.records_ &&
        signals_ == o.signals_ && clocks_ == o.clocks_ &&
        valueMaps_ == o.valueMaps_ && boundsSets_ == o.boundsSets_))
    return false;
  if (extensions_.size() != o.extensions_.size())
    return false;
  for (const auto &kv : extensions_) {
    auto it = o.extensions_.find(kv.first);
    if (it == o.extensions_.end() || it->second != kv.second)
      return false;
  }
  return true;
}

//===----------------------------------------------------------------------===//
// parse
//===----------------------------------------------------------------------===//
Expected<Schema> Schema::parseJSON(StringRef jsonText) {
  auto parsed = json::parse(jsonText);
  if (!parsed)
    return parsed.takeError();
  const auto *root = parsed->getAsObject();
  if (!root)
    return err("schema: root must be an object");

  // Refuse unknown top-level keys; extensibility is confined to extensions.
  if (Error e = requireOnlyKeys(
          *root, {"version", "coverage", "core", "telemetry", "extensions"},
          "schema"))
    return std::move(e);

  auto version = getU64(*root, "version", "schema");
  if (!version)
    return version.takeError();
  if (*version != kSchemaVersion)
    return err("schema: version must be " + Twine(kSchemaVersion) + ", got " +
               Twine(*version));

  Schema s;

  // Coverage is required, with no implicit default.
  {
    auto covObj = getObj(*root, "coverage", "schema");
    if (!covObj)
      return err("schema: \"coverage\" is required — it says what this schema "
                 "makes canonical. Omitting it would let a missing declaration "
                 "silently disable checking (see E153).");
    if (Error e = requireOnlyKeys(
            **covObj, {"programs", "maps", "records", "telemetry"}, "coverage"))
      return std::move(e);
    auto one = [&](StringRef key, Coverage &out) -> Error {
      auto v = getStr(**covObj, key, "coverage");
      if (!v)
        return v.takeError();
      if (*v == "complete")
        out = Coverage::Complete;
      else if (*v == "omitted")
        out = Coverage::Omitted;
      else
        return err("coverage." + key +
                   " must be \"complete\" or \"omitted\", got \"" + *v +
                   "\" (there is no \"partial\": its scope would be ambiguous)");
      return Error::success();
    };
    if (Error e = one("programs", s.coverage_.programs))
      return std::move(e);
    if (Error e = one("maps", s.coverage_.maps))
      return std::move(e);
    if (Error e = one("records", s.coverage_.records))
      return std::move(e);
    if (Error e = one("telemetry", s.coverage_.telemetry))
      return std::move(e);
  }

  //===------------------------------------------------------------------===//
  // core
  //===------------------------------------------------------------------===//
  auto coreObj = getObj(*root, "core", "schema");
  if (!coreObj)
    return coreObj.takeError();
  if (Error e =
          requireOnlyKeys(**coreObj, {"programs", "maps", "records"}, "core"))
    return std::move(e);

  // ---- records ----
  auto recArr = getArr(**coreObj, "records", "core");
  if (!recArr)
    return recArr.takeError();
  StringSet<> recSymbols;
  DenseSet<uint32_t> recIds;
  for (const json::Value &v : **recArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("core.records: entry must be an object");
    if (Error e = requireOnlyKeys(*o,
                                  {"symbol", "id", "size", "min_size",
                                   "alignment", "required_through", "fields",
                                   "note"},
                                  "core.records"))
      return std::move(e);
    Record r;
    auto sym = getStr(*o, "symbol", "core.records");
    if (!sym)
      return sym.takeError();
    r.symbol = sym->str();
    if (!recSymbols.insert(r.symbol).second)
      return err("core.records: duplicate record symbol \"" + r.symbol + "\"");
    std::string where = "record \"" + r.symbol + "\"";

    auto id = getU64(*o, "id", where);
    if (!id)
      return id.takeError();
    r.id = static_cast<uint32_t>(*id);
    if (r.id != 0 && !recIds.insert(r.id).second)
      return err(where + ": duplicate record id " + Twine(r.id));

    auto size = getU64(*o, "size", where);
    if (!size)
      return size.takeError();
    r.size = *size;
    auto minSize = getU64(*o, "min_size", where);
    if (!minSize)
      return minSize.takeError();
    r.minSize = *minSize;
    if (r.minSize > r.size)
      return err(where + ": min_size " + Twine(r.minSize) +
                 " exceeds size " + Twine(r.size));

    auto align = getU64(*o, "alignment", where);
    if (!align)
      return align.takeError();
    r.alignment = static_cast<uint32_t>(*align);
    if (!isPowerOfTwo(r.alignment))
      return err(where + ": alignment must be a power of two, got " +
                 Twine(r.alignment));
    if (r.size % r.alignment != 0)
      return err(where + ": size " + Twine(r.size) +
                 " is not a multiple of alignment " + Twine(r.alignment));

    auto reqThrough = getStr(*o, "required_through", where);
    if (!reqThrough)
      return reqThrough.takeError();
    r.requiredThrough = reqThrough->str();
    r.note = optStr(*o, "note");

    auto fieldsArr = getArr(*o, "fields", where);
    if (!fieldsArr)
      return fieldsArr.takeError();
    StringSet<> fieldNames;
    for (const json::Value &fv : **fieldsArr) {
      const auto *fo = fv.getAsObject();
      if (!fo)
        return err(where + ": field must be an object");
      if (Error e = requireOnlyKeys(
              *fo, {"name", "type", "offset", "expose", "note"},
              where + " field"))
        return std::move(e);
      Field f;
      auto fname = getStr(*fo, "name", where + " field");
      if (!fname)
        return fname.takeError();
      f.name = fname->str();
      if (!fieldNames.insert(f.name).second)
        return err(where + ": duplicate field name \"" + f.name + "\"");
      std::string fwhere = where + " field \"" + f.name + "\"";

      const json::Value *tv = fo->get("type");
      if (!tv)
        return err(fwhere + ": missing \"type\"");
      auto ft = parseType(*tv, fwhere);
      if (!ft)
        return ft.takeError();
      f.type = std::move(*ft);

      auto off = getU64(*fo, "offset", fwhere);
      if (!off)
        return off.takeError();
      f.offset = *off;
      f.expose = optStr(*fo, "expose");
      f.note = optStr(*fo, "note");
      r.fields.push_back(std::move(f));
    }
    if (!r.requiredThrough.empty() && !fieldNames.contains(r.requiredThrough))
      return err(where + ": required_through \"" + r.requiredThrough +
                 "\" is not a field of this record");
    s.records_.push_back(std::move(r));
  }

  // Reject record_ref cycles before layout: sizeOf returns declared size and could otherwise accept
  // impossible self-containing structs, as observed.
  {
    llvm::StringMap<std::vector<std::string>> refs;
    std::function<void(const Type &, std::vector<std::string> &)> collect =
        [&](const Type &t, std::vector<std::string> &out) {
          if (const auto *a = std::get_if<ArrayType>(&t.v))
            collect(*a->element, out);
          else if (const auto *r = std::get_if<RecordRefType>(&t.v))
            out.push_back(r->symbol);
        };
    for (const Record &r : s.records_) {
      auto &out = refs[r.symbol];
      for (const Field &f : r.fields)
        collect(f.type, out);
    }
    std::set<std::string> onStack, done;
    std::function<Error(StringRef)> visit = [&](StringRef sym) -> Error {
      if (done.count(sym.str()))
        return Error::success();
      if (!onStack.insert(sym.str()).second)
        return err("record \"" + sym + "\" is cyclic (a record cannot contain "
                                       "itself, directly or through another "
                                       "record)");
      auto it = refs.find(sym);
      if (it != refs.end())
        for (const std::string &next : it->second) {
          if (!recSymbols.contains(next))
            return err("record_ref \"" + next +
                       "\" is not declared in the schema");
          if (Error e = visit(next))
            return e;
        }
      onStack.erase(sym.str());
      done.insert(sym.str());
      return Error::success();
    };
    for (const Record &r : s.records_)
      if (Error e = visit(r.symbol))
        return std::move(e);
  }

  // Validate layout after collecting every record, needed for reference resolution.
  for (const Record &r : s.records_) {
    std::string where = "record \"" + r.symbol + "\"";
    struct Span { uint64_t begin, end; const Field *f; };
    std::vector<Span> spans;
    for (const Field &f : r.fields) {
      auto sz = s.sizeOf(f.type);
      if (!sz)
        return err(where + " field \"" + f.name +
                   "\": " + toString(sz.takeError()));
      if (*sz == 0)
        return err(where + " field \"" + f.name + "\": zero-sized field");
      // Offset must satisfy the type alignment.
      uint64_t need = 1;
      if (const auto *i = std::get_if<IntType>(&f.type.v))
        need = i->alignment;
      else if (const auto *rr = std::get_if<RecordRefType>(&f.type.v)) {
        for (const Record &o : s.records_)
          if (o.symbol == rr->symbol)
            need = o.alignment;
      }
      if (f.offset % need != 0)
        return err(where + " field \"" + f.name + "\": offset " +
                   Twine(f.offset) + " is not aligned to " + Twine(need));
      if (f.offset + *sz > r.size)
        return err(where + " field \"" + f.name + "\": ends at " +
                   Twine(f.offset + *sz) + " which is past the record size " +
                   Twine(r.size));
      spans.push_back({f.offset, f.offset + *sz, &f});
    }
    llvm::sort(spans, [](const Span &a, const Span &b) {
      return a.begin < b.begin;
    });
    for (size_t i = 1; i < spans.size(); ++i)
      if (spans[i].begin < spans[i - 1].end)
        return err(where + ": fields \"" + spans[i - 1].f->name + "\" and \"" +
                   spans[i].f->name + "\" overlap (" +
                   Twine(spans[i - 1].begin) + ".." + Twine(spans[i - 1].end) +
                   " vs " + Twine(spans[i].begin) + ")");
  }

  // ---- maps ----
  auto mapsArr = getArr(**coreObj, "maps", "core");
  if (!mapsArr)
    return mapsArr.takeError();
  StringSet<> mapSymbols;
  for (const json::Value &v : **mapsArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("core.maps: entry must be an object");
    if (Error e = requireOnlyKeys(*o,
                                  {"symbol", "kind", "key", "value",
                                   "max_entries", "flags", "record", "note"},
                                  "core.maps"))
      return std::move(e);
    Map m;
    auto sym = getStr(*o, "symbol", "core.maps");
    if (!sym)
      return sym.takeError();
    m.symbol = sym->str();
    if (!mapSymbols.insert(m.symbol).second)
      return err("core.maps: duplicate map symbol \"" + m.symbol + "\"");
    std::string where = "map \"" + m.symbol + "\"";

    auto kind = getStr(*o, "kind", where);
    if (!kind)
      return kind.takeError();
    if (*kind == "hash")
      m.kind = MapKind::Hash;
    else if (*kind == "array")
      m.kind = MapKind::Array;
    else if (*kind == "ringbuf")
      m.kind = MapKind::RingBuf;
    else if (*kind == "percpu_array")
      m.kind = MapKind::PerCpuArray;
    else
      return err(where + ": kind must be \"hash\", \"array\", \"ringbuf\" or "
                         "\"percpu_array\", got \"" +
                 *kind + "\"");

    if (const json::Value *kv = o->get("key")) {
      auto kt = parseType(*kv, where + " key");
      if (!kt)
        return kt.takeError();
      m.key = std::move(*kt);
    }
    if (const json::Value *vv = o->get("value")) {
      auto vt = parseType(*vv, where + " value");
      if (!vt)
        return vt.takeError();
      m.value = std::move(*vt);
    }
    // Ring buffers have no ordinary key/value; specify requirements by kind rather than requiring
    // them for every map.
    if (m.kind == MapKind::RingBuf) {
      if (m.key || m.value)
        return err(where + ": a ringbuf map has no key/value");
    } else if (!m.key || !m.value) {
      return err(where + ": a \"" + *kind + "\" map needs both key and value");
    }

    auto maxE = getU64(*o, "max_entries", where);
    if (!maxE)
      return maxE.takeError();
    m.maxEntries = *maxE;
    if (m.maxEntries == 0)
      return err(where + ": max_entries must be positive");
    if (m.kind == MapKind::RingBuf && !isPowerOfTwo(m.maxEntries))
      return err(where + ": a ringbuf size must be a power of two, got " +
                 Twine(m.maxEntries));

    auto flags = getU64(*o, "flags", where);
    if (!flags)
      return flags.takeError();
    m.flags = *flags;
    m.record = optStr(*o, "record");
    m.note = optStr(*o, "note");
    if (!m.record.empty() && !recSymbols.contains(m.record))
      return err(where + ": record \"" + m.record +
                 "\" is not declared in the schema");
    if (m.kind == MapKind::RingBuf && m.record.empty())
      return err(where + ": a ringbuf map must name the record it carries");
    s.maps_.push_back(std::move(m));
  }

  // ---- programs ----
  auto progArr = getArr(**coreObj, "programs", "core");
  if (!progArr)
    return progArr.takeError();
  StringSet<> progNames;
  for (const json::Value &v : **progArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("core.programs: entry must be an object");
    if (Error e = requireOnlyKeys(
            *o, {"name", "kind", "attach_target", "maps", "note"},
            "core.programs"))
      return std::move(e);
    Program p;
    auto name = getStr(*o, "name", "core.programs");
    if (!name)
      return name.takeError();
    p.name = name->str();
    if (!progNames.insert(p.name).second)
      return err("core.programs: duplicate program name \"" + p.name + "\"");
    std::string where = "program \"" + p.name + "\"";

    auto kind = getStr(*o, "kind", where);
    if (!kind)
      return kind.takeError();
    p.kind = kind->str();
    if (p.kind != "xdp")
      return err(where + ": kind must be \"xdp\", got \"" + p.kind + "\"");

    auto target = getStr(*o, "attach_target", where);
    if (!target)
      return target.takeError();
    p.attachTarget = target->str();
    p.note = optStr(*o, "note");

    auto pMaps = getArr(*o, "maps", where);
    if (!pMaps)
      return pMaps.takeError();
    StringSet<> bound;
    for (const json::Value &mv : **pMaps) {
      auto ms = mv.getAsString();
      if (!ms)
        return err(where + ": maps entries must be strings");
      if (!mapSymbols.contains(*ms))
        return err(where + ": map symbol \"" + *ms +
                   "\" is not declared in the schema");
      if (!bound.insert(*ms).second)
        return err(where + ": map symbol \"" + *ms + "\" is bound twice");
      p.maps.push_back(ms->str());
    }
    s.programs_.push_back(std::move(p));
  }

  //===------------------------------------------------------------------===//
  // telemetry
  //===------------------------------------------------------------------===//
  auto telObj = getObj(*root, "telemetry", "schema");
  if (!telObj)
    return telObj.takeError();
  if (Error e = requireOnlyKeys(
          **telObj, {"signals", "clocks", "value_maps", "bounds_sets"},
          "telemetry"))
    return std::move(e);

  // ---- clocks ----
  auto clockArr = getArr(**telObj, "clocks", "telemetry");
  if (!clockArr)
    return clockArr.takeError();
  StringSet<> clockIds;
  for (const json::Value &v : **clockArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("telemetry.clocks: entry must be an object");
    if (Error e = requireOnlyKeys(
            *o, {"id", "kernel_source", "posix_clock", "to_wall", "note"},
            "telemetry.clocks"))
      return std::move(e);
    Clock c;
    auto id = getStr(*o, "id", "telemetry.clocks");
    if (!id)
      return id.takeError();
    c.id = id->str();
    if (!clockIds.insert(c.id).second)
      return err("telemetry.clocks: duplicate clock id \"" + c.id + "\"");
    std::string where = "clock \"" + c.id + "\"";
    auto ks = getStr(*o, "kernel_source", where);
    if (!ks)
      return ks.takeError();
    c.kernelSource = ks->str();
    auto pc = getStr(*o, "posix_clock", where);
    if (!pc)
      return pc.takeError();
    c.posixClock = pc->str();
    auto tw = getStr(*o, "to_wall", where);
    if (!tw)
      return tw.takeError();
    c.toWall = tw->str();
    c.note = optStr(*o, "note");
    s.clocks_.push_back(std::move(c));
  }

  // ---- value_maps ----
  auto vmArr = getArr(**telObj, "value_maps", "telemetry");
  if (!vmArr)
    return vmArr.takeError();
  StringSet<> vmIds;
  for (const json::Value &v : **vmArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("telemetry.value_maps: entry must be an object");
    if (Error e = requireOnlyKeys(*o,
                                  {"id", "unknown", "arch_invariant",
                                   "btf_mode", "btf_anchor", "btf_prefix",
                                   "btf_omit", "authority", "note", "entries"},
                                  "telemetry.value_maps"))
      return std::move(e);
    ValueMap vm;
    auto id = getStr(*o, "id", "telemetry.value_maps");
    if (!id)
      return id.takeError();
    vm.id = id->str();
    if (!vmIds.insert(vm.id).second)
      return err("telemetry.value_maps: duplicate id \"" + vm.id + "\"");
    std::string where = "value_map \"" + vm.id + "\"";
    vm.unknown = optStr(*o, "unknown");
    if (auto ai = o->getBoolean("arch_invariant"))
      vm.archInvariant = *ai;
    vm.btfMode = optStr(*o, "btf_mode");
    vm.btfAnchor = optStr(*o, "btf_anchor");
    vm.btfPrefix = optStr(*o, "btf_prefix");
    vm.btfOmit = optStr(*o, "btf_omit");
    vm.authority = optStr(*o, "authority");
    vm.note = optStr(*o, "note");
    if (!vm.btfMode.empty() && vm.btfAnchor.empty())
      return err(where + ": btf_mode needs a btf_anchor to check against");
    auto entries = getArr(*o, "entries", where);
    if (!entries)
      return entries.takeError();
    std::set<int64_t> seen;
    for (const json::Value &ev : **entries) {
      const auto *eo = ev.getAsObject();
      if (!eo)
        return err(where + ": entry must be an object");
      if (Error e = requireOnlyKeys(*eo, {"value", "name"}, where + " entry"))
        return std::move(e);
      auto val = eo->getInteger("value");
      if (!val)
        return err(where + ": entry missing integer \"value\"");
      if (!seen.insert(*val).second)
        return err(where + ": duplicate value " + Twine(*val));
      auto nm = getStr(*eo, "name", where + " entry");
      if (!nm)
        return nm.takeError();
      vm.entries.push_back({*val, nm->str()});
    }
    s.valueMaps_.push_back(std::move(vm));
  }

  // ---- bounds_sets ----
  auto bsArr = getArr(**telObj, "bounds_sets", "telemetry");
  if (!bsArr)
    return bsArr.takeError();
  StringSet<> bsIds;
  for (const json::Value &v : **bsArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("telemetry.bounds_sets: entry must be an object");
    if (Error e = requireOnlyKeys(
            *o, {"id", "bounds", "unit", "authority", "note"},
            "telemetry.bounds_sets"))
      return std::move(e);
    BoundsSet b;
    auto id = getStr(*o, "id", "telemetry.bounds_sets");
    if (!id)
      return id.takeError();
    b.id = id->str();
    if (!bsIds.insert(b.id).second)
      return err("telemetry.bounds_sets: duplicate id \"" + b.id + "\"");
    std::string where = "bounds_set \"" + b.id + "\"";
    auto unit = getStr(*o, "unit", where);
    if (!unit)
      return unit.takeError();
    b.unit = unit->str();
    b.authority = optStr(*o, "authority");
    b.note = optStr(*o, "note");
    auto bounds = getArr(*o, "bounds", where);
    if (!bounds)
      return bounds.takeError();
    double prev = -std::numeric_limits<double>::infinity();
    for (const json::Value &bv : **bounds) {
      auto d = bv.getAsNumber();
      if (!d)
        return err(where + ": bounds entries must be numbers");
      if (*d <= prev)
        return err(where + ": bounds must be strictly increasing");
      prev = *d;
      b.bounds.push_back(*d);
    }
    if (b.bounds.empty())
      return err(where + ": bounds must not be empty");
    s.boundsSets_.push_back(std::move(b));
  }

  // ---- signals ----
  auto sigArr = getArr(**telObj, "signals", "telemetry");
  if (!sigArr)
    return sigArr.takeError();
  StringSet<> sigNames;
  for (const json::Value &v : **sigArr) {
    const auto *o = v.getAsObject();
    if (!o)
      return err("telemetry.signals: entry must be an object");
    if (Error e = requireOnlyKeys(*o,
                                  {"name", "signal", "record", "span_name",
                                   "span_kind", "timing", "drop_when",
                                   "attributes", "body", "value", "metric",
                                   "note"},
                                  "telemetry.signals"))
      return std::move(e);
    Signal sig;
    auto name = getStr(*o, "name", "telemetry.signals");
    if (!name)
      return name.takeError();
    sig.name = name->str();
    if (!sigNames.insert(sig.name).second)
      return err("telemetry.signals: duplicate signal name \"" + sig.name +
                 "\"");
    std::string where = "signal \"" + sig.name + "\"";

    auto kind = getStr(*o, "signal", where);
    if (!kind)
      return kind.takeError();
    sig.signal = kind->str();
    if (sig.signal != "traces" && sig.signal != "metrics" &&
        sig.signal != "logs")
      return err(where + ": signal must be \"traces\", \"metrics\" or "
                         "\"logs\", got \"" +
                 sig.signal + "\"");

    auto rec = getStr(*o, "record", where);
    if (!rec)
      return rec.takeError();
    sig.record = rec->str();
    if (!recSymbols.contains(sig.record))
      return err(where + ": record \"" + sig.record +
                 "\" is not declared in core.records");

    sig.spanName = optStr(*o, "span_name");
    sig.spanKind = optStr(*o, "span_kind");
    sig.note = optStr(*o, "note");

    auto timing = getObj(*o, "timing", where);
    if (!timing)
      return timing.takeError();
    if (Error e = requireOnlyKeys(**timing, {"start", "clock", "end"},
                                  where + " timing"))
      return std::move(e);
    auto st = getStr(**timing, "start", where + " timing");
    if (!st)
      return st.takeError();
    sig.timing.start = st->str();
    auto ck = getStr(**timing, "clock", where + " timing");
    if (!ck)
      return ck.takeError();
    sig.timing.clock = ck->str();
    // Empty means building directly from wall clock without a kernel clock, as offcpu does. Permit
    // empty but require any supplied spelling to exist.
    if (!sig.timing.clock.empty() && !clockIds.contains(sig.timing.clock))
      return err(where + ": clock \"" + sig.timing.clock +
                 "\" is not declared in telemetry.clocks");
    auto en = getStr(**timing, "end", where + " timing");
    if (!en)
      return en.takeError();
    sig.timing.end = en->str();

    const json::Value *dw = o->get("drop_when");
    if (!dw)
      return err(where + ": missing \"drop_when\" (a signal must say when it "
                         "produces nothing)");
    auto pred = parsePredicate(*dw, where + " drop_when");
    if (!pred)
      return pred.takeError();
    sig.dropWhen = std::move(*pred);

    if (const auto *mo = o->getObject("metric")) {
      if (Error e = requireOnlyKeys(*mo,
                                    {"kind", "unit", "temporality", "monotonic",
                                     "scale", "zero_threshold", "bucket_rule"},
                                    where + " metric"))
        return std::move(e);
      Metric m;
      auto mk = getStr(*mo, "kind", where + " metric");
      if (!mk)
        return mk.takeError();
      m.kind = mk->str();
      // Closed set: accepting an unknown kind would claim representation for a declaration no
      // consumer reads.
      if (m.kind != "sum" && m.kind != "exponential_histogram")
        return err(where + ": metric kind must be \"sum\" or "
                           "\"exponential_histogram\", got \"" +
                   m.kind + "\"");
      auto mu = getStr(*mo, "unit", where + " metric");
      if (!mu)
        return mu.takeError();
      m.unit = mu->str();
      auto mt = getStr(*mo, "temporality", where + " metric");
      if (!mt)
        return mt.takeError();
      m.temporality = mt->str();
      if (m.temporality != "delta" && m.temporality != "cumulative")
        return err(where + ": metric temporality must be \"delta\" or "
                           "\"cumulative\", got \"" +
                   m.temporality + "\"");
      // Kind-specific required/forbidden fields.
      if (m.kind == "sum") {
        auto mono = getBool(*mo, "monotonic", where + " metric (sum)");
        if (!mono)
          return mono.takeError();
        m.monotonic = *mono;
        if (mo->get("scale") || mo->get("zero_threshold") ||
            mo->get("bucket_rule"))
          return err(where + ": a sum metric takes no scale / zero_threshold "
                             "/ bucket_rule");
      } else { // exponential_histogram
        if (mo->get("monotonic"))
          return err(where +
                     ": an exponential_histogram metric takes no monotonic");
        auto sc = mo->getInteger("scale");
        if (!sc)
          return err(where + " metric (exponential_histogram): missing or "
                             "non-integer \"scale\"");
        m.scale = *sc;
        auto zt = mo->getNumber("zero_threshold");
        if (!zt)
          return err(where + " metric (exponential_histogram): missing or "
                             "non-numeric \"zero_threshold\"");
        if (*zt < 0)
          return err(where + ": zero_threshold must not be negative");
        m.zeroThreshold = *zt;
        auto br = getStr(*mo, "bucket_rule",
                         where + " metric (exponential_histogram)");
        if (!br)
          return br.takeError();
        m.bucketRule = br->str();
        // Declare scalar-observation-to-bucket mapping as a closed token so Spinel/MLIR/Go agree on
        // open/closed endpoints.
        if (m.bucketRule != "otlp_lower_exclusive")
          return err(where + ": bucket_rule must be \"otlp_lower_exclusive\" "
                             "(v > zero_threshold goes to index i with "
                             "base^i < v <= base^(i+1)), got \"" +
                     m.bucketRule + "\"");
      }
      sig.metric = m;
    }
    if (sig.signal == "metrics" && !sig.metric)
      return err(where + ": a metrics signal needs a \"metric\" block");
    if (sig.signal != "metrics" && sig.metric)
      return err(where + ": \"metric\" only applies to metrics signals");
    if (sig.signal == "traces" && sig.spanName.empty())
      return err(where + ": a traces signal needs a span_name");

    auto attrs = getArr(*o, "attributes", where);
    if (!attrs)
      return attrs.takeError();
    StringSet<> attrKeys;
    for (const json::Value &av : **attrs) {
      const auto *ao = av.getAsObject();
      if (!ao)
        return err(where + ": attribute must be an object");
      if (Error e = requireOnlyKeys(
              *ao, {"key", "stability", "source", "presence", "note"},
              where + " attribute"))
        return std::move(e);
      Attribute a;
      auto key = getStr(*ao, "key", where + " attribute");
      if (!key)
        return key.takeError();
      a.key = key->str();
      if (!attrKeys.insert(a.key).second)
        return err(where + ": duplicate attribute key \"" + a.key + "\"");
      std::string awhere = where + " attribute \"" + a.key + "\"";
      auto stab = getStr(*ao, "stability", awhere);
      if (!stab)
        return stab.takeError();
      a.stability = stab->str();
      a.note = optStr(*ao, "note");

      auto srcObj = getObj(*ao, "source", awhere);
      if (!srcObj)
        return srcObj.takeError();
      auto src = parseSource(**srcObj, awhere + " source");
      if (!src)
        return src.takeError();
      a.source = std::move(*src);

      const json::Value *pv = ao->get("presence");
      if (!pv)
        return err(awhere + ": missing \"presence\"");
      auto pp = parsePredicate(*pv, awhere + " presence");
      if (!pp)
        return pp.takeError();
      a.presence = std::move(*pp);
      sig.attributes.push_back(std::move(a));
    }

    // body/value reuse Source, excluding C/Ruby expressions and exporter-function names from the
    // generic layer.
    if (const auto *bo = o->getObject("body")) {
      auto src = parseSource(*bo, where + " body");
      if (!src)
        return src.takeError();
      sig.body = std::move(*src);
    } else if (o->get("body")) {
      return err(where + ": \"body\" must be an object");
    }
    if (const auto *vo = o->getObject("value")) {
      auto src = parseSource(*vo, where + " value");
      if (!src)
        return src.takeError();
      sig.value = std::move(*src);
    } else if (o->get("value")) {
      return err(where + ": \"value\" must be an object");
    }

    // Signal-specific required/forbidden fields.
    if (sig.signal == "logs") {
      if (!sig.body)
        return err(where + ": a logs signal needs a \"body\" (the source of "
                           "the LogRecord body)");
      if (sig.value)
        return err(where + ": \"value\" only applies to metrics signals");
      if (!sig.spanName.empty() || !sig.spanKind.empty())
        return err(where +
                   ": span_name/span_kind only apply to traces signals");
    } else if (sig.signal == "metrics") {
      if (!sig.value)
        return err(where + ": a metrics signal needs a \"value\" (the source "
                           "of the observation)");
      if (sig.body)
        return err(where + ": \"body\" only applies to logs signals");
      if (!sig.spanName.empty() || !sig.spanKind.empty())
        return err(where +
                   ": span_name/span_kind only apply to traces signals");
    } else { // traces
      if (sig.spanKind.empty())
        return err(where + ": a traces signal needs a span_kind");
      if (sig.body || sig.value)
        return err(where + ": body/value do not apply to traces signals");
    }

    // ---- Field reference consistency ----
    const Record *sigRec = findRecordBySymbol(s.records_, sig.record);
    auto checkFieldRef = [&](const Source &src,
                             const std::string &what) -> Error {
      if (src.kind == "field" && !hasFieldPath(s.records_, *sigRec, src.name))
        return err(where + " " + what + ": source field \"" + src.name +
                   "\" is not declared in record \"" + sig.record + "\"");
      if (src.kind == "derived" && !src.from.empty() &&
          !hasFieldPath(s.records_, *sigRec, src.from))
        return err(where + " " + what + ": derived source's \"from\" field \"" +
                   src.from + "\" is not declared in record \"" + sig.record +
                   "\"");
      return Error::success();
    };
    if (sig.body)
      if (Error e = checkFieldRef(*sig.body, "body"))
        return std::move(e);
    if (sig.value) {
      if (Error e = checkFieldRef(*sig.value, "value"))
        return std::move(e);
      // Constant observations must be integers to aggregate; never silently substitute zero.
      if (sig.value->kind == "constant") {
        int64_t n;
        if (StringRef(sig.value->name).getAsInteger(10, n))
          return err(where + ": a constant metrics value must be an integer "
                             "literal, got \"" +
                     sig.value->name + "\"");
      }
    }
    for (const Attribute &a : sig.attributes)
      if (Error e = checkFieldRef(a.source,
                                  "attribute \"" + a.key + "\""))
        return std::move(e);

    s.signals_.push_back(std::move(sig));
  }

  // Extensions: core checks namespace shape only, preserving payload without interpretation.
  if (const auto *extObj = root->getObject("extensions")) {
    for (const auto &kv : *extObj) {
      StringRef ns = kv.first;
      if (!ns.contains('.'))
        return err("extensions: namespace \"" + ns +
                   "\" must be a reverse-DNS style stable name (containing "
                   "'.')");
      if (ns.starts_with(".") || ns.ends_with(".") || ns.contains(".."))
        return err("extensions: malformed namespace \"" + ns + "\"");
      s.extensions_.emplace(ns.str(), kv.second);
    }
  } else if (root->get("extensions")) {
    return err("schema: \"extensions\" must be an object");
  }

  // Sort all collections by name for canonical output.
  auto bySymbol = [](const auto &a, const auto &b) { return a.symbol < b.symbol; };
  auto byName = [](const auto &a, const auto &b) { return a.name < b.name; };
  auto byId = [](const auto &a, const auto &b) { return a.id < b.id; };
  llvm::sort(s.records_, bySymbol);
  llvm::sort(s.maps_, bySymbol);
  llvm::sort(s.programs_, byName);
  llvm::sort(s.signals_, byName);
  llvm::sort(s.clocks_, byId);
  llvm::sort(s.valueMaps_, byId);
  llvm::sort(s.boundsSets_, byId);
  return s;
}

//===----------------------------------------------------------------------===//
// Serialize canonical form
//===----------------------------------------------------------------------===//
std::string Schema::serializeJSON() const {
  std::string out;
  raw_string_ostream os(out);
  os << "{\n";
  os << "  \"version\": " << kSchemaVersion << ",\n";

  auto cov = [](Coverage c) { return c == Coverage::Complete ? "complete" : "omitted"; };
  os << "  \"coverage\": {\n";
  os << "    \"programs\": \"" << cov(coverage_.programs) << "\",\n";
  os << "    \"maps\": \"" << cov(coverage_.maps) << "\",\n";
  os << "    \"records\": \"" << cov(coverage_.records) << "\",\n";
  os << "    \"telemetry\": \"" << cov(coverage_.telemetry) << "\"\n";
  os << "  },\n";

  // ---- core ----
  os << "  \"core\": {\n";

  os << "    \"records\": [\n";
  for (auto [i, r] : llvm::enumerate(records_)) {
    os << "      {\n";
    os << "        \"symbol\": "; emitStr(os, r.symbol); os << ",\n";
    os << "        \"id\": " << r.id << ",\n";
    os << "        \"size\": " << r.size << ",\n";
    os << "        \"min_size\": " << r.minSize << ",\n";
    os << "        \"alignment\": " << r.alignment << ",\n";
    os << "        \"required_through\": "; emitStr(os, r.requiredThrough); os << ",\n";
    os << "        \"note\": "; emitStr(os, r.note); os << ",\n";
    os << "        \"fields\": [\n";
    for (auto [j, f] : llvm::enumerate(r.fields)) {
      os << "          {\n";
      os << "            \"name\": "; emitStr(os, f.name); os << ",\n";
      os << "            \"offset\": " << f.offset << ",\n";
      os << "            \"expose\": "; emitStr(os, f.expose); os << ",\n";
      os << "            \"note\": "; emitStr(os, f.note); os << ",\n";
      os << "            \"type\": ";
      emitType(os, f.type, 12);
      os << "\n          }" << (j + 1 < r.fields.size() ? "," : "") << "\n";
    }
    os << "        ]\n";
    os << "      }" << (i + 1 < records_.size() ? "," : "") << "\n";
  }
  os << "    ],\n";

  os << "    \"maps\": [\n";
  for (auto [i, m] : llvm::enumerate(maps_)) {
    os << "      {\n";
    os << "        \"symbol\": "; emitStr(os, m.symbol); os << ",\n";
    os << "        \"kind\": \"" << mapKindName(m.kind) << "\",\n";
    if (m.key) {
      os << "        \"key\": ";
      emitType(os, *m.key, 8);
      os << ",\n";
    }
    if (m.value) {
      os << "        \"value\": ";
      emitType(os, *m.value, 8);
      os << ",\n";
    }
    os << "        \"max_entries\": " << m.maxEntries << ",\n";
    os << "        \"flags\": " << m.flags << ",\n";
    os << "        \"record\": "; emitStr(os, m.record); os << ",\n";
    os << "        \"note\": "; emitStr(os, m.note); os << "\n";
    os << "      }" << (i + 1 < maps_.size() ? "," : "") << "\n";
  }
  os << "    ],\n";

  os << "    \"programs\": [\n";
  for (auto [i, p] : llvm::enumerate(programs_)) {
    os << "      {\n";
    os << "        \"name\": "; emitStr(os, p.name); os << ",\n";
    os << "        \"kind\": "; emitStr(os, p.kind); os << ",\n";
    os << "        \"attach_target\": "; emitStr(os, p.attachTarget); os << ",\n";
    os << "        \"maps\": [";
    for (auto [j, mm] : llvm::enumerate(p.maps)) {
      if (j)
        os << ", ";
      emitStr(os, mm);
    }
    os << "],\n";
    os << "        \"note\": "; emitStr(os, p.note); os << "\n";
    os << "      }" << (i + 1 < programs_.size() ? "," : "") << "\n";
  }
  os << "    ]\n";
  os << "  },\n";

  // ---- telemetry ----
  os << "  \"telemetry\": {\n";

  os << "    \"clocks\": [\n";
  for (auto [i, c] : llvm::enumerate(clocks_)) {
    os << "      {\n";
    os << "        \"id\": "; emitStr(os, c.id); os << ",\n";
    os << "        \"kernel_source\": "; emitStr(os, c.kernelSource); os << ",\n";
    os << "        \"posix_clock\": "; emitStr(os, c.posixClock); os << ",\n";
    os << "        \"to_wall\": "; emitStr(os, c.toWall); os << ",\n";
    os << "        \"note\": "; emitStr(os, c.note); os << "\n";
    os << "      }" << (i + 1 < clocks_.size() ? "," : "") << "\n";
  }
  os << "    ],\n";

  os << "    \"value_maps\": [\n";
  for (auto [i, v] : llvm::enumerate(valueMaps_)) {
    os << "      {\n";
    os << "        \"id\": "; emitStr(os, v.id); os << ",\n";
    os << "        \"unknown\": "; emitStr(os, v.unknown); os << ",\n";
    os << "        \"arch_invariant\": " << (v.archInvariant ? "true" : "false") << ",\n";
    os << "        \"btf_mode\": "; emitStr(os, v.btfMode); os << ",\n";
    os << "        \"btf_anchor\": "; emitStr(os, v.btfAnchor); os << ",\n";
    os << "        \"btf_prefix\": "; emitStr(os, v.btfPrefix); os << ",\n";
    os << "        \"btf_omit\": "; emitStr(os, v.btfOmit); os << ",\n";
    os << "        \"authority\": "; emitStr(os, v.authority); os << ",\n";
    os << "        \"note\": "; emitStr(os, v.note); os << ",\n";
    os << "        \"entries\": [\n";
    for (auto [j, e] : llvm::enumerate(v.entries)) {
      os << "          {\"value\": " << e.value << ", \"name\": ";
      emitStr(os, e.name);
      os << "}" << (j + 1 < v.entries.size() ? "," : "") << "\n";
    }
    os << "        ]\n";
    os << "      }" << (i + 1 < valueMaps_.size() ? "," : "") << "\n";
  }
  os << "    ],\n";

  os << "    \"bounds_sets\": [\n";
  for (auto [i, b] : llvm::enumerate(boundsSets_)) {
    os << "      {\n";
    os << "        \"id\": "; emitStr(os, b.id); os << ",\n";
    os << "        \"unit\": "; emitStr(os, b.unit); os << ",\n";
    os << "        \"authority\": "; emitStr(os, b.authority); os << ",\n";
    os << "        \"note\": "; emitStr(os, b.note); os << ",\n";
    os << "        \"bounds\": [";
    for (auto [j, d] : llvm::enumerate(b.bounds)) {
      if (j)
        os << ", ";
      os << json::Value(d);
    }
    os << "]\n";
    os << "      }" << (i + 1 < boundsSets_.size() ? "," : "") << "\n";
  }
  os << "    ],\n";

  os << "    \"signals\": [\n";
  for (auto [i, sg] : llvm::enumerate(signals_)) {
    os << "      {\n";
    os << "        \"name\": "; emitStr(os, sg.name); os << ",\n";
    os << "        \"signal\": "; emitStr(os, sg.signal); os << ",\n";
    os << "        \"record\": "; emitStr(os, sg.record); os << ",\n";
    os << "        \"span_name\": "; emitStr(os, sg.spanName); os << ",\n";
    os << "        \"span_kind\": "; emitStr(os, sg.spanKind); os << ",\n";
    os << "        \"note\": "; emitStr(os, sg.note); os << ",\n";
    os << "        \"timing\": {\n";
    os << "          \"start\": "; emitStr(os, sg.timing.start); os << ",\n";
    os << "          \"clock\": "; emitStr(os, sg.timing.clock); os << ",\n";
    os << "          \"end\": "; emitStr(os, sg.timing.end); os << "\n";
    os << "        },\n";
    if (sg.body) {
      os << "        \"body\": ";
      emitSource(os, *sg.body, 8);
      os << ",\n";
    }
    if (sg.value) {
      os << "        \"value\": ";
      emitSource(os, *sg.value, 8);
      os << ",\n";
    }
    if (sg.metric) {
      os << "        \"metric\": {\n";
      os << "          \"kind\": "; emitStr(os, sg.metric->kind); os << ",\n";
      os << "          \"unit\": "; emitStr(os, sg.metric->unit); os << ",\n";
      os << "          \"temporality\": "; emitStr(os, sg.metric->temporality);
      if (sg.metric->monotonic) {
        os << ",\n          \"monotonic\": "
           << (*sg.metric->monotonic ? "true" : "false");
      }
      if (sg.metric->scale)
        os << ",\n          \"scale\": " << *sg.metric->scale;
      if (sg.metric->zeroThreshold)
        os << ",\n          \"zero_threshold\": "
           << json::Value(*sg.metric->zeroThreshold);
      if (!sg.metric->bucketRule.empty()) {
        os << ",\n          \"bucket_rule\": ";
        emitStr(os, sg.metric->bucketRule);
      }
      os << "\n        },\n";
    }
    os << "        \"drop_when\": ";
    emitPredicate(os, sg.dropWhen, 8);
    os << ",\n";
    os << "        \"attributes\": [\n";
    for (auto [j, a] : llvm::enumerate(sg.attributes)) {
      os << "          {\n";
      os << "            \"key\": "; emitStr(os, a.key); os << ",\n";
      os << "            \"stability\": "; emitStr(os, a.stability); os << ",\n";
      os << "            \"note\": "; emitStr(os, a.note); os << ",\n";
      os << "            \"source\": ";
      emitSource(os, a.source, 12);
      os << ",\n";
      os << "            \"presence\": ";
      emitPredicate(os, a.presence, 12);
      os << "\n          }" << (j + 1 < sg.attributes.size() ? "," : "") << "\n";
    }
    os << "        ]\n";
    os << "      }" << (i + 1 < signals_.size() ? "," : "") << "\n";
  }
  os << "    ]\n";
  os << "  },\n";

  // ---- extensions ----
  os << "  \"extensions\": ";
  if (extensions_.empty()) {
    os << "{}\n";
  } else {
    os << "{\n";
    size_t i = 0;
    for (const auto &kv : extensions_) {
      os << "    ";
      emitStr(os, kv.first);
      os << ": ";
      emitCanonical(os, kv.second, 4);
      os << (++i < extensions_.size() ? "," : "") << "\n";
    }
    os << "  }\n";
  }
  os << "}\n";
  return out;
}

} // namespace spbpf
