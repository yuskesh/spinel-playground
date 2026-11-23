#include "spinel/Conversion/RecordValue.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace spinel::consumer;
static void require(bool ok, const char *name) {
  if (!ok) { llvm::errs() << "FAIL " << name << "\n"; std::exit(1); }
}
static std::string exportText(Consumer &c, DeclarationRef declaration, bool schema) {
  auto fields = c.dispatchExport(declaration, schema);
  require(fields.state == Disposition::Handled, "record export dispatched");
  std::string text;
  llvm::raw_string_ostream stream(text);
  llvm::json::OStream json(stream);
  json.object([&] {
    for (auto &field : *fields.value) {
      json.attributeBegin(field.first);
      if (field.second.writer) field.second.writer(json);
      else json.value(*field.second.primitive);
      json.attributeEnd();
    }
  });
  return text;
}
int main(int argc, char **argv) {
  require(argc == 3, "facts path and fixture kind required");
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto input = parseSourceFile<ModuleOp>(argv[1], &context);
  require(bool(input), "real facts parse");
  Consumer c(*input);
  const std::vector<std::string> mapClasses = {"RecordMap", "PerCpuRecordMap",
      "RecordHashMap", "LruRecordHashMap", "PerCpuRecordHashMap"};
  for (const auto &name : mapClasses) {
    unsigned registrations = 0;
    for (const auto &registration : c.registry.declarations)
      if (registration.first.receiver == "BPF::" + name &&
          registration.first.method == "new") ++registrations;
    require(registrations == 1, "each record map class registered exactly once");
  }
  Operation *root = nullptr;
  for (auto table : input->getOps<spinel::ir::TableOp>())
    if (text(table, "phase") == "pristine")
      root = c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  require(root, "pristine root");
  auto top = c.array(c.ref(root, "statements"), "body");
  IntegerAttr rootFile;
  for (auto op : top)
    if (text(op, "kind") == "CallNode" &&
        c.constant(c.ref(op, "receiver")) == "BPF" &&
        field(op, "strings", "name") == "xdp")
      rootFile = op->getAttrOfType<IntegerAttr>("file_id");
  require(bool(rootFile), "root file");
  for (auto op : top)
    if (op->getAttrOfType<IntegerAttr>("file_id") == rootFile)
      c.selectedTop.push_back(op);
  unsigned declarations = 0;
  for (auto op : c.selectedTop) {
    auto call = text(op, "kind") == "ConstantWriteNode" ? c.ref(op, "value") : op;
    auto receiver = c.constant(c.ref(call, "receiver"));
    auto method = field(call, "strings", "name");
    if (!((receiver == "Struct" && method == "new") ||
          (receiver == "BPF" && method == "record"))) continue;
    require(c.dispatchDeclaration(op).state == Disposition::Handled,
            "real record declaration handled");
    ++declarations;
  }
  require(c.badRecords.empty(), "no failed positive record declaration");
  if (StringRef(argv[2]) == "basic") {
    auto stat = lookupRecordLayout(c, "Stat"), pair = lookupRecordLayout(c, "Pair");
    require(declarations == 4 && c.records.size() == 2 && stat && pair,
            "real Stat/Pair declaration count");
    require(stat->size == 24 && stat->alignment == 8 &&
        stat->fields.size() == 5 && stat->fields[2].offset == 16 &&
        stat->fields[3].padding && stat->fields[4].offset == 20 &&
        stat->fields[4].isSigned && pair->size == 4,
        "real E003 Stat/Pair layout");
    unsigned mapDeclarations = 0;
    for (auto op : c.selectedTop) {
      auto call = c.ref(op, "value");
      if (c.constant(c.ref(call, "receiver")) != "BPF::RecordMap") continue;
      require(c.dispatchDeclaration(op).state == Disposition::Handled,
              "real RecordMap declaration handled");
      ++mapDeclarations;
    }
    require(mapDeclarations == 2 && c.maps.size() == 2 &&
        c.maps[0].valueRecord == "Stat" && c.maps[1].valueRecord == "Pair" &&
        c.maps[0].entries == 4 && c.maps[1].entries == 2 &&
        isa<ebpf::RecordType>(c.maps[0].valueType),
        "real RecordMap names/entries/nominal type");
    c.maps[0].used = c.maps[1].used = true;
    require(c.usedRecordOrder() == std::vector<size_t>{0, 1},
            "real RecordMap record id order");
    require(exportText(c, {DeclarationRef::Domain::Map, 0}, true) ==
        R"({"symbol":"Stats","kind":"array","key":{"kind":"int","bits":32,"signed":false,"endianness":"little","alignment":4},"value":{"kind":"record_ref","symbol":"Stat"},"max_entries":4,"flags":0,"record":"","note":"Ruby constant Stats"})",
        "real record map schema exact key order and nominal value");
    require(exportText(c, {DeclarationRef::Domain::Map, 0}, false) ==
        R"({"name":"Stats","kind":"array","key":"u32","value":"record:Stat","max_entries":4})",
        "real record map maps.json exact fields");
    auto recordJson = exportText(c, {DeclarationRef::Domain::Record, 1}, true);
    require(StringRef(recordJson).starts_with(R"({"symbol":"Pair","id":1,)"),
        "real record exporter id uses map order");
    Operation *read = nullptr, *store = nullptr, *atomic = nullptr;
    for (const auto &entry : c.nodes) {
      auto op = entry.second;
      if (text(op, "kind") != "CallNode") continue;
      auto receiver = c.ref(op, "receiver");
      if (text(receiver, "kind") == "CallNode" &&
          field(receiver, "strings", "name") == "load" &&
          field(c.ref(receiver, "receiver"), "strings", "name") == "p") {
        if (field(op, "strings", "name") == "flags") read = op;
        if (field(op, "strings", "name") == "flags=") store = op;
      }
      if (field(receiver, "strings", "name") == "p" &&
          field(op, "strings", "name") == "atomic_add") {
        auto args = c.args(op);
        if (args.size() == 2 && c.spelling(args[0], true) == "hits") atomic = op;
      }
    }
    require(read && store && atomic, "real fixed member nodes");
    auto output = ModuleOp::create(UnknownLoc::get(&context));
    auto borrowed = output.getBody()->addArgument(
        ebpf::BorrowedType::get(&context, c.maps[0].valueType), UnknownLoc::get(&context));
    c.borrows["p"] = {0, 0, borrowed};
    c.builder.setInsertionPointToEnd(output.getBody());
    auto value = c.scalar(read);
    require(succeeded(value) && (*value)->reads.size() == 1 &&
        (*value)->reads.front().ref == "p", "real member check retains read origin");
    Value emitted = c.emitScalar(*value);
    require(emitted && emitted.getType().isInteger(64) &&
        emitted.getDefiningOp<arith::ExtSIOp>(), "real signed i32 field load widens to i64");
    c.records[0].used = false;
    require(succeeded(c.scalarStatements({store})) && c.records[0].used &&
        !output.getOps<ebpf::RefFieldStoreOp>().empty(), "real fixed member store marks record used");
    c.records[0].used = false;
    require(succeeded(c.scalarStatements({atomic})) &&
        c.records[0].used && !output.getOps<ebpf::RefFieldAtomicAddOp>().empty(), "real fixed member atomic marks record used");
  } else {
    auto ev = lookupRecordLayout(c, "Ev");
    require(declarations == 2 && c.records.size() == 1 && ev &&
        ev->size == 8 && ev->fields.size() == 1, "real Ev declaration/layout");
    Operation *make = nullptr;
    for (const auto &entry : c.nodes) {
      auto op = entry.second;
      if (text(op, "kind") != "CallNode" || c.constant(c.ref(op, "receiver")) != "Ev" ||
          field(op, "strings", "name") != "new") continue;
      auto args = c.args(op);
      if (args.size() == 1 && text(args[0], "literal_decimal") == "1") make = op;
    }
    require(make, "real ring output constructor");
    auto checked = checkRecordMake(c, make, ev,
        {"Events", RecordDestination::Kind::Ring, ""});
    require(succeeded(checked), "real Ev.new value check");
    auto output = ModuleOp::create(UnknownLoc::get(&context));
    c.builder.setInsertionPointToEnd(output.getBody());
    require(succeeded(emitRecordMake(c, **checked)), "real Ev.new emit");
  }
  llvm::outs() << "real record declarations/value: " << argv[2] << " OK\n";
}
