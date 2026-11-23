// SB003 (CrossDomainUse) on the user side of the program: Go's membership and
// checkUserSideAPI (spinel-bpf-mlir v0.6.0 internal/frontend/analyze.go
// :647-654, :1186-1281). The callee tables are the strings of that file's
// ebpfOnlyHelpers and libCallees (:16-101), copied verbatim.
#include "spinel/Conversion/Consumer.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringSet.h"
#include <algorithm>

namespace spinel::consumer {
namespace {
const char *const kEBPFOnlyCallees[] = {
    "BPF.pid_tgid",
    "RingBuf#output_argv",
    "KsyscallCtx#argv_arg",
    "TracepointCtx#argv_field",
    "BPF.fmod_return",
    "FmodRetCtx#arg",
    "BPF.ktime_ns",
    "XdpMd#check",
    "SkBuff#check",
    "Window#u8",
    "Window#be16",
    "Window#be32",
    "Window#le16",
    "Window#le32",
    "ArrayMap#atomic_add",
    "ArrayMap#lookup",
    "ArrayMap#update",
    "MapRef#load",
    "RecordMap#lookup",
    "RecordMap#update",
    "RecordRef#load",
    "RecordRef#atomic_add",
    "RingBuf#output",
    "MapRef#atomic_add",
    "PerCpuArrayMap#lookup",
    "PerCpuArrayMap#update",
    "PerCpuArrayMap#atomic_add",
    "PerCpuRecordMap#lookup",
    "PerCpuRecordMap#update",
    "PerCpuHashMap#lookup",
    "PerCpuHashMap#update",
    "PerCpuHashMap#insert",
    "PerCpuHashMap#replace",
    "PerCpuHashMap#delete",
    "PerCpuHashMap#add_or_init",
    "PerCpuRecordHashMap#lookup",
    "PerCpuRecordHashMap#update",
    "PerCpuRecordHashMap#insert",
    "PerCpuRecordHashMap#replace",
    "PerCpuRecordHashMap#delete",
    "HashMap#lookup",
    "HashMap#update",
    "HashMap#insert",
    "HashMap#replace",
    "HashMap#delete",
    "HashMap#add_or_init",
    "LruHashMap#lookup",
    "LruHashMap#update",
    "LruHashMap#insert",
    "LruHashMap#replace",
    "LruHashMap#delete",
    "LruHashMap#add_or_init",
    "RecordHashMap#lookup",
    "RecordHashMap#update",
    "RecordHashMap#insert",
    "RecordHashMap#replace",
    "RecordHashMap#delete",
    "LruRecordHashMap#lookup",
    "LruRecordHashMap#update",
    "LruRecordHashMap#insert",
    "LruRecordHashMap#replace",
    "LruRecordHashMap#delete",
    "LpmTrieMap#lookup",
    "FexitCtx#ret",
    "KretprobeCtx#ret",
    "UretprobeCtx#ret",
    "SocketFilterCtx#len",
    "CgroupSkb#len",
    "CgroupSkb#check",
    "NfCtx#state",
    "NfCtx#skb",
    "FlowCtx#check",
    "FlowCtx#key",
    "FlowCtx#set_key",
    "XdpMd#ingress_ifindex",
    "SkBuff#len",
    "SkBuff#mark",
    "SkBuff#mark=",
    "XdpMd#adjust_head",
    "XdpMd#adjust_tail",
    "Config#value",
    "OptionalConfig#value",
    "Counter#value",
    "Counter#add",
    "KprobeCtx#arg",
    "FentryCtx#arg",
    "DevMap#redirect",
    "SockMap#assign",
    "SkLookupCtx#local_port",
    "KprobeCtx#read",
    "RawTpCtx#arg",
    "KsyscallCtx#arg",
    "KsyscallCtx#str_arg",
    "TracepointCtx#field",
    "TracepointCtx#str_field",
    "TracepointCtx#copy",
    "UprobeCtx#arg",
    "UprobeCtx#str_arg",
    "UprobeCtx#buf_arg",
    "RingBuf#output_buf",
    "RingBuf#output_str",
    "OutputStr#status",
    "RingBuf#output_str_or_discard",
    "OutputStr#sent",
    "TpBtfCtx#kptr",
    "TpBtfCtx#kptr_or_null",
    "FentryCtx#kptr_or_null",
    "TpBtfCtx#arg",
    "KPtr#load",
    "KPtr#addr",
    "KPtr#ptr",
    "KPtr#copy",
    "KPtr#str",
};

const llvm::StringSet<> &ebpfOnlyCallees() {
  static const llvm::StringSet<> set = [] {
    llvm::StringSet<> s;
    for (auto *name : kEBPFOnlyCallees)
      s.insert(name);
    return s;
  }();
  return set;
}
} // namespace

FailureOr<Consumer::UserSideMembership> Consumer::userSideMembership(llvm::ArrayRef<Operation *> inspectionRoots) {
  // A caller may provide an inspection-only view. No run-owned roots change.
  auto roots = inspectionRoots.empty() ? llvm::ArrayRef<Operation *>(rootEntries) : inspectionRoots;
  UserSideMembership out;
  Operation *root = nullptr;
  for (auto table : input.getOps<ir::TableOp>())
    if (text(table, "phase") == "analyzed")
      root = analyzed.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  if (!root || roots.empty())
    return failure();
  auto fileAttr = roots.front()->getAttrOfType<IntegerAttr>("file_id");
  if (!fileAttr)
    return failure();
  auto refOf = [&](Operation *node, StringRef key) -> Operation * {
    auto d = node ? node->getAttrOfType<DictionaryAttr>("refs") : DictionaryAttr();
    auto v = d ? d.getAs<IntegerAttr>(key) : IntegerAttr();
    return v && v.getInt() >= 0 ? analyzed.lookup(v.getInt()) : nullptr;
  };
  auto statements = refOf(root, "statements");
  auto d = statements ? statements->getAttrOfType<DictionaryAttr>("arrays") : DictionaryAttr();
  auto body = d ? d.getAs<ArrayAttr>("body") : ArrayAttr();
  if (!body)
    return failure();
  std::set<Operation *> sourceDefs;
  if (inspectionOutput) {
    // Same ID selects a candidate; scope and full node identity prove it.
    // An analyzed-only flattened clone has no pristine top-level witness.
    Operation *pristineRoot = nullptr;
    for (auto table : input.getOps<ir::TableOp>())
      if (text(table,"phase") == "pristine")
        pristineRoot = nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
    auto savedFailure = equivalenceFailure;
    for (auto original : array(ref(pristineRoot,"statements"),"body")) {
      if (!original || text(original,"kind") != "DefNode" || ref(original,"receiver") ||
          original->getAttrOfType<IntegerAttr>("file_id") != fileAttr) continue;
      auto *candidate = analyzed.lookup(id(original));
      if (candidate && equivalentNode(original,candidate)) sourceDefs.insert(candidate);
    }
    equivalenceFailure = std::move(savedFailure);
  }
  for (auto x : body) {
    auto node = analyzed.lookup(cast<IntegerAttr>(x).getInt());
    if (!node || node->getAttrOfType<IntegerAttr>("file_id") != fileAttr)
      continue;
    out.topStatements.push_back(node);
    if (text(node, "kind") == "DefNode" && !refOf(node, "receiver") &&
        (!inspectionOutput || sourceDefs.count(node)))
      out.defs.emplace(field(node, "strings", "name").str(), node);
  }
  // Calls in n (not entering a nested def) whose single codegen callee is a
  // top-level def of the root file.
  auto callees = [&](Operation *n) {
    std::vector<inspection::Edge> found;
    llvm::DenseSet<Operation *> seen;
    auto walk = [&](auto &&self, Operation *c) -> void {
      if (!c || !seen.insert(c).second)
        return;
      if (text(c, "kind") == "DefNode" && c != n)
        return;
      if (text(c, "kind") == "CallNode" &&
          c->getAttrOfType<IntegerAttr>("file_id") == fileAttr) {
        auto &ev = evidence[id(c)];
        if (ev.size() == 1) {
          auto callee = text(ev.front(), "callee");
          if (!callee.empty() && out.defs.count(callee.str()))
            found.push_back({"", callee.str(),
              domainDiagnostic(c,"","","","").pos, text(ev.front(),"dispatch").str()});
        }
      }
      if (inspectionOutput) {
        // Go analyze.go walk sorts the R/A field names together.
        std::map<std::string, SmallVector<Operation *>> children;
        for (auto attr : c->getAttrOfType<DictionaryAttr>("refs")) {
          auto v = cast<IntegerAttr>(attr.getValue()).getInt();
          if (v >= 0) children["R"+attr.getName().str()].push_back(analyzed.lookup(v));
        }
        for (auto attr : c->getAttrOfType<DictionaryAttr>("arrays"))
          for (auto v : cast<ArrayAttr>(attr.getValue()))
            children["A"+attr.getName().str()].push_back(analyzed.lookup(cast<IntegerAttr>(v).getInt()));
        for (const auto &[key, values] : children)
          for (auto child : values) self(self,child);
      } else {
        for (auto attr : c->getAttrOfType<DictionaryAttr>("refs")) {
          auto v = cast<IntegerAttr>(attr.getValue()).getInt();
          if (v >= 0)
            self(self, analyzed.lookup(v));
        }
        for (auto attr : c->getAttrOfType<DictionaryAttr>("arrays"))
          for (auto v : cast<ArrayAttr>(attr.getValue()))
            self(self, analyzed.lookup(cast<IntegerAttr>(v).getInt()));
      }
    };
    walk(walk, n);
    return found;
  };
  auto visit = [&](auto &&self, const std::string &name, StringRef side) -> void {
    if (!out.sides[name].insert(side.str()).second)
      return;
    for (auto &next : callees(out.defs.at(name))) {
      if (inspectionOutput) { auto edge = next; edge.from = name; out.edges.push_back(std::move(edge)); }
      self(self, next.to, side);
    }
  };
  for (auto rootEntry : roots) {
    auto arguments = args(rootEntry);
    if (arguments.empty() || text(arguments.front(), "kind") != "SymbolNode")
      continue;
    auto name = spelling(arguments.front(), true).str();
    if (out.defs.count(name))
      visit(visit, name, "bpf");
  }
  for (auto node : out.topStatements)
    if (text(node, "kind") != "DefNode")
      for (auto &next : callees(node)) {
        if (inspectionOutput) { auto edge = next; edge.from = "<top>"; out.edges.push_back(std::move(edge)); }
        visit(visit, next.to, "user");
      }
  return out;
}

FailureOr<std::vector<Consumer::PendingDiagnostic>>
Consumer::userSideFindings() {
  // Semantic SB003 keeps its established census even when a caller requests
  // an inspection graph; the stricter source witness belongs to I only.
  auto *inspection = inspectionOutput;
  inspectionOutput = nullptr;
  auto membership = userSideMembership();
  inspectionOutput = inspection;

  if (failed(membership))
    return (void)error(nullptr, "user-side check found no analyzed root file"),
           failure();
  struct Finding {
    unsigned line = 0, col = 0;
    Operation *node = nullptr;
    std::string message;
    std::vector<std::string> path;
  };
  std::vector<Finding> findings;
  auto position = [](Operation *node, Finding &f) {
    if (auto loc = dyn_cast<FileLineColLoc>(node->getLoc())) {
      f.line = loc.getLine();
      f.col = loc.getColumn();
    }
  };
  for (const auto &[name, sides] : membership->sides) {
    if (!sides.count("user") || !sides.count("bpf"))
      continue;
    Finding f;
    f.node = membership->defs.at(name);
    f.message = "function `" + name +
                "` is reached from both the user-space side and the eBPF "
                "side ({User, BPF}) — the eBPF side's functions must not be "
                "called from Ruby";
    f.path = {"user", name};
    position(f.node, f);
    findings.push_back(std::move(f));
  }
  std::set<Operation *> bpfDefs;
  for (const auto &[name, node] : membership->defs) {
    auto found = membership->sides.find(name);
    if (found != membership->sides.end() && found->second.count("bpf"))
      bpfDefs.insert(node);
  }
  for (auto top : membership->topStatements) {
    if (bpfDefs.count(top))
      continue;
    llvm::DenseSet<Operation *> seen;
    auto walk = [&](auto &&self, Operation *c) -> void {
      if (!c || !seen.insert(c).second)
        return;
      if (text(c, "kind") == "CallNode") {
        auto &ev = evidence[id(c)];
        if (ev.size() == 1) {
          auto callee = text(ev.front(), "callee");
          if (ebpfOnlyCallees().contains(callee)) {
            Finding f;
            f.node = c;
            f.message = "`" + callee.str() +
                        "` is eBPF-side only — user space reads maps through "
                        "the loaded object (SpinelBPF)";
            position(c, f);
            findings.push_back(std::move(f));
          }
        }
      }
      for (auto attr : c->getAttrOfType<DictionaryAttr>("refs")) {
        auto v = cast<IntegerAttr>(attr.getValue()).getInt();
        if (v >= 0)
          self(self, analyzed.lookup(v));
      }
      for (auto attr : c->getAttrOfType<DictionaryAttr>("arrays"))
        for (auto v : cast<ArrayAttr>(attr.getValue()))
          self(self, analyzed.lookup(cast<IntegerAttr>(v).getInt()));
    };
    walk(walk, top);
  }
  std::vector<PendingDiagnostic> out;
  for (auto &f : findings) {
    std::optional<std::string> path;
    if (!f.path.empty())
      path = llvm::join(f.path, " -> ");
    out.push_back({f.line, f.col,
                   renderDiagnostic(f.node, "rejected", "SB003",
                                    "CrossDomainUse", f.message, path), "",
                   DiagnosticVerdict::Rejected, "SB003"});
    if (inspectionOutput)
      out.back().domain = domainDiagnostic(f.node, "rejected", "SB003",
                                          "CrossDomainUse", f.message, path);
  }
  return out;
}
} // namespace spinel::consumer
