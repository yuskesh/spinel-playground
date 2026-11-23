// E021: the common json export — a global declared but unused leaves no
// "globals" key (schema and maps.json), a used one follows "programs" in the
// schema core, and an ExportValue writer keeps its own (Go struct) key order.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace spinel::consumer;
using namespace mlir;
static void require(bool ok, const char *name) {
  if (!ok) {
    llvm::errs() << "FAIL " << name << "\n";
    std::exit(1);
  }
}
static size_t at(const std::string &text, const char *needle) {
  return text.find(needle);
}
int main(int argc, char **argv) {
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = ModuleOp::create(UnknownLoc::get(&context));
  Consumer consumer(module);
  consumer.useIsolatedRegistryForTesting();
  consumer.registry.addGlobalExporter(
      [](Consumer &c, size_t index, bool schema) {
        ExportFields fields;
        fields.emplace_back("name", c.globals[index].name);
        if (schema)
          fields.emplace_back("section", c.globals[index].section);
        return Dispatch<ExportFields>::handled(std::move(fields));
      });
  GlobalDecl unused;
  unused.name = "Unused";
  unused.section = "bss";
  consumer.globals.push_back(unused);
  ProgramDecl program;
  program.name = "prog";
  consumer.programs.push_back(program);
  auto schema = consumer.json(true), maps = consumer.json(false);
  require(at(schema, "\"globals\"") == std::string::npos,
          "unused global leaves no schema globals key");
  require(at(maps, "\"globals\"") == std::string::npos,
          "unused global leaves no maps.json globals key");

  consumer.globals.front().used = true;
  schema = consumer.json(true);
  maps = consumer.json(false);
  require(at(schema, "\"globals\"") != std::string::npos &&
              at(schema, "\"programs\"") < at(schema, "\"globals\""),
          "used global follows programs in the schema core");
  require(at(maps, "\"globals\"") != std::string::npos &&
              at(maps, "\"maps\"") < at(maps, "\"globals\""),
          "used global follows maps in maps.json");

  auto order = std::make_shared<const std::vector<std::string>>(
      std::vector<std::string>{"kind", "bits", "signed", "endianness",
                               "alignment"});
  consumer.registry.addMapExporter(
      "ordered", [order](Consumer &, size_t, bool) {
        ExportFields fields;
        fields.emplace_back("symbol", "M");
        fields.emplace_back("key", ExportValue::write([order](llvm::json::OStream &j) {
          j.object([&] {
            for (auto &name : *order)
              j.attribute(name, name);
          });
        }));
        fields.emplace_back("max_entries", 4);
        return Dispatch<ExportFields>::handled(std::move(fields));
      });
  MapDecl map;
  map.name = "M";
  map.kind = "ordered";
  map.used = true;
  consumer.maps.push_back(map);
  schema = consumer.json(true);
  auto k = at(schema, "\"kind\": \"kind\""), b = at(schema, "\"bits\": \"bits\""),
       s = at(schema, "\"signed\": \"signed\""),
       e = at(schema, "\"endianness\": \"endianness\""),
       a = at(schema, "\"alignment\": \"alignment\"");
  require(k != std::string::npos && k < b && b < s && s < e && e < a,
          "writer keeps its own key order (not sorted)");
  require(at(schema, "\"symbol\": \"M\"") < at(schema, "\"key\": {") &&
              at(schema, "\"key\": {") < at(schema, "\"max_entries\": 4"),
          "primitive and writer fields keep their order");
  require(!consumer.blocking, "no export error");

  // E022: a handled program export is the whole object in its own order;
  // kernel_types comes first in core and is omitted when declined; maps.json
  // records are keyed by name in byte order and omitted when none is used.
  consumer.registry.addProgramExporter("kprobe", [](Consumer &c, size_t i,
                                                    bool) {
    ExportFields fields;
    fields.emplace_back("name", c.programs[i].name);
    fields.emplace_back("kind", "kprobe");
    fields.emplace_back("attach_target", "do_sys_poll");
    fields.emplace_back("maps", llvm::json::Array{});
    fields.emplace_back("arch", "x86_64");
    fields.emplace_back("note", "Ruby def " + c.programs[i].name);
    return Dispatch<ExportFields>::handled(std::move(fields));
  });
  ProgramDecl traced;
  traced.name = "trace";
  traced.kind = "kprobe";
  consumer.programs.push_back(traced);
  schema = consumer.json(true);
  // Search forward from the traced program (the declined one also has maps).
  auto tn = at(schema, "\"name\": \"trace\"");
  auto ta = schema.find("\"attach_target\": \"do_sys_poll\"", tn),
       tm = schema.find("\"maps\": []", tn),
       tr = schema.find("\"arch\": \"x86_64\"", tn),
       tt = schema.find("\"note\": \"Ruby def trace\"", tn);
  require(tn != std::string::npos && tn < ta && ta < tm && tm < tr && tr < tt,
          "program exporter writes its fields in its order");
  require(at(schema, "\"name\": \"prog\"") != std::string::npos &&
              at(schema, "\"note\": \"Ruby def prog\"") != std::string::npos,
          "declined program keeps the common fields");
  require(at(schema, "\"kernel_types\"") == std::string::npos,
          "no kernel_types without an exporter");

  require(consumer.registry.addCoreExporter(
              "kernel_types", [](Consumer &, bool schema) {
                if (!schema)
                  return Dispatch<ExportValue>::declined();
                return Dispatch<ExportValue>::handled(
                    ExportValue::write([](llvm::json::OStream &j) {
                      j.array([&] { j.value("task_struct"); });
                    }));
              }),
          "kernel_types core exporter accepted");
  schema = consumer.json(true);
  maps = consumer.json(false);
  // "records" also names a coverage field before core; search inside core.
  auto core = at(schema, "\"core\"");
  require(core != std::string::npos &&
              schema.find("\"kernel_types\"", core) != std::string::npos &&
              schema.find("\"kernel_types\"", core) <
                  schema.find("\"records\"", core),
          "kernel_types precedes records in core");
  require(at(maps, "\"kernel_types\"") == std::string::npos &&
              at(maps, "\"programs\"") == std::string::npos,
          "maps.json has no kernel_types or programs");
  {
    Registry other;
    require(!other.addCoreExporter("records",
                                   [](Consumer &, bool) {
                                     return Dispatch<ExportValue>::declined();
                                   }) &&
                !other.valid,
            "unknown core key invalidates the registry");
  }

  require(at(maps, "\"records\"") == std::string::npos,
          "no used record leaves no maps.json records key");
  consumer.registry.addRecordExporter([](Consumer &c, size_t i, bool schema) {
    ExportFields fields;
    if (schema)
      fields.emplace_back("symbol", c.records[i].name);
    else
      fields.emplace_back("size", 8);
    return Dispatch<ExportFields>::handled(std::move(fields));
  });
  // E029: the used records come from used maps and rings (usedRecordOrder),
  // not from RecordDecl::used — each record is a used map's value record, in
  // an order that differs from the name bytes.
  for (auto name : {"zeta", "Alpha", "beta"}) {
    RecordDecl record;
    record.name = name;
    consumer.records.push_back(record);
    MapDecl map;
    map.name = std::string("M_") + name;
    map.used = true;
    map.valueRecord = name;
    consumer.maps.push_back(map);
  }
  maps = consumer.json(false);
  auto ra = at(maps, "\"Alpha\""), rb = at(maps, "\"beta\""),
       rz = at(maps, "\"zeta\""), rm = at(maps, "\"maps\"");
  require(at(maps, "\"records\"") < ra && ra < rb && rb < rz && rz < rm,
          "maps.json records sorted by name bytes, before maps");
  require(!consumer.blocking, "no export error after E022 cases");

  if (argc == 2) {
    // The facts are an XDP program, whose ebpf.program verifier refuses an
    // `arch`: the refusal is the observation that ProgramDecl::arch reached
    // the op, and the same root without arch is the control.
    auto runWith = [&](std::string arch, std::string &diagnostics) {
      auto input = parseSourceFile<ModuleOp>(argv[1], &context);
      require(bool(input), "parse real producer facts");
      Consumer real(*input);
      real.useIsolatedRegistryForTesting();
      real.registry.addRoot("xdp", [arch](Consumer &, Operation *) {
        ProgramDecl decl;
        decl.arch = arch;
        return Dispatch<ProgramDecl>::handled(std::move(decl));
      });
      ScopedDiagnosticHandler capture(&context, [&](Diagnostic &d) {
        diagnostics += d.str();
        return success();
      });
      return succeeded(real.run());
    };
    std::string withArch, withoutArch;
    require(!runWith("x86_64", withArch) &&
                withArch.find("`arch` is only for kprobe") != std::string::npos,
            "ProgramDecl arch reaches the program op (verifier refuses it on xdp)");
    require(runWith("", withoutArch) && withoutArch.empty(),
            "empty arch leaves no program arch attribute");
  }
  llvm::outs() << "E021/E022 export: unused global omitted, globals after "
                  "programs, writer order kept, program/core/records order\n";
  return 0;
}
