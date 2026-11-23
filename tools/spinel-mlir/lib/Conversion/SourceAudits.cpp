// Go v0.6.0 internal/frontend/analyze.go:103-123,1001-1040.
#include "spinel/Conversion/SourceAudits.h"
#include "llvm/ADT/StringSet.h"
#include <algorithm>

namespace spinel::consumer {
namespace {
bool member(StringRef value, std::initializer_list<StringRef> names) {
  return llvm::is_contained(names, value);
}
bool reserved(StringRef name) {
  return name.starts_with("spinelbpf_") || name.starts_with("_spinelbpf_");
}
Dispatch<bool> rejectReopenedIntegerOperator(Consumer &c, Operation *node) {
  // Reject only. This does not certify equivalent ASTs or produce an Expr.
  if (c.probing || !c.sourceAuditUnknown || !c.runDiagnostics ||
      text(node,"kind")!="CallNode" || field(node,"strings","name")!="+" ||
      text(c.ref(node,"receiver"),"kind")!="IntegerNode" || !c.activeDef)
    return Dispatch<bool>::declined();
  auto args=c.args(node);
  if(args.size()!=1 || text(args[0],"kind")!="IntegerNode" || c.ref(node,"block"))
    return Dispatch<bool>::declined();
  bool root=llvm::any_of(c.rootEntries,[&](Operation *entry) {
    auto values=c.args(entry);
    return !values.empty() && text(values[0],"kind")=="SymbolNode" &&
        c.spelling(values[0],true)==field(c.activeDef,"strings","name") &&
        entry->getAttr("file_id")==c.activeDef->getAttr("file_id");
  });
  bool inRoot=false;
  for(auto parent=node;parent;parent=c.parent(parent))
    if(parent==c.activeDef) { inRoot=true;break; }
  if(!root || !inRoot || node->getAttrOfType<IntegerAttr>("file_id").getInt()!=0)
    return Dispatch<bool>::declined();
  auto target=c.analyzed.lookup(c.id(node));
  if(!target || text(target,"kind")!="CallNode" || target->getLoc()!=node->getLoc() ||
      target->getAttr("file_id")!=node->getAttr("file_id") || target->getAttr("span")!=node->getAttr("span"))
    return Dispatch<bool>::declined();
  auto cloneName="__int_+__"+std::to_string(c.id(node));
  auto evidence=c.evidence.find(c.id(node));
  if(field(target,"strings","name")!=cloneName || evidence==c.evidence.end() || evidence->second.size()!=1 ||
      text(evidence->second[0],"phase")!="analyzed" || text(evidence->second[0],"kind")!="CallNode" ||
      text(evidence->second[0],"dispatch")!="direct" || text(evidence->second[0],"name")!=cloneName ||
      text(evidence->second[0],"callee")!=cloneName)
    return Dispatch<bool>::declined();
  int64_t copy;
  if(field(target,"integers","bx_copy").getAsInteger(10,copy) || field(target,"integers","bx_container")!="0")
    return Dispatch<bool>::declined();
  auto clone=c.analyzed.lookup(copy);
  if(!clone || text(clone,"kind")!="DefNode" || field(clone,"strings","name")!=cloneName)
    return Dispatch<bool>::declined();
  // All original non-rewrite attributes remain exact; this is a recognition
  // of a rejected call, never an alternative to equivalentNode on success.
  for(auto attr:node->getAttrs())
    if(attr.getName()!="strings" && attr.getName()!="integers" && attr.getName()!="refs" &&
       attr.getValue()!=target->getAttr(attr.getName())) return Dispatch<bool>::declined();
  auto strings=node->getAttrOfType<DictionaryAttr>("strings");
  auto targetStrings=target->getAttrOfType<DictionaryAttr>("strings");
  if(strings.size()!=targetStrings.size())return Dispatch<bool>::declined();
  for(auto attr:strings)
    if(attr.getName()!="name" && attr.getValue()!=targetStrings.get(attr.getName()))return Dispatch<bool>::declined();
  auto integers=node->getAttrOfType<DictionaryAttr>("integers");
  auto targetIntegers=target->getAttrOfType<DictionaryAttr>("integers");
  if(targetIntegers.size()!=integers.size()+2)return Dispatch<bool>::declined();
  for(auto attr:integers)
    if(attr.getValue()!=targetIntegers.get(attr.getName()))return Dispatch<bool>::declined();
  auto refs=target->getAttrOfType<DictionaryAttr>("refs");
  auto receiver=refs.getAs<IntegerAttr>("receiver"), block=refs.getAs<IntegerAttr>("block"), arguments=refs.getAs<IntegerAttr>("arguments");
  if(refs.size()!=3 || !receiver || receiver.getInt()!=-1 || !block || block.getInt()!=-1 || !arguments)
    return Dispatch<bool>::declined();
  auto tuple=c.analyzed.lookup(arguments.getInt());
  if(!tuple || text(tuple,"kind")!="ArgumentsNode")return Dispatch<bool>::declined();
  auto tupleValues=tuple->getAttrOfType<DictionaryAttr>("arrays").getAs<ArrayAttr>("arguments");
  if(!tupleValues || tupleValues.size()!=2 || cast<IntegerAttr>(tupleValues[0]).getInt()!=c.id(c.ref(node,"receiver")) ||
     cast<IntegerAttr>(tupleValues[1]).getInt()!=c.id(args[0]))return Dispatch<bool>::declined();
  Operation *sourceDef=nullptr,*sourceClass=nullptr;
  for(auto &[id,candidate]:c.nodes) {
    if(text(candidate,"kind")!="DefNode" || field(candidate,"strings","name")!="+" ||
        candidate->getLoc()!=clone->getLoc() || candidate->getAttr("span")!=clone->getAttr("span") ||
        candidate->getAttr("file_id")!=clone->getAttr("file_id"))continue;
    for(auto parent=c.parent(candidate);parent;parent=c.parent(parent)) {
      if(text(parent,"kind")!="ClassNode")continue;
      if(c.constant(c.ref(parent,"constant_path"))=="Integer" && parent->getAttrOfType<IntegerAttr>("file_id").getInt()==0) {
        if(sourceDef)return Dispatch<bool>::declined();
        sourceDef=candidate;sourceClass=parent;
      }
      break;
    }
  }
  if(!sourceClass)return Dispatch<bool>::declined();
  auto location=cast<FileLineColLoc>(sourceClass->getLoc());
  if(!llvm::any_of(*c.runDiagnostics,[&](const auto &diagnostic) {
    return diagnostic.verdict==Consumer::DiagnosticVerdict::Unknown && diagnostic.code=="SB016" &&
        diagnostic.rejectedCode.empty() && diagnostic.line==location.getLine() && diagnostic.col==location.getColumn();
  }))return Dispatch<bool>::declined();
  (void)c.diagnostic(node,"SB009","OperatorRedefined","operator `+` resolves to the user definition "+cloneName+" — redefined operators are refused",true);
  return Dispatch<bool>::error();
}
} // namespace
LogicalResult auditProgramSource(Consumer &c, llvm::ArrayRef<Operation *>) {
  std::vector<Operation *> nodes;
  for (auto &[id, node] : c.nodes) {
    auto file = node->getAttrOfType<IntegerAttr>("file_id");
    if (file && file.getInt() == 0) nodes.push_back(node);
  }
  std::sort(nodes.begin(), nodes.end(), [&](Operation *a, Operation *b) {
    auto al = cast<FileLineColLoc>(a->getLoc()), bl = cast<FileLineColLoc>(b->getLoc());
    return std::make_tuple(al.getLine(), al.getColumn(), c.id(a)) <
           std::make_tuple(bl.getLine(), bl.getColumn(), c.id(b));
  });
  bool found = false;
  auto report = [&](Operation *node, bool unknown, StringRef code, StringRef label, const std::string &message) {
    found = true;
    if (unknown) (void)c.unknownDiagnostic(node, code, label, message);
    else (void)c.diagnostic(node, code, label, message);
  };
  for (auto node : nodes) {
    auto kind = text(node, "kind"), name = field(node, "strings", "name");
    if (kind == "ClassNode" || kind == "ModuleNode") {
      auto constant = c.constant(c.ref(node, "constant_path"));
      auto shortName = StringRef(constant).rsplit(':').second;
      if (shortName.empty()) shortName = constant;
      if (StringRef(constant).starts_with("BPF::") || member(shortName, {
          "BPF", "ArrayMap", "MapRef", "XdpMd", "Window", "RecordMap", "RecordRef", "RingBuf",
          "HashMap", "LruHashMap", "RecordHashMap", "LruRecordHashMap", "PerCpuArrayMap", "PerCpuRecordMap",
          "PerCpuHashMap", "PerCpuRecordHashMap", "LpmTrieMap", "DevMap", "SockMap"})) {
        report(node, false, "SB011", "ShadowedName", "`" + constant + "` is defined by ruby/lib/bpf.rb — the program must not define or reopen it");
      } else if (member(shortName, {"Integer", "Object", "Kernel", "BasicObject", "Comparable", "Module", "Class", "NilClass",
                                  "TrueClass", "FalseClass", "Symbol", "String", "Array", "Hash", "Numeric"})) {
        report(node, true, "SB016", "DynamicProgram", "the program reopens builtin `" + constant + "` — operators and calls may no longer mean what the eBPF side assumes");
      }
    } else if (kind == "SingletonClassNode") {
      report(node, true, "SB016", "DynamicProgram", "`class << …` is outside P001 (static call targets)");
    } else if (kind == "DefNode") {
      if (member(name, {"method_missing", "respond_to_missing?"}))
        report(node, true, "SB016", "DynamicProgram", "the program defines `" + name.str() + "` — calls may no longer resolve statically");
      if (reserved(name)) {
        std::string message = "`" + name.str() + "` uses the reserved prefix spinelbpf_";
#ifdef SPINEL_E052_TEST_DIAGNOSTIC_BYTE
        message.back() = '!';
#endif
        report(node, false, "SB007", "ReservedName", message);
      }
      if (name.starts_with("__ebpf_"))
        report(node, false, "SB007", "ReservedName", "`" + name.str() + "` uses the reserved prefix __ebpf_ — a program or an eBPF-side function becomes a symbol next to bpf-mlir's internal functions (`__ebpf_present_*` — the outlined ring buffer present, `__ebpf_loop_cb_*` …); rename it (P025 E103)");
    } else if (kind == "CallNode" && member(name, {
        "send", "public_send", "__send__", "define_method", "instance_eval", "class_eval", "module_eval", "instance_exec", "class_exec", "eval", "method",
        "instance_variable_get", "instance_variable_set", "const_get", "const_set", "prepend", "include", "extend", "refine", "using", "alias_method", "remove_method", "undef_method"})) {
      report(node, true, "SB016", "DynamicProgram", "the program calls `" + name.str() + "` — calls may no longer resolve statically");
    } else if (kind == "ConstantWriteNode" && reserved(name.lower())) {
      report(node, false, "SB007", "ReservedName", "`" + name.str() + "` uses the reserved prefix spinelbpf_");
    }
  }
  return failure(found);
}
void registerSourceAudits(Registry &registry) {
  registry.sourceAudits.push_back(auditProgramSource);
  registry.rejectOnlyScalarChecks.push_back(rejectReopenedIntegerOperator);
}
} // namespace spinel::consumer
