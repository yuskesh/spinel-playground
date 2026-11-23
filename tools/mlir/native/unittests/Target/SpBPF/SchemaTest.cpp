// Three-layer schema unit tests. The user chose no gtest on 2026-08-25: Debian LLVM 22 and Homebrew
// lacked libllvm_gtest, this repository had no googletest precedent, and it added no test
// capability for this task. Follow the existing small executable plus lit pattern. The Test
// filename followed the original file list, not a gtest dependency. Continue and count every
// failure so later regressions remain visible.
#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "llvm/Support/Error.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <string>

using namespace llvm;
using namespace spbpf;

namespace {

int failures = 0;
int checks = 0;

void ok(bool cond, const Twine &what) {
  ++checks;
  if (cond)
    outs() << "ok   " << what << "\n";
  else {
    ++failures;
    outs() << "FAIL " << what << "\n";
  }
}

void expectReject(StringRef json, StringRef needle, const Twine &what) {
  auto parsed = Schema::parseJSON(json);
  if (parsed) {
    ++checks;
    ++failures;
    outs() << "FAIL " << what << " (accepted, expected rejection)\n";
    return;
  }
  std::string msg = toString(parsed.takeError());
  bool hit = StringRef(msg).contains(needle);
  ok(hit, what + " [" + (hit ? msg : "got: " + msg) + "]");
}

// Construct a valid skeleton with one independently breakable position.
std::string wrap(StringRef records, StringRef maps = "", StringRef programs = "",
                 StringRef telemetry = "", StringRef extensions = "{}",
                 StringRef version = "1") {
  std::string tel = telemetry.empty()
                        ? std::string("\"signals\": [], \"clocks\": [], "
                                      "\"value_maps\": [], \"bounds_sets\": []")
                        : telemetry.str();
  return ("{\"version\": " + version +
          ", \"coverage\": {\"programs\": \"complete\", \"maps\": \"complete\", "
          "\"records\": \"complete\", \"telemetry\": \"complete\"}"
          ", \"core\": {\"records\": [" + records +
          "], \"maps\": [" + maps + "], \"programs\": [" + programs +
          "]}, \"telemetry\": {" + tel + "}, \"extensions\": " + extensions +
          "}")
      .str();
}

std::string intType(StringRef bits, StringRef align, StringRef sign = "false") {
  return ("{\"kind\": \"int\", \"bits\": " + bits + ", \"signed\": " + sign +
          ", \"endianness\": \"little\", \"alignment\": " + align + "}")
      .str();
}

std::string fieldOf(StringRef name, StringRef offset, StringRef type) {
  return ("{\"name\": \"" + name + "\", \"offset\": " + offset +
          ", \"expose\": \"\", \"note\": \"\", \"type\": " + type + "}")
      .str();
}

std::string recordOf(StringRef fields, StringRef symbol = "r",
                     StringRef id = "1", StringRef size = "16",
                     StringRef minSize = "16", StringRef align = "8",
                     StringRef reqThrough = "") {
  return ("{\"symbol\": \"" + symbol + "\", \"id\": " + id + ", \"size\": " +
          size + ", \"min_size\": " + minSize + ", \"alignment\": " + align +
          ", \"required_through\": \"" + reqThrough +
          "\", \"note\": \"\", \"fields\": [" + fields + "]}")
      .str();
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    errs() << "usage: SchemaTest <schema-roundtrip.json>\n";
    return 2;
  }

  // 1. Decode/encode fixtures.
  auto bufOrErr = MemoryBuffer::getFile(argv[1]);
  if (!bufOrErr) {
    errs() << "cannot read fixture " << argv[1] << "\n";
    return 2;
  }
  auto first = Schema::parseJSON((*bufOrErr)->getBuffer());
  if (!first) {
    outs() << "FAIL fixture does not parse: " << toString(first.takeError())
           << "\n";
    return 1;
  }
  ok(true, "fixture parses");

