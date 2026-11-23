#include "spinel/Conversion/Consumer.h"
#include "spinel/Analysis/RecordLayout.h"

namespace spinel::consumer {
namespace {
std::string shape(const record::Layout &layout) {
  std::string out = layout.name + "|size=" + std::to_string(layout.size) + ";";
  for (const auto &f : layout.fields) {
    int64_t count = f.count.value_or(1);
    for (int64_t i = 0; i < count; ++i) {
      auto name = f.count ? f.name + "[" + std::to_string(i) + "]" : f.name;
      out += name + ":" + std::to_string(f.offset+i*f.bits/8) + ":" + f.type + ";";
    }
  }
  return out;
}
}
std::string Consumer::exportRecords() {
  std::string out;
  auto row = [&](const std::string &name, const std::string &record) {
    if (record.empty()) return;
    for (const auto &r : records)
      if (r.name == record && r.recordLayout) {
        out += name + "|" + shape(*r.recordLayout) + "\n";
        return;
      }
    (void)error(nullptr,"inspection records export is missing a checked layout");
  };
  for (const auto &m : maps) if (m.used) {
    row(m.name+":key",m.keyRecord);
    row(m.name,m.valueRecord);
  }
  for (const auto &r : rings) if (r.used) {
    if (!r.layout) { (void)error(r.node,"inspection ring lacks a checked layout"); continue; }
    out += r.name + "|" + shape(*r.layout) + "\n";
  }
  for (const auto &g : globals) if (g.used)
    out += "G|"+g.name+"|"+g.section+"|"+(g.isSigned ? "i" : "u")+
           std::to_string(g.bits)+"|"+(g.className=="OptionalConfig" ? "1" : "0")+"\n";
  return out;
}
std::vector<UprobeTarget> Consumer::exportUprobeTargets() {
  std::vector<UprobeTarget> out;
  for (const auto &p : programs) {
    if (p.kind != "uprobe" && p.kind != "uretprobe") continue;
    if (p.binaryPath.empty()) {
      (void)error(p.entry,"inspection uprobe target has no resolved binary path");
      continue;
    }
    auto decl = domainDiagnostic(p.entry,"","","","").pos;
    out.push_back({p.name,p.kind,p.binaryPath,decl.file,decl.line,decl.col});
  }
  return out;
}
} // namespace spinel::consumer
