#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/Path.h"
#include <algorithm>
#include <tuple>

namespace spinel::consumer {
inspection::Diagnostic Consumer::domainDiagnostic(Operation *node,
    StringRef verdict, StringRef code, StringRef name, StringRef message,
    std::optional<std::string> path) {
  inspection::Diagnostic d;
  d.verdict = verdict.str(); d.code = code.str();
  d.name = name.str(); d.message = message.str();
  if (node) if (auto loc = dyn_cast<FileLineColLoc>(node->getLoc()))
    d.pos = {llvm::sys::path::filename(loc.getFilename().getValue()).str(),
             loc.getLine(), loc.getColumn()};
  if (path && !path->empty()) {
    SmallVector<StringRef> parts;
    StringRef(*path).split(parts, " -> ");
    for (auto part : parts) d.path.push_back(part.str());
  }
  return d;
}
void Consumer::noteInspectionBody(Operation *node) {
  if (!inspectionOutput || inspectionGraphAvailable || !inspectionRootDefinition || !node) return;
  auto *def = inspectionRootDefinition;
  bool inBody = node == def;
  // Crossing the Def through its parameters does not establish body analysis.
  auto *body = ref(def,"body");
  llvm::DenseSet<Operation *> seen;
  for (auto *ancestor = node; !inBody && ancestor && ancestor != def &&
       seen.insert(ancestor).second; ancestor = parent(ancestor))
    if (ancestor == body) inBody = true;
  if (!inBody) return;
  inspectionGraphAvailable = true;
  snapshotDomainGraph();
}
void Consumer::snapshotDomainGraph(llvm::ArrayRef<Operation *> roots) {

  if (!inspectionOutput || !inspectionGraphAvailable) return;
  auto membership = userSideMembership(roots);
  if (failed(membership)) {
    input.emitError("inspection graph lacks the analyzed root source");
    blocking = true;
    return;
  }
  inspectionDomain.functions.clear();
  for (const auto &[name, sides] : membership->sides) {
    inspection::Function f; f.name = name;
    for (const auto *side : {"user", "bpf"})
      if (sides.count(side)) f.membership.emplace_back(side);
    inspectionDomain.functions.push_back(std::move(f));
  }
  inspectionDomain.edges = std::move(membership->edges);
  std::stable_sort(inspectionDomain.edges.begin(), inspectionDomain.edges.end(),
      [](const auto &a, const auto &b) {
        return std::tie(a.pos.line,a.pos.col) < std::tie(b.pos.line,b.pos.col);
      });
}
void Consumer::finishInspection(bool success) {
  if (!inspectionOutput) return;
  for (auto source : input.getOps<ir::SourceOp>())
    if (source->getAttrOfType<IntegerAttr>("file_id").getInt() == 0)
      inspectionDomain.source = llvm::sys::path::filename(text(source,"path")).str();
  if (inspectionDomain.source.empty()) return;
  if (!success) inspectionDomain.roots.clear();
  auto &ds = inspectionDomain.diagnostics;
  const bool dynamic = llvm::any_of(ds, [](const auto &d) { return d.code == "SB016"; });
  const bool other = llvm::any_of(ds, [](const auto &d) {
    return d.verdict != "conditional" && d.code != "SB010";
  });
  std::set<std::tuple<std::string,unsigned,unsigned,std::string>> seen;
  ds.erase(std::remove_if(ds.begin(),ds.end(),[&](const auto &d) {
    if (d.verdict == "conditional") return false;
    if ((dynamic && d.code == "SB009") || (other && d.code == "SB010")) return true;
    return !seen.emplace(d.pos.file,d.pos.line,d.pos.col,d.code).second;
  }),ds.end());
  std::stable_sort(ds.begin(),ds.end(),[](const auto &a, const auto &b) {
    return std::tie(a.pos.file,a.pos.line,a.pos.col,a.code) <
           std::tie(b.pos.file,b.pos.line,b.pos.col,b.code);
  });
  inspectionOutput->domain = inspection::writeDomain(inspectionDomain);
  inspectionOutput->domainProduced = true;
}
} // namespace spinel::consumer
