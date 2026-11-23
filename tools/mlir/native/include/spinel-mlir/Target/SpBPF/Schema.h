// Canonical three-layer schema, chosen by the user on 2026-08-25:
// core: eBPF ABI/layout (programs, maps, records, types);
// telemetry: language-independent OpenTelemetry meaning (signal/clock/value_map/bounds_set);
// extensions: implementation wiring, preserved but not interpreted by core.
// A single canonical schema does not mean flattening every field into generic
// C++ types. Keep Spinel push_fn/enrichers/producer/consumer wiring under
// extensions["spinel.ebpf"]. Integer width/signedness/offset/alignment/endianness
// are required. Refuse unknown top-level keys; only extensions is extensible.
// Extension names must be stable reverse-DNS-style names containing a dot.
// Version is fixed at 1.
#ifndef SPINEL_MLIR_TARGET_SPBPF_SCHEMA_H
#define SPINEL_MLIR_TARGET_SPBPF_SCHEMA_H

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/JSON.h"

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace spbpf {

inline constexpr uint32_t kSchemaVersion = 1;

enum class Endianness { Little, Big };

// Coverage explicitly states what the schema canonicalizes. programs: [] must
// not ambiguously mean both a complete empty schema and a schema omitting
// program information: forgetting declarations would silently disable matching.
// complete requires every IR X in the schema and every schema X in the IR.
// omitted means this schema does not canonicalize X; skip only that comparison.
// Refuse missing coverage rather than defaulting it. No ambiguous partial value.
enum class Coverage { Complete, Omitted };

struct CoverageDecl {
  Coverage programs = Coverage::Complete;
  Coverage maps = Coverage::Complete;
  Coverage records = Coverage::Complete;
  Coverage telemetry = Coverage::Complete;
  bool operator==(const CoverageDecl &o) const {
    return programs == o.programs && maps == o.maps && records == o.records &&
           telemetry == o.telemetry;
  }
};

//===----------------------------------------------------------------------===//
// core: types
//===----------------------------------------------------------------------===//
struct Type;

struct IntType {
  uint32_t bits = 0;      // 8 / 16 / 32 / 64
  bool isSigned = false;
  Endianness endianness = Endianness::Little;
  uint32_t alignment = 0; // Power of two.
  bool operator==(const IntType &o) const;
};

// Named record references, not anonymous copies, map directly to BTF and Go named structs, as the
// user decided.
struct RecordRefType {
  std::string symbol;
  bool operator==(const RecordRefType &o) const { return symbol == o.symbol; }
};

struct ArrayType {
  std::unique_ptr<Type> element;
  uint64_t count = 0;
  ArrayType() = default;
  ArrayType(const ArrayType &o);
  ArrayType &operator=(const ArrayType &o);
  bool operator==(const ArrayType &o) const;
};

struct Type {
  std::variant<IntType, ArrayType, RecordRefType> v;
  bool operator==(const Type &o) const { return v == o.v; }
  bool operator!=(const Type &o) const { return !(*this == o); }
};

//===----------------------------------------------------------------------===//
// core: record / map / program
//===----------------------------------------------------------------------===//
struct Field {
  std::string name;
  Type type;
  uint64_t offset = 0;
  std::string expose;  // "" / "int" / "str" / ...: representation exposed to readers.
  std::string note;    // Optional documentation, unused by codegen.
  bool operator==(const Field &o) const {
    return name == o.name && type == o.type && offset == o.offset &&
           expose == o.expose && note == o.note;
  }
};

struct Record {
  std::string symbol;
  uint32_t id = 0;            // Ring-buffer identifier; 0 means none.
  uint64_t size = 0;          // Fixed size, or upper bound for variable-length records.
  uint64_t minSize = 0;       // record_min_bytes; fixed length when equal to size.
  uint32_t alignment = 0;
  std::string requiredThrough; // Fields through this one are present; "" means all.
  std::vector<Field> fields;
  std::string note;
  bool isVariableLength() const { return minSize != size; }
  bool operator==(const Record &o) const {
    return symbol == o.symbol && id == o.id && size == o.size &&
           minSize == o.minSize && alignment == o.alignment &&
           requiredThrough == o.requiredThrough && fields == o.fields &&
           note == o.note;
  }
};

enum class MapKind { Hash, Array, RingBuf, PerCpuArray };

// Single source of spellings shared by serialization and verify-schema.
const char *mapKindName(MapKind k);

// Represent ring buffers as MapKind::RingBuf too. They have no key/value, so do not require those
// fields for every map.
struct Map {
  std::string symbol;
  MapKind kind = MapKind::Hash;
  std::optional<Type> key;
  std::optional<Type> value;
  uint64_t maxEntries = 0;  // Bytes for a ring buffer.
  uint64_t flags = 0;
  std::string record;       // Record symbol carried by ringbuf; "" means none.
  std::string note;
  bool operator==(const Map &o) const {
    return symbol == o.symbol && kind == o.kind && key == o.key &&
           value == o.value && maxEntries == o.maxEntries &&
           flags == o.flags && record == o.record && note == o.note;
  }
};

struct Program {
  std::string name;
  std::string kind;              // "xdp"
  std::string attachTarget;
  std::vector<std::string> maps; // Positionally matches spbpf.program maps [...].
  std::string note;
  bool operator==(const Program &o) const {
    return name == o.name && kind == o.kind && attachTarget == o.attachTarget &&
           maps == o.maps && note == o.note;
  }
};

// Telemetry predicate/source AST: use the already structured representation, not prose or C/Ruby
// expressions. Unrepresentable forms cross the boundary as runtime_extension rather than
// disappearing.
struct Operand {
  std::string kind;  // "field" / "derived" / "constant"
  std::string name;
  bool operator==(const Operand &o) const {
    return kind == o.kind && name == o.name;
  }
};

struct Predicate {
  // always / never / empty / nonempty / zero / nonzero / byte_eq /
  // any / all / not / unexpressible.
  // unexpressible explicitly records a predicate that could not be represented;
  // retain its original condition in detail rather than silently dropping it.
  std::string op;
  std::optional<Operand> operand;
  uint64_t index = 0;              // byte_eq byte index.
  std::vector<uint8_t> bytes;      // byte_eq
  std::vector<Predicate> args;     // any / all / not
  std::string detail;              // unexpressible: the original unrepresentable condition.
  bool operator==(const Predicate &o) const {
    return op == o.op && operand == o.operand && index == o.index &&
           bytes == o.bytes && args == o.args && detail == o.detail;
  }
};

struct Source {
  // field / derived / constant / runtime_extension
  std::string kind;
  std::string name;
  std::string from;   // Source field; may be empty.
  std::string detail; // Preserve unrepresentable prose here rather than dropping it.
  bool operator==(const Source &o) const {
    return kind == o.kind && name == o.name && from == o.from &&
           detail == o.detail;
  }
};

struct Attribute {
  std::string key;        // semconv key
  std::string stability;  // "semconv" / "spinel" / ...
  Source source;
  Predicate presence;
  std::string note;
  bool operator==(const Attribute &o) const {
    return key == o.key && stability == o.stability && source == o.source &&
           presence == o.presence && note == o.note;
  }
};

struct Timing {
  std::string start;  // For example "record_ktime:hdr.timestamp".
  std::string clock;  // References clocks[].id.
  std::string end;    // For example "start_plus:duration_ns".
  bool operator==(const Timing &o) const {
    return start == o.start && clock == o.clock && end == o.end;
  }
};

// metric.kind is closed: sum or exponential_histogram; refuse unknown kinds.
// sum requires monotonic and forbids scale/zero_threshold/bucket_rule.
// exponential_histogram requires scale/zero_threshold/bucket_rule and forbids
// monotonic. bucket_rule is a closed scalar-observation mapping token:
// otlp_lower_exclusive uses OTLP's standard rule. At scale 0, v above the zero
// threshold belongs to i where 2^i < v <= 2^(i+1); v at/below the threshold
// enters zero_count. Declare the open/closed endpoints to align Spinel, MLIR and Go.
struct Metric {
  std::string kind;         // "sum" / "exponential_histogram" (closed set)
  std::string unit;         // UCUM
  std::string temporality;  // "delta" / "cumulative"
  std::optional<bool> monotonic;       // sum only.
  std::optional<int64_t> scale;        // exponential_histogram only.
  std::optional<double> zeroThreshold; // exponential_histogram only.
  std::string bucketRule;              // exponential_histogram only.
  bool operator==(const Metric &o) const {
    return kind == o.kind && unit == o.unit && temporality == o.temporality &&
           monotonic == o.monotonic && scale == o.scale &&
           zeroThreshold == o.zeroThreshold && bucketRule == o.bucketRule;
  }
};

// Signal-specific required/forbidden fields:
// traces: require span_name/span_kind; forbid body/value.
// logs: require body (Source); forbid value/metric/span_*.
// metrics: require value (Source) and metric; forbid body/span_*.
// Reuse Source for body/value to exclude C/Ruby expressions and exporter
// function names from generic types; Spinel wiring belongs in extensions.spinel.ebpf.
struct Signal {
  std::string name;
  std::string signal;   // "traces" / "metrics" / "logs"
  std::string record;   // Source record symbol.
  std::string spanName; // Template; may contain "{attr.key}".
  std::string spanKind; // "INTERNAL" / "CLIENT" / ...
  Timing timing;
  Predicate dropWhen;
  std::vector<Attribute> attributes;
  std::optional<Source> body;   // logs: source of LogRecord body/main value.
  std::optional<Source> value;  // metrics: observation source.
  std::optional<Metric> metric;
  std::string note;
  bool operator==(const Signal &o) const {
    return name == o.name && signal == o.signal && record == o.record &&
           spanName == o.spanName && spanKind == o.spanKind &&
           timing == o.timing && dropWhen == o.dropWhen &&
           attributes == o.attributes && body == o.body && value == o.value &&
           metric == o.metric && note == o.note;
  }
};

struct Clock {
  std::string id;
  std::string kernelSource; // "bpf_ktime_get_ns()"
  std::string posixClock;   // "CLOCK_MONOTONIC"
  std::string toWall;       // Conversion to wall-clock time.
  std::string note;
  bool operator==(const Clock &o) const {
    return id == o.id && kernelSource == o.kernelSource &&
           posixClock == o.posixClock && toWall == o.toWall && note == o.note;
  }
};

struct ValueMapEntry {
  int64_t value = 0;
  std::string name;
  bool operator==(const ValueMapEntry &o) const {
    return value == o.value && name == o.name;
  }
};

// Value-to-name mapping, including instructions for BTF validation against the running kernel
// rather than trusting the declaration.
struct ValueMap {
  std::string id;
  std::string unknown;        // Unknown-value spelling, e.g. "unnamed(%ld)".
  bool archInvariant = false; // Whether the value is architecture-independent.
  std::string btfMode;        // For example "names"; "" skips BTF matching.
  std::string btfAnchor;      // Enumerator anchoring the comparison.
  std::string btfPrefix;      // Namespace prefix to strip.
  std::string btfOmit;        // Enumerator excluded from comparison.
  std::string authority;      // Authority for the value.
  std::string note;
  std::vector<ValueMapEntry> entries;
  bool operator==(const ValueMap &o) const {
    return id == o.id && unknown == o.unknown &&
           archInvariant == o.archInvariant && btfMode == o.btfMode &&
           btfAnchor == o.btfAnchor && btfPrefix == o.btfPrefix &&
           btfOmit == o.btfOmit && authority == o.authority &&
           note == o.note && entries == o.entries;
  }
};

struct BoundsSet {
  std::string id;
  std::string unit;
  std::string authority;
  std::string note;
  std::vector<double> bounds;
  bool operator==(const BoundsSet &o) const {
    return id == o.id && unit == o.unit && authority == o.authority &&
           note == o.note && bounds == o.bounds;
  }
};

//===----------------------------------------------------------------------===//
// Schema
//===----------------------------------------------------------------------===//
class Schema {
public:
  static llvm::Expected<Schema> parseJSON(llvm::StringRef json);

  // Canonical bytes for the same Schema; canonicalize and preserve extensions too, without
  // interpreting their payloads.
  std::string serializeJSON() const;

  const CoverageDecl &coverage() const { return coverage_; }

  // core
  const std::vector<Program> &programs() const { return programs_; }
  const std::vector<Map> &maps() const { return maps_; }
  const std::vector<Record> &records() const { return records_; }
  // telemetry
  const std::vector<Signal> &signals() const { return signals_; }
  const std::vector<Clock> &clocks() const { return clocks_; }
  const std::vector<ValueMap> &valueMaps() const { return valueMaps_; }
  const std::vector<BoundsSet> &boundsSets() const { return boundsSets_; }
  // Extensions: namespace to uninterpreted payload.
  const std::map<std::string, llvm::json::Value> &extensions() const {
    return extensions_;
  }

  // Type size in bytes; resolve record_ref through records().
  llvm::Expected<uint64_t> sizeOf(const Type &t) const;

  bool operator==(const Schema &o) const;

private:
  Schema() = default;
  CoverageDecl coverage_;
  std::vector<Program> programs_;
  std::vector<Map> maps_;
  std::vector<Record> records_;
  std::vector<Signal> signals_;
  std::vector<Clock> clocks_;
  std::vector<ValueMap> valueMaps_;
  std::vector<BoundsSet> boundsSets_;
  std::map<std::string, llvm::json::Value> extensions_;
};

} // namespace spbpf

#endif // SPINEL_MLIR_TARGET_SPBPF_SCHEMA_H