  // ---- core ----
  ok(first->records().size() == 2, "core: 2 records");
  ok(first->maps().size() == 2 && !first->programs().empty(),
     "core: 2 maps and at least one program");
  const Record *ev = nullptr;
  for (const Record &r : first->records())
    if (r.symbol == "event")
      ev = &r;
  ok(ev != nullptr, "core: the event record is present");
  if (ev) {
    ok(ev->isVariableLength() && ev->minSize == 40,
       "core: min_size marks the record variable length");
    ok(ev->requiredThrough == "pid", "core: required_through survives decode");
    ok(std::holds_alternative<RecordRefType>(ev->fields[0].type.v),
       "core: a nested struct is a record_ref, not an anonymous copy");
    ok(std::holds_alternative<ArrayType>(ev->fields[1].type.v),
       "core: char[16] is an array type");
    auto sz = first->sizeOf(ev->fields[1].type);
    ok(sz && *sz == 16, "core: array size resolves to 16");
    auto hsz = first->sizeOf(ev->fields[0].type);
    ok(hsz && *hsz == 16, "core: record_ref size resolves through the schema");
    ok(ev->fields[1].expose == "str", "core: expose survives decode");
    ok(!ev->fields[1].note.empty(), "core: field note survives decode");
  }
  const Map *rb = nullptr;
  for (const Map &m : first->maps())
    if (m.kind == MapKind::RingBuf)
      rb = &m;
  ok(rb && !rb->key && !rb->value && rb->record == "event",
     "core: a ringbuf map has no key/value and names its record");

  // ---- telemetry ----
  ok(first->signals().size() == 4, "telemetry: 4 signals");
  ok(first->clocks().size() == 1 && first->valueMaps().size() == 1 &&
         first->boundsSets().size() == 1,
     "telemetry: clock / value_map / bounds_set all decode");
  const Signal *tr = nullptr;
  for (const Signal &s : first->signals())
    if (s.signal == "traces")
      tr = &s;
  ok(tr != nullptr, "telemetry: the traces signal is present");
  if (tr) {
    ok(StringRef(tr->spanName).contains("{"),
       "telemetry: span name template survives");
    ok(tr->spanKind == "INTERNAL", "telemetry: span kind survives");
    ok(tr->timing.clock == "monotonic", "telemetry: timing form survives");
    ok(tr->dropWhen.op == "zero" && tr->dropWhen.operand &&
           tr->dropWhen.operand->name == "pid",
       "telemetry: drop predicate survives as an AST");
    ok(tr->attributes.size() == 4, "telemetry: 4 attributes");
    ok(tr->attributes[0].key == "process.pid" &&
           tr->attributes[0].stability == "semconv",
       "telemetry: semconv key and stability survive");
    ok(tr->attributes[1].source.kind == "derived" &&
           tr->attributes[1].source.from == "comm",
       "telemetry: a derived attribute keeps the field it came from");
    ok(tr->attributes[3].source.kind == "runtime_extension" &&
           !tr->attributes[3].source.detail.empty(),
       "telemetry: what cannot be expressed goes to runtime_extension, "
       "not silently dropped");
    ok(tr->attributes[3].presence.op == "any" &&
           tr->attributes[3].presence.args.size() == 2,
       "telemetry: nested presence predicates survive");
  }
  const ValueMap &vm = first->valueMaps()[0];
  ok(vm.btfMode == "names" && vm.btfAnchor == "TCP_ESTABLISHED" &&
         vm.unknown == "unnamed(%ld)",
     "telemetry: value map keeps its BTF check directives");

  // Telemetry body/value/metric vocabulary.
  const Signal *sumSig = nullptr, *logSig = nullptr, *ehSig = nullptr;
  for (const Signal &s2 : first->signals()) {
    if (s2.name == "exec_total")
      sumSig = &s2;
    if (s2.name == "exec_log")
      logSig = &s2;
    if (s2.name == "exec_latency")
      ehSig = &s2;
  }
  ok(sumSig && sumSig->metric && sumSig->metric->kind == "sum" &&
         sumSig->metric->monotonic && *sumSig->metric->monotonic,
     "telemetry: sum keeps its declared monotonic");
  ok(sumSig && sumSig->value && sumSig->value->kind == "constant" &&
         sumSig->value->name == "1",
     "telemetry: a metrics value source survives (constant 1 per record)");
  ok(logSig && logSig->body && logSig->body->kind == "field" &&
         logSig->body->name == "pid",
     "telemetry: a logs body source survives");
  ok(ehSig && ehSig->metric && ehSig->metric->kind == "exponential_histogram" &&
         ehSig->metric->scale && *ehSig->metric->scale == 0 &&
         ehSig->metric->zeroThreshold && *ehSig->metric->zeroThreshold == 0 &&
         ehSig->metric->bucketRule == "otlp_lower_exclusive",
     "telemetry: exponential_histogram keeps scale / zero_threshold / "
     "bucket_rule");
  ok(ehSig && ehSig->value && ehSig->value->kind == "field" &&
         ehSig->value->name == "duration_ns",
     "telemetry: exphist observes a declared record field");

