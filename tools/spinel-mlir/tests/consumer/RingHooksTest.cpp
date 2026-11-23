#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "spinel/Conversion/Consumer.h"
#include <cstdio>
using namespace spinel::consumer;
int main() {
  mlir::MLIRContext context;
  context.loadDialect<spinel::ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      mlir::arith::ArithDialect>();
  auto module = mlir::ModuleOp::create(mlir::UnknownLoc::get(&context));
  Consumer c(module);
  c.useIsolatedRegistryForTesting();
  for (auto name : {"Value", "Key", "Unused", "Other"}) {
    RecordDecl record;
    record.name = name;
    record.used = std::string(name) == "Unused";
    c.records.push_back(record);
  }
  MapDecl first;
  first.used = true;
  first.keyRecord = "Key";
  first.valueRecord = "Value";
  c.maps.push_back(first);
  MapDecl ignored;
  ignored.valueRecord = "Unused";
  c.maps.push_back(ignored);
  MapDecl second;
  second.used = true;
  second.keyRecord = "Value";
  second.valueRecord = "Other";
  c.maps.push_back(second);
  if (c.usedRecordOrder() != std::vector<size_t>{1, 0, 3}) {
    std::fprintf(stderr, "FAIL used record map/key/value order and dedup\n");
    return 1;
  }
  c.records.front().used = true;
  if (c.usedRecordOrder() != std::vector<size_t>{1, 0, 3}) {
    std::fprintf(stderr, "FAIL used record order depends on record used bit\n");
    return 1;
  }
  c.registry.addDeclaration({"", ""}, [](Consumer &c, mlir::Operation *node) {
    RingDecl ring;
    ring.constant = ring.name = "Events";
    ring.size = 4096;
    ring.node = node;
    c.rings.push_back(std::move(ring));
    return Dispatch<bool>::handled(true);
  });
  auto declaration = c.dispatchDeclaration(module);
  if (declaration.state != Disposition::Handled || c.rings.size() != 1 ||
      c.declarationOrder.size() != 1 ||
      c.declarationOrder.front().domain != DeclarationRef::Domain::Ring) {
    std::fprintf(stderr, "FAIL ring append/domain\n"); return 1;
  }
  {
    ScopeGuard guard(c);
    c.rings.front().used = true;
  }
  if (c.rings.front().used) {
    std::fprintf(stderr, "FAIL ring used rollback\n"); return 1;
  }
  {
    ScopeGuard guard(c);
    c.rings.front().used = true;
    guard.commit();
  }
  if (!c.rings.front().used) {
    std::fprintf(stderr, "FAIL ring used commit\n"); return 1;
  }
  unsigned calls = 0;
  c.registry.addRingExporter([&calls](Consumer &c, size_t i, bool schema) {
    ++calls;
    ExportFields fields;
    fields.emplace_back(schema ? "symbol" : "name", c.rings.at(i).name);
    return Dispatch<ExportFields>::handled(std::move(fields));
  });
  for (bool schema : {false, true}) {
    auto result = c.dispatchExport({DeclarationRef::Domain::Ring, 0}, schema);
    if (result.state != Disposition::Handled || result.value->size() != 1) {
      std::fprintf(stderr, "FAIL ring export dispatch\n"); return 1;
    }
  }
  if (calls != 2 ||
      c.dispatchExport({DeclarationRef::Domain::Ring, 1}, true).state !=
          Disposition::Error || !c.blocking) {
    std::fprintf(stderr, "FAIL ring invalid-index fail closed\n"); return 1;
  }
  return 0;
}
