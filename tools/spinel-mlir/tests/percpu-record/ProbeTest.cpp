#include "spinel/Conversion/RecordValue.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace spinel::consumer;
namespace spinel::consumer { void registerRecordMembers(Registry &); }
static void require(bool ok, const char *message) {
  if (!ok) { llvm::errs() << "FAIL " << message << "\n"; std::exit(1); }
}
int main(int argc, char **argv) {
  require(argc == 2, "facts path");
  MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto input = parseSourceFile<ModuleOp>(argv[1], &context);
  require(bool(input), "real width facts parse");
  Consumer c(*input);
  c.useIsolatedRegistryForTesting();
  registerRecordMembers(c.registry);
  c.registry.addRMWExemption([](const Consumer &c, const ReadOrigin &r, size_t m) {
    return r.domain == ReadOrigin::Domain::Map && m < c.maps.size() &&
        c.maps[m].kind == "percpu_array" && c.activeKind == "xdp";
  });
  auto layout = std::make_shared<spinel::record::Layout>();
  layout->name = "S";
  for (const auto &item : std::vector<std::pair<std::string, unsigned>>{
           {"n64", 64}, {"n32", 32}, {"n8", 8}}) {
    spinel::record::FieldLayout f;
    f.name = item.first; f.bits = item.second;
    f.type = "u" + std::to_string(item.second);
    layout->fields.push_back(f);
  }
  RecordDecl record; record.name = "S"; record.recordLayout = layout;
  c.records.push_back(record);
  MapDecl map; map.name = "M"; map.kind = "percpu_array";
  map.valueRecord = "S"; c.maps.push_back(map);
  c.borrows["p"] = {0, 0, {}};
  c.activeKind = "xdp";
  c.probing = true;
  std::string before;
  llvm::raw_string_ostream beforeStream(before); input->print(beforeStream);
  unsigned checked = 0;
  for (const auto &entry : c.nodes) {
    auto node = entry.second;
    if (text(node, "kind") != "CallOperatorWriteNode") continue;
    Operation *one[] = {node};
    auto result = c.dispatchStatement("CallOperatorWriteNode", one, 0, 0);
    require(result.state == Disposition::Handled && result.value->consumed == 1,
            "per-CPU operator Probe handled once");
    ++checked;
  }
  std::string after;
  llvm::raw_string_ostream afterStream(after); input->print(afterStream);
  require(checked == 4, "four real width operators checked");
  require(before == after && !c.maps[0].used && !c.records[0].used &&
              c.locals.empty() && c.borrows.size() == 1 &&
              !c.borrows.at("p").value && c.probeIssues.empty(),
          "Probe leaves IR, flags, locals and borrow unchanged");
  llvm::outs() << "GREEN four operators; Probe no IR/state publication\n";
}