  // ---- extensions ----
  ok(first->extensions().size() == 2, "extensions: both namespaces kept");
  ok(first->extensions().count("spinel.ebpf") == 1,
     "extensions: spinel.ebpf is preserved verbatim (core does not read it)");

  // Encode/decode equivalence and canonical encoding idempotence.
  std::string once = first->serializeJSON();
  auto second = Schema::parseJSON(once);
  if (!second) {
    outs() << "FAIL canonical output does not parse: "
           << toString(second.takeError()) << "\n";
    return 1;
  }
  ok(*first == *second, "decode(encode(x)) == x");
  ok(once == second->serializeJSON(), "encode is idempotent (canonical)");
  ok(StringRef(once).contains("spnl_otlp_exec_span_push") &&
         StringRef(once).contains("example.vendor"),
     "extension payload survives a parse/serialize round trip");

  // 2. Negative tests.
  std::string okField = fieldOf("a", "0", intType("64", "8"));

  // Unknown version
  expectReject(wrap(recordOf(okField), "", "", "", "{}", "2"),
               "version must be 1", "rejects unknown version");

  // Refuse unknown top-level keys; only extensions is extensible.
  expectReject(R"({"version":1,"coverage":{"programs":"complete","maps":"complete","records":"complete","telemetry":"complete"},"core":{"records":[],"maps":[],"programs":[]},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{},"extra":1})",
               "unknown key \"extra\"", "rejects an unknown top-level key");
  expectReject(R"({"version":1,"coverage":{"programs":"complete","maps":"complete","records":"complete","telemetry":"complete"},"core":{"records":[],"maps":[],"programs":[],"extra":1},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{}})",
               "unknown key \"extra\"", "rejects an unknown key inside core");

  // Extension namespaces use stable reverse-DNS-style names.
  expectReject(wrap(recordOf(okField), "", "", "", R"({"nodots": {}})"),
               "reverse-DNS style", "rejects an extension namespace without a dot");

  // Duplicates
  expectReject(wrap(recordOf(okField) + "," + recordOf(okField, "r", "2")),
               "duplicate record symbol", "rejects a duplicate record symbol");
  expectReject(wrap(recordOf(okField, "r", "1") + "," +
                    recordOf(okField, "s", "1")),
               "duplicate record id", "rejects a duplicate record id");
  expectReject(wrap(recordOf(okField + "," +
                             fieldOf("a", "8", intType("64", "8")))),
               "duplicate field name", "rejects a duplicate field name");

  // Overlapping fields.
  expectReject(wrap(recordOf(fieldOf("a", "0", intType("64", "8")) + "," +
                             fieldOf("b", "4", intType("32", "4")))),
               "overlap", "rejects overlapping fields");

  // Non-power-of-two alignment
  expectReject(wrap(recordOf(okField, "r", "1", "16", "16", "3")),
               "alignment must be a power of two",
               "rejects a non-power-of-two record alignment");
  expectReject(wrap(recordOf(fieldOf("a", "0", intType("64", "6")))),
               "alignment must be a power of two",
               "rejects a non-power-of-two field alignment");

  // Required contract fields.
  expectReject(wrap(recordOf(fieldOf(
                   "a", "0",
                   R"({"kind":"int","bits":64,"signed":false,"endianness":"little"})"))),
               "missing or non-integer \"alignment\"",
               "rejects an int type missing alignment");
  expectReject(wrap(recordOf(fieldOf(
                   "a", "0",
                   R"({"kind":"int","bits":64,"endianness":"little","alignment":8})"))),
               "missing or non-boolean \"signed\"",
               "rejects an int type missing signedness");
  expectReject(wrap(recordOf(fieldOf(
                   "a", "0",
                   R"({"kind":"int","bits":64,"signed":false,"alignment":8})"))),
               "missing or non-string \"endianness\"",
               "rejects an int type missing endianness");

