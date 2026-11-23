#include "spinel/Conversion/RecordValue.h"
#include "spinel/Conversion/RecordExport.h"
#include "llvm/Support/Error.h"

namespace spinel::consumer {
namespace {
Dispatch<bool> reject(Consumer &c, Operation *node, const std::string &message) {
  (void)c.diagnostic(node, "SB024", "RecordShape", message);
  return Dispatch<bool>::error();
}
struct StructInfo {
  Operation *node = nullptr;
  std::vector<std::string> members;
  std::string bad;
};
std::optional<StructInfo> structInfo(Consumer &c, Operation *node) {
  auto call = c.ref(node, "value");
  if (!call || text(call, "kind") != "CallNode") return std::nullopt;
  auto receiver = c.constant(c.ref(call, "receiver"));
  auto method = field(call, "strings", "name");
  StructInfo info;
  info.node = node;
  if (receiver == "Data" && method == "define") {
    info.bad = "Data.define has no member setters — a record is a Struct (P006 §1)";
    return info;
  }
  if (receiver != "Struct" || method != "new") return std::nullopt;
  if (c.ref(call, "block")) {
    info.bad = "a record Struct takes no block (P006 §1)";
    return info;
  }
  for (auto arg : c.args(call)) {
    if (text(arg, "kind") != "SymbolNode") {
      info.bad = "a record Struct takes Symbol literals only — no keyword_init, no string name (P006 §1)";
      return info;
    }
    info.members.push_back(c.spelling(arg, true).str());
  }
  if (info.members.empty()) info.bad = "a record Struct needs at least one member";
  return info;
}
Dispatch<bool> declareRecord(Consumer &c, Operation *node) {
  auto args = c.args(node);
  if (args.size() != 2 || text(args[0], "kind") != "ConstantReadNode" ||
      text(args[1], "kind") != "KeywordHashNode")
    return reject(c, node,
        "a record is declared as `BPF.record(S, member: :u16, …)` with S a Struct constant and every member's type (P006 §1)");
  const auto name = c.constant(args[0]);
  c.badRecords.insert(name);
  std::optional<StructInfo> info;
  for (auto candidate : c.selectedTop)
    if (text(candidate, "kind") == "ConstantWriteNode" &&
        field(candidate, "strings", "name") == name) {
      auto parsed = structInfo(c, candidate);
      if (parsed) info = std::move(parsed);
    }
  if (!info)
    return reject(c, args[0], name + " is not a top-level `" + name +
        " = Struct.new(:m, …)` (P006 §1)");
  if (!info->bad.empty()) return reject(c, info->node, name + ": " + info->bad);
  if (lookupRecordLayout(c, name))
    return reject(c, node, "record " + name + " is declared twice");
  std::vector<record::FieldSpec> fields;
  struct Sites { Operation *member, *type, *count; };
  std::vector<Sites> sites;
  for (auto element : c.array(args[1], "elements")) {
    auto key = c.ref(element, "key"), value = c.ref(element, "value");
    std::optional<int64_t> count;
    auto countNode = value;
    if (text(element, "kind") == "AssocNode" && key && value &&
        text(key, "kind") == "SymbolNode" && text(value, "kind") == "ArrayNode") {
      auto elements = c.array(value, "elements");
      const auto member = c.spelling(key, true).str();
      if (elements.size() != 2 || text(elements[0], "kind") != "SymbolNode" ||
          text(elements[1], "kind") != "IntegerNode")
        return reject(c, value, "member " + member + ": an array member is `" +
            member + ": [:u32, N]` — the element type and a literal length (P016)");
      countNode = elements[1];
      int64_t n;
      if (text(countNode, "literal_decimal").getAsInteger(10, n) || n < 1 || n > 64)
        return reject(c, countNode, "member " + member +
            ": the array length must be a literal 1..64 (bpf-mlir's record arrays) (P016)");
      count = n;
      value = elements[0];
    }
    if (text(element, "kind") != "AssocNode" || !key || !value ||
        text(key, "kind") != "SymbolNode" || text(value, "kind") != "SymbolNode")
      return reject(c, element,
          "each member is `name: :type` (or `name: [:type, N]` for an array) with Symbol literals (P006 §1・P016)");
    fields.push_back({c.spelling(key, true).str(), c.spelling(value, true).str(), count});
    sites.push_back({element, value, countNode});
  }
  auto result = record::layout(name, info->members, fields);
  if (result.issue) {
    auto where = node;
    const auto &issue = *result.issue;
    if (issue.field < sites.size()) {
      if (issue.site == record::Site::Member) where = sites[issue.field].member;
      if (issue.site == record::Site::Type) where = sites[issue.field].type;
      if (issue.site == record::Site::Count) where = sites[issue.field].count;
    }
    return reject(c, where, issue.message);
  }
  RecordDecl record;
  record.node = node;
  record.name = name;
  record.recordLayout = std::make_shared<const record::Layout>(std::move(result.layout));
  c.records.push_back(std::move(record));
  c.badRecords.erase(name);
  return Dispatch<bool>::handled(true);
}
LogicalResult auditRecordSource(Consumer &c, ArrayRef<Operation *> roots) {
  if (c.records.empty()) return success();
  std::set<int64_t> files;
  std::set<std::string> rootNames;
  for (auto root : roots) {
    files.insert(root->getAttrOfType<IntegerAttr>("file_id").getInt());
    auto args = c.args(root);
    if (!args.empty() && text(args[0], "kind") == "SymbolNode")
      rootNames.insert(c.spelling(args[0], true).str());
  }
  std::map<std::string, RecordLayoutPtr> layouts;
  std::map<std::string, std::string> memberNames;
  for (const auto &record : c.records) if (record.recordLayout) {
    layouts[record.name] = record.recordLayout;
    for (const auto &f : record.recordLayout->fields) {
      memberNames[f.name] = record.name;
      memberNames[f.name + "="] = record.name;
    }
  }
  std::vector<Operation *> nodes;
  for (const auto &entry : c.nodes) {
    auto file = entry.second->getAttrOfType<IntegerAttr>("file_id");
    if (file && files.count(file.getInt())) nodes.push_back(entry.second);
  }
  std::sort(nodes.begin(), nodes.end(), [](Operation *a, Operation *b) {
    auto al = cast<FileLineColLoc>(a->getLoc()), bl = cast<FileLineColLoc>(b->getLoc());
    return std::make_tuple(al.getFilename().str(), al.getLine(), al.getColumn(), a->getAttrOfType<IntegerAttr>("id").getInt()) <
           std::make_tuple(bl.getFilename().str(), bl.getLine(), bl.getColumn(), b->getAttrOfType<IntegerAttr>("id").getInt());
  });
  bool rejected = false;
  auto issue = [&](Operation *node, StringRef code, StringRef name, const std::string &message) {
    (void)c.diagnostic(node, code, name, message); rejected = true;
  };
  for (auto node : nodes) {
    auto kind = text(node, "kind"), name = field(node, "strings", "name");
    if (kind == "DefNode" && memberNames.count(name.str()))
      issue(node,"SB011","ShadowedName","`def " + name.str() + "` shares a name with a member of record " +
          memberNames.at(name.str()) + " — the eBPF side reads members by the declaration, so a user method of that name is refused (P006 §2)");
    if (kind == "ClassNode") {
      auto constant = c.constant(c.ref(node,"constant_path"));
      if (layouts.count(constant)) issue(node,"SB011","ShadowedName","record " + constant +
          " is reopened — its members must stay the Struct's accessors (P006 §2)");
    }
    if (kind != "CallNode") continue;
    auto args = c.args(node);
    if (name == "new") {
      auto constant = c.constant(c.ref(node, "receiver"));
      auto found = layouts.find(constant);
      if (found != layouts.end()) {
        bool splat = llvm::any_of(args, [](Operation *arg) { return text(arg,"kind") == "SplatNode"; });
        bool rootOrSample = false;
        for (auto parent = c.parent(node); parent; parent = c.parent(parent)) {
          if (text(parent,"kind") == "DefNode" && rootNames.count(field(parent,"strings","name").str())) rootOrSample = true;
          if (text(parent,"kind") == "CallNode" && field(parent,"strings","name") == "new" &&
              c.constant(c.ref(parent,"receiver")) == "BPF::RecordMap") rootOrSample = true;
        }
        const auto &fields = found->second->fields;
        if (!splat && args.size() != fields.size() && !rootOrSample) {
          std::string names;
          for (const auto &f : fields) { if (!names.empty()) names += ", "; names += f.name; }
          issue(node,"SB024","RecordShape","`" + constant + ".new` takes all " + std::to_string(fields.size()) +
              " members of record " + constant + " in the declaration order (" + names + "), got " +
              std::to_string(args.size()) + " — e.g. `" + constant + ".new(v[0], …, v[" +
              std::to_string(fields.size()-1) + "])` for `v = obj.map_get(M, k)` (P006 §3)");
        }
        for (auto arg : args) if (text(arg,"kind") == "SplatNode")
          issue(node,"SB024","RecordShape","`" + constant + ".new(*…)` — a splat makes Spinel type every member of record " +
              constant + " as untyped program-wide (the eBPF side then refuses); pass the members explicitly, e.g. `" +
              constant + ".new(v[0], v[1], …)` (P006 §3, E021)");
      }
    }
    if (name == "attr_accessor" || name == "attr_reader" || name == "attr_writer" || name == "alias_method")
      for (auto arg : args) if (text(arg,"kind") == "SymbolNode") {
        auto symbol = c.spelling(arg,true).str();
        if (memberNames.count(symbol)) issue(node,"SB011","ShadowedName","`" + name.str() + " :" + symbol +
            "` shares a name with a member of record " + memberNames.at(symbol) + " (P006 §2)");
      }
  }
  return failure(rejected);
}
} // namespace
void registerGroupRecord(Registry &registry) {
  registry.sourceAudits.push_back(auditRecordSource);
  // Go program.go:997-999. Record constructors are consumed only by the
  // destination-specific checked path, never as ordinary scalar values.
  registry.addExpression("CallNode", [](Consumer &c, Operation *node) {
    if (field(node, "strings", "name") != "new")
      return Dispatch<Expr>::declined();
    auto name = c.constant(c.ref(node, "receiver"));
    if (!lookupRecordLayout(c, name)) return Dispatch<Expr>::declined();
    (void)c.diagnostic(node, "SB024", "RecordShape",
        "a record value `" + name +
        ".new(…)` is written directly as the argument of the map / ring buffer call that takes it (key, value or event) — it is not kept in a local or used as another value (bpf-mlir: a record.make result does not cross blocks) (P006 §2・P008 §2)", true);
    return Dispatch<Expr>::error();
  });
  // Struct declarations used only by user-space Ruby are not rejected here.
  auto deferStruct = [](Consumer &, Operation *) { return Dispatch<bool>::handled(true); };
  registry.addDeclaration({"Struct", "new"}, deferStruct);
  registry.addDeclaration({"Data", "define"}, deferStruct);
  registry.addDeclaration({"BPF", "record"}, declareRecord);
  registry.addRecordExporter([](Consumer &c, size_t index, bool schema) {
    if (index >= c.records.size())
      return (void)c.error(nullptr, "record export index out of range"),
             Dispatch<ExportFields>::error();
    auto layout = c.records[index].recordLayout;
    if (!layout) return Dispatch<ExportFields>::declined();
    auto order = c.usedRecordOrder();
    auto position = std::find(order.begin(), order.end(), index);
    if (position == order.end())
      return (void)c.error(c.records[index].node, "record export is not in usedRecordOrder"),
             Dispatch<ExportFields>::error();
    return Dispatch<ExportFields>::handled(recordExport(layout,
        static_cast<size_t>(position - order.begin()), schema));
  });
}
} // namespace spinel::consumer