  // Type resolution.
  expectReject(wrap(recordOf(fieldOf(
                   "a", "0", R"({"kind":"record_ref","symbol":"nope"})"))),
               "not declared in the schema",
               "rejects a record_ref to an undeclared record");
  expectReject(wrap(recordOf(fieldOf("a", "0",
                                     R"({"kind":"record_ref","symbol":"r"})"),
                             "r", "1", "16", "16", "8")),
               "cyclic", "rejects a self-referential record");
  expectReject(wrap(recordOf(fieldOf(
                   "a", "0",
                   std::string(R"({"kind":"array","count":0,"element":)") +
                       intType("64", "8") + "}"))),
               "array count must be positive",
               "rejects a zero-length array");

  // min_size / required_through
  expectReject(wrap(recordOf(okField, "r", "1", "16", "24")),
               "exceeds size", "rejects min_size greater than size");
  expectReject(wrap(recordOf(okField, "r", "1", "16", "16", "8", "nope")),
               "required_through", "rejects required_through naming no field");

  // Ring-buffer shape.
  expectReject(
      wrap(recordOf(okField),
           std::string(R"({"symbol":"rb","kind":"ringbuf","key":)") +
               intType("32", "4") +
               R"(,"max_entries":4096,"flags":0,"record":"r","note":""})"),
      "no key/value", "rejects a ringbuf carrying a key");
  expectReject(
      wrap(recordOf(okField),
           R"({"symbol":"rb","kind":"ringbuf","max_entries":4096,"flags":0,"record":"","note":""})"),
      "must name the record", "rejects a ringbuf naming no record");
  expectReject(
      wrap(recordOf(okField),
           R"({"symbol":"rb","kind":"ringbuf","max_entries":5000,"flags":0,"record":"r","note":""})"),
      "power of two", "rejects a ringbuf size that is not a power of two");
  expectReject(
      wrap(recordOf(okField),
           R"({"symbol":"h","kind":"hash","max_entries":8,"flags":0,"record":"","note":""})"),
      "needs both key and value", "rejects a hash map without key/value");

  // Predicate shape.
  expectReject(
      wrap(recordOf(okField), "", "",
           R"("signals":[{"name":"s","signal":"logs","record":"r","span_name":"","span_kind":"","note":"",
           "timing":{"start":"x","clock":"c","end":"y"},
           "drop_when":{"op":"bogus"},"attributes":[]}],
           "clocks":[{"id":"c","kernel_source":"k","posix_clock":"p","to_wall":"w","note":""}],
           "value_maps":[],"bounds_sets":[])"),
      "unknown predicate op", "rejects an unknown predicate op");
  expectReject(
      wrap(recordOf(okField), "", "",
           R"("signals":[{"name":"s","signal":"logs","record":"r","span_name":"","span_kind":"","note":"",
           "timing":{"start":"x","clock":"c","end":"y"},
           "drop_when":{"op":"always","operand":{"kind":"field","name":"a"}},"attributes":[]}],
           "clocks":[{"id":"c","kernel_source":"k","posix_clock":"p","to_wall":"w","note":""}],
           "value_maps":[],"bounds_sets":[])"),
      "takes no operand", "rejects an operand on a nullary predicate");

  // Signal reference consistency.
  expectReject(
      wrap(recordOf(okField), "", "",
           R"("signals":[{"name":"s","signal":"traces","record":"r","span_name":"n","span_kind":"","note":"",
           "timing":{"start":"x","clock":"nope","end":"y"},
           "drop_when":{"op":"never"},"attributes":[]}],
           "clocks":[],"value_maps":[],"bounds_sets":[])"),
      "is not declared in telemetry.clocks",
      "rejects a signal referencing an undeclared clock");
  expectReject(
      wrap(recordOf(okField), "", "",
           R"("signals":[{"name":"s","signal":"metrics","record":"r","span_name":"","span_kind":"","note":"",
           "timing":{"start":"x","clock":"c","end":"y"},
           "drop_when":{"op":"never"},"attributes":[]}],
           "clocks":[{"id":"c","kernel_source":"k","posix_clock":"p","to_wall":"w","note":""}],
           "value_maps":[],"bounds_sets":[])"),
      "needs a \"metric\" block", "rejects a metrics signal with no metric block");

  // Signal-specific required/forbidden fields and reference consistency.
  auto telOf = [](StringRef sig) {
    return ("\"signals\":[" + sig +
            "],\"clocks\":[{\"id\":\"c\",\"kernel_source\":\"k\","
            "\"posix_clock\":\"p\",\"to_wall\":\"w\",\"note\":\"\"}],"
            "\"value_maps\":[],\"bounds_sets\":[]")
        .str();
  };
  auto sigOf = [](StringRef kind, StringRef mid) {
    return ("{\"name\":\"s\",\"signal\":\"" + kind +
            "\",\"record\":\"r\",\"span_name\":\"\",\"span_kind\":\"\","
            "\"note\":\"\",\"timing\":{\"start\":\"x\",\"clock\":\"c\","
            "\"end\":\"y\"},\"drop_when\":{\"op\":\"never\"}," + mid +
            "\"attributes\":[]}")
        .str();
  };
  std::string fieldA = R"("value":{"kind":"field","name":"a","from":"","detail":""},)";
  std::string bodyA = R"("body":{"kind":"field","name":"a","from":"","detail":""},)";
  std::string sumM =
      R"("metric":{"kind":"sum","unit":"1","temporality":"cumulative","monotonic":true},)";

  // metric.kind is closed; refuse obsolete counter and unknown values.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       fieldA +
                           R"("metric":{"kind":"counter","unit":"1","temporality":"cumulative"},)"))),
      "metric kind must be", "rejects metric kind outside the closed set");
  // sum requires monotonic.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       fieldA +
                           R"("metric":{"kind":"sum","unit":"1","temporality":"cumulative"},)"))),
      "missing or non-boolean \"monotonic\"",
      "rejects a sum metric with no monotonic");
  // sum forbids exponential-histogram fields.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       fieldA +
                           R"("metric":{"kind":"sum","unit":"1","temporality":"cumulative","monotonic":true,"scale":0},)"))),
      "takes no scale", "rejects a sum metric carrying a scale");
  // exponential_histogram requires scale/zero_threshold/bucket_rule.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       fieldA +
                           R"("metric":{"kind":"exponential_histogram","unit":"1","temporality":"cumulative","zero_threshold":0,"bucket_rule":"otlp_lower_exclusive"},)"))),
      "missing or non-integer \"scale\"",
      "rejects an exponential_histogram with no scale");
  // Bucket mapping rules are closed too.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       fieldA +
                           R"("metric":{"kind":"exponential_histogram","unit":"1","temporality":"cumulative","scale":0,"zero_threshold":0,"bucket_rule":"log2"},)"))),
      "bucket_rule must be", "rejects an unknown bucket_rule");
  // logs requires body; metrics requires value.
  expectReject(wrap(recordOf(okField), "", "", telOf(sigOf("logs", ""))),
               "needs a \"body\"", "rejects a logs signal with no body");
  expectReject(wrap(recordOf(okField), "", "", telOf(sigOf("metrics", sumM))),
               "needs a \"value\"", "rejects a metrics signal with no value");
  // body/value/attribute field sources must exist in records.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("logs",
                       R"("body":{"kind":"field","name":"nope","from":"","detail":""},)"))),
      "is not declared in record", "rejects a body naming a missing field");
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(("{\"name\":\"s\",\"signal\":\"logs\",\"record\":\"r\","
                  "\"span_name\":\"\",\"span_kind\":\"\",\"note\":\"\","
                  "\"timing\":{\"start\":\"x\",\"clock\":\"c\",\"end\":\"y\"},"
                  "\"drop_when\":{\"op\":\"never\"}," + bodyA +
                  "\"attributes\":[{\"key\":\"k\",\"stability\":\"spinel\","
                  "\"note\":\"\",\"source\":{\"kind\":\"field\",\"name\":\"nope\","
                  "\"from\":\"\",\"detail\":\"\"},\"presence\":{\"op\":\"always\"}}]}"))),
      "is not declared in record",
      "rejects an attribute source naming a missing field");
  // Kind-specific forbidden fields.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(("{\"name\":\"s\",\"signal\":\"traces\",\"record\":\"r\","
                  "\"span_name\":\"n\",\"span_kind\":\"INTERNAL\",\"note\":\"\","
                  "\"timing\":{\"start\":\"x\",\"clock\":\"c\",\"end\":\"y\"},"
                  "\"drop_when\":{\"op\":\"never\"}," + bodyA +
                  "\"attributes\":[]}"))),
      "do not apply to traces", "rejects a traces signal carrying a body");
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(("{\"name\":\"s\",\"signal\":\"metrics\",\"record\":\"r\","
                  "\"span_name\":\"oops\",\"span_kind\":\"\",\"note\":\"\","
                  "\"timing\":{\"start\":\"x\",\"clock\":\"c\",\"end\":\"y\"},"
                  "\"drop_when\":{\"op\":\"never\"}," + fieldA + sumM +
                  "\"attributes\":[]}"))),
      "only apply to traces", "rejects a metrics signal carrying a span_name");
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(("{\"name\":\"s\",\"signal\":\"traces\",\"record\":\"r\","
                  "\"span_name\":\"n\",\"span_kind\":\"\",\"note\":\"\","
                  "\"timing\":{\"start\":\"x\",\"clock\":\"c\",\"end\":\"y\"},"
                  "\"drop_when\":{\"op\":\"never\"},\"attributes\":[]}"))),
      "needs a span_kind", "rejects a traces signal with no span_kind");
  // Constant observations are Integer literals.
  expectReject(
      wrap(recordOf(okField), "", "",
           telOf(sigOf("metrics",
                       R"("value":{"kind":"constant","name":"one","from":"","detail":""},)" +
                           sumM))),
      "must be an integer literal",
      "rejects a non-integer constant metrics value");

  // runtime_extension requires detail, preserving unrepresentable content.
  expectReject(
      wrap(recordOf(okField), "", "",
           R"("signals":[{"name":"s","signal":"logs","record":"r","span_name":"","span_kind":"","note":"",
           "timing":{"start":"x","clock":"c","end":"y"},"drop_when":{"op":"never"},
           "attributes":[{"key":"k","stability":"spinel","note":"",
             "source":{"kind":"runtime_extension","name":"k","from":"","detail":""},
             "presence":{"op":"always"}}]}],
           "clocks":[{"id":"c","kernel_source":"k","posix_clock":"p","to_wall":"w","note":""}],
           "value_maps":[],"bounds_sets":[])"),
      "must carry \"detail\"",
      "rejects a runtime_extension source with no detail");

  // Coverage is required with no implicit default, preventing silent skipped checks.
  expectReject(R"({"version":1,"core":{"records":[],"maps":[],"programs":[]},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{}})",
               "\"coverage\" is required",
               "rejects a schema with no coverage (no implicit default)");
  expectReject(R"({"version":1,"coverage":{"programs":"partial","maps":"complete","records":"complete","telemetry":"complete"},
      "core":{"records":[],"maps":[],"programs":[]},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{}})",
               "there is no \"partial\"",
               "rejects coverage \"partial\" (its scope would be ambiguous)");
  expectReject(R"({"version":1,"coverage":{"programs":"complete","maps":"complete","records":"complete"},
      "core":{"records":[],"maps":[],"programs":[]},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{}})",
               "missing or non-string \"telemetry\"",
               "rejects a coverage missing one of the four");
  {
    auto omitted = Schema::parseJSON(R"({"version":1,
      "coverage":{"programs":"omitted","maps":"complete","records":"complete","telemetry":"complete"},
      "core":{"records":[],"maps":[],"programs":[]},
      "telemetry":{"signals":[],"clocks":[],"value_maps":[],"bounds_sets":[]},
      "extensions":{}})");
    ok(bool(omitted) && omitted->coverage().programs == Coverage::Omitted,
       "accepts coverage.programs = omitted (a partial schema)");
    if (!omitted)
      consumeError(omitted.takeError());
  }
  ok(first->coverage().programs == Coverage::Complete,
     "decodes fixture coverage");

  outs() << "\nschema-unittest: " << (checks - failures) << "/" << checks
         << " checks passed\n";
  return failures ? 1 : 0;
}
