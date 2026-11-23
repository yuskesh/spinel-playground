#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Pass/Pass.h"
#include "spinel/Analysis/GroupARange.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <tuple>

#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/ConsumerTypingProbe.h"
#include "spinel/Conversion/Subprograms.h"
#include "spinel/Conversion/GroupGProbe.h"
using namespace mlir;
namespace spinel::consumer {
StringRef text(Operation *op, StringRef field) {
  if (!op)
    return {};
  auto attr = op->getAttrOfType<StringAttr>(field);
  return attr ? attr.getValue() : StringRef();
}
StringRef field(Operation *op, StringRef dict, StringRef key) {
  if (!op)
    return {};
  auto d = op->getAttrOfType<DictionaryAttr>(dict);
  if (!d)
    return {};
  auto v = d.getAs<StringAttr>(key);
  return v ? v.getValue() : StringRef();
}
LogicalResult checkLiteralNode(ir::NodeOp node, std::optional<inspection::Diagnostic> * = nullptr);
Location outputLoc(Operation *node) {
  auto loc = dyn_cast<FileLineColLoc>(node->getLoc());
  if (!loc)
    return node->getLoc();
  return FileLineColLoc::get(
      node->getContext(),
      llvm::sys::path::filename(loc.getFilename().getValue()), loc.getLine(),
      loc.getColumn());
}
Consumer::Consumer(ModuleOp module)
    : input(module), ctx(module.getContext()), builder(ctx) {
  registerConsumerGroups(registry);
  for (auto table : module.getOps<ir::TableOp>()) {
    auto &dest = text(table, "phase") == "pristine" ? nodes : analyzed;
    for (auto node : table.getBody().front().getOps<ir::NodeOp>())
      dest[node->getAttrOfType<IntegerAttr>("id").getInt()] = node;
  }
  for (auto type : module.getOps<ir::TypeOp>())
    types[type->getAttrOfType<IntegerAttr>("node_id").getInt()].push_back(type);
  for (auto item : module.getOps<ir::EvidenceOp>())
    evidence[item->getAttrOfType<IntegerAttr>("node_id").getInt()].push_back(
        item);
  for (const auto &entry : nodes) {
    auto node = entry.second;
    for (auto item : node->getAttrOfType<DictionaryAttr>("refs")) {
      auto child = nodes.lookup(cast<IntegerAttr>(item.getValue()).getInt());
      if (child)
        parents.try_emplace(child, node);
    }
    for (auto item : node->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto value : cast<ArrayAttr>(item.getValue())) {
        auto child = nodes.lookup(cast<IntegerAttr>(value).getInt());
        if (child)
          parents.try_emplace(child, node);
      }
  }
}

LogicalResult Consumer::diagnostic(Operation *node, StringRef code,
                                   StringRef name, StringRef message,
                                   bool withPath) {
  std::optional<std::string> path;
  if (withPath)
    path = activeDiagnosticPath.empty() ? programName
                                        : llvm::join(activeDiagnosticPath, " -> ");
  return recordDiagnostic(node, code, name, message, false, std::move(path));
}

LogicalResult Consumer::unknownDiagnostic(Operation *node, StringRef code,
                                          StringRef name, StringRef message,
                                          bool withPath) {
  std::optional<std::string> path;
  if (withPath)
    path = activeDiagnosticPath.empty() ? programName
                                        : llvm::join(activeDiagnosticPath, " -> ");
  return recordDiagnostic(node, code, name, message, true, std::move(path));
}

LogicalResult Consumer::recordLocatedDiagnostic(const inspection::Diagnostic &d) {
  if (probing || !runDiagnostics || d.verdict != "rejected" || d.code != "SB010")
    return error(nullptr,"located typing diagnostic requires the run's final comparison");
  blocking = true;
  std::string rendered=d.pos.file+":"+std::to_string(d.pos.line)+":"+
    std::to_string(d.pos.col)+": rejected "+d.code+" ("+d.name+"): "+d.message;
  runDiagnostics->push_back({d.pos.line,d.pos.col,std::move(rendered),d.code,
    DiagnosticVerdict::Rejected,d.code,d});
  return failure();
}

LogicalResult Consumer::recordDiagnostic(Operation *node, StringRef code,
                                         StringRef name, StringRef message,
                                         bool unknown,
                                         std::optional<std::string> path) {
  if (probing) {
    probeIssues.push_back({node ? id(node) : 0, code.str(), message.str(),
                           name.str(), unknown, std::move(path)});
    return failure();
  }
  blocking = true;
  if (inspectionOutput) noteInspectionBody(node);
  StringRef verdict = unknown ? "unknown" : "rejected";
  auto rendered = renderDiagnostic(node, verdict,
                                    code, name, message, path);
  if (runDiagnostics) {
    auto loc = node ? dyn_cast<FileLineColLoc>(node->getLoc()) : FileLineColLoc();
    runDiagnostics->push_back({loc ? loc.getLine() : 0,
                               loc ? loc.getColumn() : 0, std::move(rendered),
                               unknown ? "" : code.str(),
                               unknown ? DiagnosticVerdict::Unknown
                                       : DiagnosticVerdict::Rejected,
                               code.str()});
    if (inspectionOutput)
      runDiagnostics->back().domain = domainDiagnostic(node, verdict, code, name, message, path);
  } else {
    llvm::errs() << rendered << "\n";
    ++printedRejections;
  }
  return failure();
}

LogicalResult Consumer::recoverRejectedProgram(StringRef rejectedCode) {
  if (probing || (rejectedCode != "SB019" && rejectedCode != "SB034") ||
      !runDiagnostics ||
      llvm::none_of(*runDiagnostics, [&](const PendingDiagnostic &d) {
        return d.rejectedCode == rejectedCode;
      })) {
    input.emitError("program recovery requires an actual SB019/SB034 rejection");
    return failure();
  }
  programBodyRejected = true;
  declarationRecovery = true;
  blocking = false;
  return success();
}

void Consumer::conditionalDiagnostic(Operation *node, StringRef code,
                                      StringRef name, StringRef message) {
  auto loc = cast<FileLineColLoc>(node->getLoc());
  pendingConditionals.push_back({loc.getLine(), loc.getColumn(),
      renderDiagnostic(node, "conditional", code, name, message)});
  if (inspectionOutput)
    pendingConditionals.back().domain = domainDiagnostic(node, "conditional", code, name, message);
}

void Consumer::prepareDeclarationRecovery(Operation *body) {
  recoverySkipped.clear();
  if (!declarationRecovery)
    return;
  std::set<std::string> absent;
  for (const auto &name : failedDataDeclarations)
    if (llvm::none_of(maps, [&](const auto &m) { return m.name == name; }) &&
        llvm::none_of(globals, [&](const auto &g) { return g.name == name; }))
      absent.insert(name);
  std::set<std::string> badLookupBindings;
  auto badUse = [&](auto &&self, Operation *n) -> bool {
    if (!n)
      return false;
    if (text(n, "kind") == "LocalVariableReadNode" &&
        badLookupBindings.count(field(n, "strings", "name").str()))
      return true;
    if (text(n, "kind") == "CallNode" &&
        absent.count(constant(ref(n, "receiver"))))
      return true;
    for (auto a : n->getAttrOfType<DictionaryAttr>("refs")) {
      auto number = cast<IntegerAttr>(a.getValue()).getInt();
      if (number >= 0 && self(self, nodes.lookup(number)))
        return true;
    }
    for (auto a : n->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto number : cast<ArrayAttr>(a.getValue()))
        if (self(self, nodes.lookup(cast<IntegerAttr>(number).getInt())))
          return true;
    return false;
  };
  auto visit = [&](auto &&self, Operation *n) -> void {
    if (!n)
      return;
    auto kind = text(n, "kind");
    if (kind == "StatementsNode") {
      for (auto statement : array(n, "body"))
        self(self, statement);
      return;
    }
    // Go's nil condition drops the entire branch, including both bodies.
    auto expression = kind == "IfNode" || kind == "UnlessNode"
                          ? ref(n, "predicate")
                          : n;
    if (badUse(badUse, expression)) {
      recoverySkipped.insert(id(n));
      if (kind == "LocalVariableWriteNode") {
        auto value = ref(n, "value");
        // Only failed lookup bindings have Go's badBind semantics. A failed
        // output assignment is skipped without poisoning its local name.
        if (text(value, "kind") == "CallNode" &&
            field(value, "strings", "name") == "lookup")
          badLookupBindings.insert(field(n, "strings", "name").str());
      }
      return;
    }
    for (auto a : n->getAttrOfType<DictionaryAttr>("refs")) {
      auto number = cast<IntegerAttr>(a.getValue()).getInt();
      if (number >= 0)
        self(self, nodes.lookup(number));
    }
    for (auto a : n->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto number : cast<ArrayAttr>(a.getValue()))
        self(self, nodes.lookup(cast<IntegerAttr>(number).getInt()));
  };
  visit(visit, body);
}

std::string Consumer::renderDiagnostic(Operation *node, StringRef verdict,
                                       StringRef code, StringRef name,
                                       StringRef message,
                                       std::optional<std::string> path) {
  std::string out;
  llvm::raw_string_ostream os(out);
  auto loc = node ? dyn_cast<FileLineColLoc>(node->getLoc()) : FileLineColLoc();
  if (loc)
    os << llvm::sys::path::filename(loc.getFilename().getValue()) << ":"
       << loc.getLine() << ":" << loc.getColumn();
  else
    os << "<unknown>";
  os << ": " << verdict << " " << code << " (" << name << "): " << message;
  if (path)
    os << " [path: " << *path << "]";
  return out;
}

LogicalResult Consumer::diagnosticWithPath(Operation *node, StringRef code,
                                           StringRef name, StringRef message,
                                           llvm::ArrayRef<std::string> path) {
  auto saved = activeDiagnosticPath;
  activeDiagnosticPath.assign(path.begin(), path.end());
  auto result = diagnostic(node, code, name, message, !path.empty());
  activeDiagnosticPath = std::move(saved);
  return result;
}

LogicalResult Consumer::error(Operation *node, StringRef message) {
  return diagnostic(node, "SB001", "UnsupportedConstruct", message);
}

bool Consumer::isProducer() const {
  auto profile = text(input, "spinel_facts.profile");
  return profile == "spinel-codegen-v1" || profile == "spinel-codegen-v2";
}

StringRef Consumer::spelling(Operation *node, bool symbol) {
  auto primary =
      field(node, "strings",
            isProducer() ? (symbol ? "value" : "content") : "unescaped");
  auto alternate = field(node, "strings", "unescaped");
  if (isProducer() && !alternate.empty() && alternate != primary)
    return {};
  return primary;
}

int64_t Consumer::id(Operation *node) {
  return node->getAttrOfType<IntegerAttr>("id").getInt();
}

Operation *Consumer::ref(Operation *node, StringRef key) {
  if (!node)
    return nullptr;
  auto d = node->getAttrOfType<DictionaryAttr>("refs");
  auto v = d ? d.getAs<IntegerAttr>(key) : IntegerAttr();
  return v && v.getInt() >= 0 ? nodes.lookup(v.getInt()) : nullptr;
}

SmallVector<Operation *> Consumer::array(Operation *node, StringRef key) {
  SmallVector<Operation *> result;
  if (!node)
    return result;
  auto d = node->getAttrOfType<DictionaryAttr>("arrays");
  auto a = d ? d.getAs<ArrayAttr>(key) : ArrayAttr();
  if (a)
    for (auto x : a)
      result.push_back(nodes.lookup(cast<IntegerAttr>(x).getInt()));
  return result;
}

SmallVector<Operation *> Consumer::args(Operation *node) {
  return array(ref(node, "arguments"), "arguments");
}

std::string Consumer::constant(Operation *node, unsigned depth) {
  if (!node || depth > 32)
    return {};
  if (text(node, "kind") == "ConstantReadNode")
    return field(node, "strings", "name").str();
  if (text(node, "kind") != "ConstantPathNode")
    return {};
  auto parent = constant(ref(node, "parent"), depth + 1);
  return parent.empty() ? std::string()
                        : parent + "::" + field(node, "strings", "name").str();
}

LogicalResult Consumer::checkTree(Operation *node,
                                  llvm::DenseSet<int64_t> &seen, bool root) {
  if (!node || !seen.insert(id(node)).second)
    return success();
  if (!root && text(node, "kind") == "DefNode")
    return error(node, "E006 does not support nested method declarations");
  if (text(node, "kind") == "IntegerNode") {
    std::optional<inspection::Diagnostic> literal;
    if (failed(checkLiteralNode(cast<ir::NodeOp>(node), inspectionOutput ? &literal : nullptr))) {
      if (literal) {
        inspectionLiteralRejected = true;
        inspectionDomain.diagnostics.push_back(std::move(*literal));
      }
      return ++printedRejections, failure();
    }
  }
  if (auto loc = dyn_cast<FileLineColLoc>(node->getLoc())) {
    auto base = llvm::sys::path::filename(loc.getFilename().getValue());
    if (base.empty() || base == "." || base == "..")
      return error(node, "E006 invalid output location basename");
  }
  auto refs = node->getAttrOfType<DictionaryAttr>("refs");
  for (auto item : refs) {
    auto value = cast<IntegerAttr>(item.getValue()).getInt();
    if (value >= 0 && failed(checkTree(nodes.lookup(value), seen, false)))
      return failure();
  }
  auto arrays = node->getAttrOfType<DictionaryAttr>("arrays");
  for (auto item : arrays)
    for (auto value : cast<ArrayAttr>(item.getValue()))
      if (failed(checkTree(nodes.lookup(cast<IntegerAttr>(value).getInt()),
                           seen, false)))
        return failure();
  return success();
}

LogicalResult Consumer::select(Operation *root) {
  inspectionRootDefinitions.clear();
  llvm::DenseSet<int64_t> seen;
  if (text(root, "kind") != "ProgramNode")
    return checkTree(root, seen);
  auto top = array(ref(root, "statements"), "body");
  SmallVector<Operation *> roots;
  for (auto node : top)
    if (text(node, "kind") == "CallNode" &&
        (field(node, "strings", "name") == "xdp" ||
         llvm::any_of(registry.roots,
                      [&](const auto &h) {
                        return h.first == field(node, "strings", "name");
                      })) &&
        constant(ref(node, "receiver")) == "BPF") {
      roots.push_back(node);
    }
  if (roots.empty()) {
    // M1's combined ProgramNode can have file_id=-1; source 0 is the entry
    // source, never a required library. Import has checked source/node paths.
    Operation *source = nullptr;
    for (auto s : input.getOps<ir::SourceOp>())
      if (s->getAttrOfType<IntegerAttr>("file_id").getInt() == 0) {
        if (source) return error(root, "duplicate entry source for rootless declarations");
        source = s;
      }
    auto rootFile = root->getAttrOfType<IntegerAttr>("file_id");
    if (!source || text(source,"path").empty() || !rootFile ||
        (rootFile.getInt() != -1 && rootFile.getInt() != 0))
      return error(root, "rootless declarations require the entry source contract");
    std::vector<PendingDiagnostic> localDiagnostics;
    auto *previous = runDiagnostics;
    if (!runDiagnostics) runDiagnostics = &localDiagnostics;
    auto restore = llvm::make_scope_exit([&] {
      runDiagnostics = previous;
      if (!previous) for (const auto &d : localDiagnostics) {
        llvm::errs() << d.text << "\n";
        if (d.verdict != DiagnosticVerdict::Conditional) ++printedRejections;
      }
    });
    bool rejected = false;
    for (auto node : top) {
      auto file = node->getAttrOfType<IntegerAttr>("file_id");
      if (!file || file.getInt() != 0) continue;
      auto call = ref(node, "value");
      if (!call) call = node;
      bool registered = llvm::any_of(registry.declarations, [&](const auto &h) {
        return h.first.receiver == constant(ref(call,"receiver")) &&
               h.first.method == field(call,"strings","name");
      });
      if (!registered) continue;
      if (failed(checkTree(node, seen))) return failure();
      auto before = runDiagnostics->size();
      auto result = dispatchDeclaration(node);
      if (result.state != Disposition::Error) {
        if (blocking) return failure();
        continue;
      }
      bool data = text(node,"kind") == "ConstantWriteNode" ||
          (text(node,"kind") == "CallNode" && constant(ref(node,"receiver")) == "BPF" &&
           (field(node,"strings","name") == "record" || field(node,"strings","name") == "kernel_type"));
      bool diagnosed = false, internal = false;
      for (size_t i = before; i < runDiagnostics->size(); ++i) {
        auto message = StringRef((*runDiagnostics)[i].text);
        diagnosed |= message.contains(": rejected ");
        internal |= message.contains("rejected SB001") || message.contains("rejected SB017");
      }
      bool dependency = rejected && dependentDeclarationErrors.erase(id(node)) &&
          llvm::any_of(*runDiagnostics, [](const auto &d) {
            return StringRef(d.text).contains(": rejected ");
          });
      if (!data || internal || (!diagnosed && !dependency)) return failure();
      rejected = declarationRecovery = true;
      if (text(node,"kind") == "ConstantWriteNode")
        failedDataDeclarations.insert(field(node,"strings","name").str());
      blocking = false;
    }
    if (rejected) { blocking = true; return failure(); }
    Operation *nestedRoot = nullptr;
    for (const auto &[number, node] : nodes) {
      auto file = node->getAttrOfType<IntegerAttr>("file_id");
      if (!file || file.getInt() != 0 || text(node,"kind") != "CallNode" ||
          constant(ref(node,"receiver")) != "BPF") continue;
      auto name = field(node,"strings","name");
      if (name != "xdp" && !llvm::any_of(registry.roots,[&](const auto &handler) { return handler.first == name; })) continue;
      if (!nestedRoot || id(node) < id(nestedRoot)) nestedRoot = node;
    }
    if (nestedRoot)
      return diagnostic(nestedRoot,"SB008","ProgramShape","`BPF." + field(nestedRoot,"strings","name").str() + "` must be a top-level statement");
    blocking = true;
    runDiagnostics->push_back({0,0,
      llvm::sys::path::filename(text(source,"path")).str() +
      ": rejected SB008 (ProgramShape): no eBPF program: declare one with `BPF.xdp :name` at the top level",
      "SB008", DiagnosticVerdict::Rejected, "SB008"});
    if (inspectionOutput) {
      auto d = domainDiagnostic(nullptr,"rejected","SB008","ProgramShape",
          "no eBPF program: declare one with `BPF.xdp :name` at the top level");
      d.pos.file = llvm::sys::path::filename(text(source,"path")).str();
      runDiagnostics->back().domain = std::move(d);
    }

    return failure();
  }
  // The producer's observed Symbol field is used only for selection here.
  // The existing constructor/root validation remains unchanged in this step.
  auto entry = roots.front();
  auto fid = entry->getAttrOfType<IntegerAttr>("file_id");
  SmallVector<Operation *> declarations;
  for (auto node : top) {
    if (node->getAttrOfType<IntegerAttr>("file_id") != fid)
      continue;
    if (text(node, "kind") == "ConstantWriteNode") {
      auto call = ref(node, "value");
      bool extensionDecl =
          llvm::any_of(registry.declarations, [&](const auto &h) {
            return h.first.receiver == constant(ref(call, "receiver")) &&
                   h.first.method == field(call, "strings", "name");
          });
      if (extensionDecl ||
          (text(call, "kind") == "CallNode" &&
           field(call, "strings", "name") == "new" &&
           constant(ref(call, "receiver")) == "BPF::ArrayMap")) {
        declarations.push_back(node);
      }
    } else if (llvm::any_of(registry.declarations, [&](const auto &h) {
                 return h.first.receiver == constant(ref(node, "receiver")) &&
                        h.first.method == field(node, "strings", "name");
               })) {
      declarations.push_back(node);
    }
  }
  bool customRoot = llvm::any_of(roots, [&](Operation *node) {
    return llvm::any_of(registry.roots, [&](const auto &h) {
      return h.first == field(node, "strings", "name");
    });
  });
  if (declarations.empty() && !customRoot)
    return error(entry,
                 "E006 requires one ArrayMap declaration in the root file");
  selectedTop = declarations;
  std::set<std::string> rootNames;
  SmallVector<Operation *> graphRoots;
  for (auto rootEntry : roots) {
    auto as = args(rootEntry);
    bool registered = llvm::any_of(registry.roots, [&](const auto &h) {
      return h.first == field(rootEntry, "strings", "name");
    });
    if ((!registered && as.size() != 1) || as.empty() ||
        text(as[0], "kind") != "SymbolNode")
      return error(rootEntry, "E006 requires a literal XDP root target");
    auto name = spelling(as[0], true);
    if (!rootNames.insert(name.str()).second) {
      // Keep every call in the facts proof. Defer only a repeated, already
      // selected XDP declaration to scanTop, where unused diagnostics exist.
      bool repeatedXdp = field(rootEntry, "strings", "name") == "xdp" &&
          as.size() == 1 && llvm::any_of(graphRoots, [&](Operation *first) {
            return field(first, "strings", "name") == "xdp" &&
                   spelling(args(first)[0], true) == name;
          });
      if (!repeatedXdp)
        return diagnostic(rootEntry, "SB008", "ProgramShape",
                          "`BPF.xdp :" + name.str() + "` is declared twice");
      if (failed(known(rootEntry, true))) return failure();
      selectedTop.push_back(rootEntry);
      continue;
    }
    Operation *def = nullptr;
    for (auto n : top)
      if (n->getAttrOfType<IntegerAttr>("file_id") == fid &&
          text(n, "kind") == "DefNode" && !ref(n, "receiver") &&
          field(n, "strings", "name") == name) {
        if (def)
          return error(n, "E006 requires one root method in the root file");
        def = n;
      }
    if (!def)
      return diagnostic(rootEntry,"SB008","ProgramShape","`BPF." + field(rootEntry,"strings","name").str() + " :" + name.str() + "` names no top-level `def " + name.str() + "`");
    if (inspectionOutput) inspectionRootDefinitions[rootEntry] = def;
    selectedTop.push_back(def);
    selectedTop.push_back(rootEntry);
    graphRoots.push_back(rootEntry);
  }
  if (failed(prepareSubprograms(*this, top, graphRoots)))
    return failure();
  for (auto node : selectedTop)
    if (failed(checkTree(node, seen))) {
      if (inspectionOutput && inspectionLiteralRejected) {
        inspectionGraphAvailable = true;
        snapshotDomainGraph(graphRoots);
      }
      return failure();
    }
  return success();
}

LogicalResult Consumer::known(Operation *node, bool call) {
  if (!node)
    return error(node, "missing node in E001 input");
  auto target = analyzed.lookup(id(node));
  equivalenceFailure.clear();
  // ID only chooses a candidate; all recorded attributes and the explicit
  // location must agree before using metadata from the analyzed phase.
  if (!target || !equivalentNode(node, target))
    return error(node, equivalenceFailure.empty()
                           ? "analyzed node shape differs from pristine "
                             "(E001 cannot prove identity)"
                           : equivalenceFailure);
  if (types[id(node)].size() != 1)
    return error(node,
                 "E001 requires exactly one type record for the used node");
  if (call) {
    auto &records = evidence[id(node)];
    if (records.size() != 1 || text(records.front(), "dispatch") != "direct" ||
        text(records.front(), "name") != field(node, "strings", "name"))
      return error(node,
                   "E001 requires one direct call evidence with the same name");
    if (isProducer()) {
      auto name = field(node, "strings", "name");
      StringRef expected;
      if (name == "atomic_add")
        expected = "ArrayMap#atomic_add";
      else if (name == "lookup")
        expected = "ArrayMap#lookup";
      else if (name == "update")
        expected = "ArrayMap#update";
      else if (name == "load")
        expected = "MapRef#load";
      else if (name == "xdp")
        expected = "BPF.xdp";
      if (!expected.empty() && text(records.front(), "callee") != expected)
        return error(node, "E006 call evidence callee differs from the "
                           "selected BPF operation");
    }
  }
  return success();
}

bool Consumer::equivalentNode(Operation *pristine, Operation *target,
                              unsigned depth) {
  if (depth > 64)
    return false;
  if (pristine->getLoc() != target->getLoc())
    return false;
  if (pristine->getAttrs() == target->getAttrs())
    return true;
  // v2 analysis-only metadata is not syntax or dispatch evidence. Compare
  // every other integer, and leave type/callee checks to known().
  auto version = input->getAttrOfType<IntegerAttr>("spinel_facts.version");
  auto sameIntegers = [&] {
    if (!version || version.getInt() != 2)
      return false;
    auto before = pristine->getAttrOfType<DictionaryAttr>("integers");
    auto after = target->getAttrOfType<DictionaryAttr>("integers");
    if (!before || !after)
      return false;
    NamedAttrList syntax(after);
    syntax.erase("enum_copy");
    return before == syntax.getDictionary(input.getContext());
  };
  for (auto attr : pristine->getAttrs())
    if (attr.getName() != "refs" &&
        attr.getValue() != target->getAttr(attr.getName()) &&
        !(attr.getName() == "integers" &&
          sameIntegers()))
      return false;
  if (pristine->getAttrs().size() != target->getAttrs().size())
    return false;
  auto oldRefs = pristine->getAttrOfType<DictionaryAttr>("refs");
  auto newRefs = target->getAttrOfType<DictionaryAttr>("refs");
  if (oldRefs.size() != newRefs.size())
    return false;
  for (auto attr : oldRefs) {
    auto direct = newRefs.getAs<IntegerAttr>(attr.getName());
    if (!direct)
      return false;
    int64_t old = cast<IntegerAttr>(attr.getValue()).getInt();
    if (old == direct.getInt())
      continue;
    auto inner = nodes.lookup(old);
    llvm::DenseSet<int64_t> seen;
    while (inner && text(inner, "kind") == "ParenthesesNode" &&
           seen.insert(id(inner)).second) {
      auto statements = ref(inner, "body");
      if (text(statements, "kind") != "StatementsNode")
        return false;
      auto body = array(statements, "body");
      if (body.size() != 1) {
        equivalenceFailure = "parentheses equivalence requires one statement";
        return false;
      }
      inner = body[0];
    }
    // Only the pristine side may have a transparent wrapper. Matching a
    // different terminal or changing any terminal attribute remains invalid.
    if (!inner || inner == nodes.lookup(old) || id(inner) != direct.getInt()) {
      equivalenceFailure = "parentheses equivalence terminal differs";
      return false;
    }
    auto terminal = analyzed.lookup(direct.getInt());
    if (!terminal || !equivalentNode(inner, terminal, depth + 1))
      return false;
  }
  return true;
}

FailureOr<int64_t> Consumer::integer(Operation *node) {
  if (!node || text(node, "kind") != "IntegerNode")
    return (void)error(node, "E001 requires an integer literal here"),
           failure();
  if (failed(known(node)))
    return failure();
  int64_t value;
  if (text(node, "literal_text").getAsInteger(10, value))
    return (void)error(node, "E001 supports decimal integer literals"),
           failure();
  auto t = types[id(node)].front()->getAttrOfType<TypeAttr>("value_type");
  if (!t || !isa<ir::IntegerType>(t.getValue()))
    return (void)error(node,
                       "integer literal has no mathematical Integer type"),
           failure();
  return value;
}

FailureOr<Value> Consumer::key(Operation *node, int64_t *literal) {
  auto value = integer(node);
  if (failed(value))
    return failure();
  if (*value < 0 || *value >= entries)
    return (void)error(node,
                       "E001 array key must be in the declared constant range"),
           failure();
  if (literal)
    *literal = *value;
  return arith::ConstantIntOp::create(builder, outputLoc(node), *value, 32)
      .getResult();
}

LogicalResult Consumer::mapCall(Operation *node) {
  if (failed(known(node, true)))
    return failure();
  auto receiver = constant(ref(node, "receiver"));
  auto found = llvm::find_if(maps, [&](auto &m) { return m.name == receiver; });
  if (found == maps.end())
    return error(node, "call receiver is not a declared map");
  mapName = found->name;
  entries = found->entries;
  mapValue = found->value;
  found->used = true;
  usedMap = true;
  return success();
}

LogicalResult Consumer::body(Operation *statements, StringRef borrowedName,
                             Value borrowed, int64_t borrowedKey,
                             unsigned depth) {
  if (!statements || text(statements, "kind") != "StatementsNode" || depth > 16)
    return error(statements, "unsupported statement block in E001");
  auto list = array(statements, "body");
  for (size_t i = 0; i < list.size(); ++i) {
    auto node = list[i];
    if (skipRejectedSubprogramStatement(*this, node))
      continue;
    if (recoverySkipped.count(id(node)))
      continue;
    auto kind = text(node, "kind");
    auto name = field(node, "strings", "name");
    if (kind == "CallNode" && name == "atomic_add") {
      if (failed(mapCall(node)))
        return failure();
      auto as = args(node);
      if (as.size() != 2)
        return error(node, "atomic_add requires two arguments");
      auto k = key(as[0]);
      auto delta = integer(as[1]);
      if (failed(k) || failed(delta))
        return failure();
      if (*delta < 0)
        return diagnostic(as[1], "SB014", "SemanticGap",
                          "the delta literal " + std::to_string(*delta) +
                              " is outside [0, 18446744073709551615] (u64 on "
                              "the eBPF side; Ruby would not wrap it)");
      auto value =
          arith::ConstantIntOp::create(builder, outputLoc(as[1]), *delta, 64);
      ebpf::MapAtomicAddOp::create(builder, outputLoc(node), mapValue, *k,
                                   value);
    } else if (kind == "LocalVariableWriteNode" && !borrowed) {
      auto call = ref(node, "value");
      if (!call || text(call, "kind") != "CallNode" ||
          field(call, "strings", "name") != "lookup" || failed(mapCall(call)))
        return error(node, "E001 local binding requires map lookup");
      auto as = args(call);
      if (as.size() != 1 || i + 1 >= list.size())
        return error(node, "lookup must be followed by its nullable if");
      auto check = list[++i];
      auto pred = ref(check, "predicate");
      if (text(check, "kind") != "IfNode" ||
          text(pred, "kind") != "LocalVariableReadNode" ||
          field(pred, "strings", "name") != name || ref(check, "subsequent"))
        return error(node,
                     "lookup requires an immediate matching if without else");
      int64_t lookupKey = -1;
      auto k = key(as[0], &lookupKey);
      if (failed(k))
        return failure();
      auto lookup = ebpf::MapLookupOp::create(
          builder, outputLoc(node),
          ebpf::MaybeRefType::get(ctx, builder.getI64Type()), mapValue, *k);
      auto present = ebpf::RefCheckOp::create(builder, outputLoc(node),
                                              TypeRange{}, lookup.getResult());
      OpBuilder::InsertionGuard guard(builder);
      auto *yes = new Block();
      present.getPresentRegion().push_back(yes);
      auto ptr =
          yes->addArgument(ebpf::BorrowedType::get(ctx, builder.getI64Type()),
                           builder.getUnknownLoc());
      builder.setInsertionPointToStart(yes);
      if (failed(
              body(ref(check, "statements"), name, ptr, lookupKey, depth + 1)))
        return failure();
      ebpf::YieldOp::create(builder, outputLoc(check), ValueRange{});
      auto *no = new Block();
      present.getAbsentRegion().push_back(no);
      builder.setInsertionPointToStart(no);
      ebpf::YieldOp::create(builder, outputLoc(check), ValueRange{});
    } else if (kind == "CallNode" && name == "update" && borrowed) {
      if (failed(mapCall(node)))
        return failure();
      auto as = args(node);
      if (as.size() != 2)
        return error(node, "update requires two arguments");
      auto load = as[1];
      auto recv = ref(load, "receiver");
      if (text(load, "kind") != "CallNode" ||
          field(load, "strings", "name") != "load" ||
          text(recv, "kind") != "LocalVariableReadNode" ||
          field(recv, "strings", "name") != borrowedName ||
          !args(load).empty() || failed(known(load, true)))
        return error(node, "E001 update value requires the checked ref load");
      int64_t storeKey = -1;
      auto k = key(as[0], &storeKey);
      if (failed(k))
        return failure();
      if (storeKey == borrowedKey)
        return diagnostic(
            node, "SB019", "SharedReadModifyWrite",
            "`" + mapName +
                ".update` stores a value read from the same map (`" +
                borrowedName.str() +
                ".load`) — concurrent CPUs lose updates; use `" + mapName +
                ".atomic_add` (keys must be different literals to accept "
                "this form) (P002 §1.4)");
      auto value = ebpf::RefLoadOp::create(
          builder, outputLoc(load), builder.getI64Type(), borrowed, false);
      ebpf::MapUpdateOp::create(builder, outputLoc(node), mapValue, *k,
                                value.getResult());
    } else if (constant(node) == "BPF::XDP_PASS" && !borrowed &&
               i + 1 == list.size()) {
      ebpf::VerdictOp::create(builder, outputLoc(node), "pass");
    } else {
      return error(node,
                   "statement is outside E001 handwritten xdpcount support");
    }
  }
  return success();
}

range::MapType Consumer::rangeMap(size_t index) {
  auto &m = maps[index];
  return {m.name, m.bits, m.isSigned, uint64_t(m.entries)};
}

LogicalResult Consumer::rangeFailure(llvm::Error failure, Operation *node) {
  return error(node, "range evidence unavailable: " +
                         llvm::toString(std::move(failure)));
}

LogicalResult Consumer::issue(const range::RangeIssue &i) {
  if (!i.diagnosticName.empty())
    return recordDiagnostic(nodes.lookup(i.node), i.code, i.diagnosticName,
                             i.message, i.unknown, i.diagnosticPath);
  return diagnostic(nodes.lookup(i.node), i.code,
                    i.code == "SB020" ? "KeyOutOfRange" : "SemanticGap",
                    i.message, true);
}

LogicalResult Consumer::checked(range::Check check, Operation *node) {
  if (!check)
    return rangeFailure(check.takeError(), node);
  if (*check)
    return issue(**check);
  return success();
}

FailureOr<Expr> Consumer::outcome(Expr result,
                                  llvm::Expected<range::RangeOutcome> value) {
  if (!value)
    return (void)rangeFailure(value.takeError(), result->node), failure();
  if (value->issue)
    return (void)issue(*value->issue), failure();
  result->range = value->value;
  result->divMode = value->divMode;
  return result;
}

bool Consumer::hasMapOperation(Operation *node) {
  llvm::DenseSet<int64_t> visited;
  auto walk = [&](auto &&self, Operation *n) -> bool {
    if (!n || !visited.insert(id(n)).second)
      return false;
    if (text(n, "kind") == "CallNode") {
      auto name = field(n, "strings", "name");
      if (name == "atomic_add" || name == "update" || name == "lookup" ||
          name == "insert" || name == "replace" || name == "delete" ||
          name == "add_or_init")
        return true;
    }
    for (auto attr : n->getAttrOfType<DictionaryAttr>("refs"))
      if (self(self, nodes.lookup(cast<IntegerAttr>(attr.getValue()).getInt())))
        return true;
    for (auto attr : n->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto number : cast<ArrayAttr>(attr.getValue()))
        if (self(self, nodes.lookup(cast<IntegerAttr>(number).getInt())))
          return true;
    return false;
  };
  return walk(walk, node);
}

FailureOr<Expr> Consumer::scalar(Operation *node) {
  if (!node)
    return (void)error(node, "missing scalar expression"), failure();
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  auto kind = text(node, "kind");
  auto extension = dispatchExpression(kind, node);
  if (extension.state == Disposition::Error)
    return failure();
  if (extension.state == Disposition::Handled)
    return *extension.value;
  if (failed(checkScalarShape(node))) return failure();
  if (kind == "ParenthesesNode") {
    auto list = array(ref(node, "body"), "body");
    if (list.size() != 1)
      return (void)error(node,
                         "parentheses equivalence requires one statement"),
             failure();
    return scalar(list[0]);
  }
  if (kind == "CallNode") for (const auto &check : registry.rejectOnlyScalarChecks) {
    auto result = check(*this, node);
    if (result.state == Disposition::Error) return failure();
    if (result.state == Disposition::Handled)
      return (void)diagnostic(node, "SB017", "InternalError",
          "reject-only scalar check returned Handled", true), failure();
  }
  if ((kind == "IntegerNode" || kind == "LocalVariableReadNode" ||
       kind == "CallNode") && failed(typed(node)))
    return failure();
  bool checkedOperator = false;
  if (kind == "CallNode") for (const auto &check : registry.operatorChecks) {
    auto result = check(*this, node);
    if (result.state == Disposition::Error) return failure();
    if (result.state == Disposition::Handled) { checkedOperator = true; break; }
  }
  if (failed(known(node, kind == "CallNode" && !checkedOperator)))
    return failure();
  if (kind == "IntegerNode") {
    e->kind = "literal";
    auto decimal = text(node, "literal_decimal");
    if (decimal.getAsInteger(10, e->literal))
      return (void)error(node, "literal has no supported exact decimal value"),
             failure();
    return outcome(e,
                   range::literal(math::Integer::from(e->literal), {id(node)}));
  }
  if (kind == "TrueNode" || kind == "FalseNode") {
    e->kind = "bool";
    e->literal = kind == "TrueNode";
    e->range.isBool = true;
    return e;
  }
  if (kind == "LocalVariableReadNode") {
    e->name = field(node, "strings", "name").str();
    auto found = locals.find(e->name);
    if (found == locals.end()) {
      if (borrows.count(e->name))
        return (void)diagnostic(node, "SB005", "RefCheckShape",
                                "`" + e->name + "` may be read only as `if " +
                                    e->name + "` and as `" + e->name +
                                    ".load` / `" + e->name +
                                    ".atomic_add(d)` inside it",
                                true),
               failure();
      return (void)error(node, "unknown scalar local " + e->name), failure();
    }
    e->kind = "local";
    e->range = range::asLocal(found->second.expr->range);
    e->reads = found->second.expr->reads;
    return e;
  }
  if (kind == "ParenthesesNode") {
    auto list = array(ref(node, "body"), "body");
    if (list.size() != 1)
      return (void)error(node, "scalar parentheses require one expression"),
             failure();
    return scalar(list[0]);
  }
  if (kind == "AndNode" || kind == "OrNode") {
    e->kind = kind == "AndNode" ? "and" : "or";
    if (hasMapOperation(ref(node, "right")))
      return (void)diagnostic(
                 node, "SB018", "LogicalSideEffect",
                 "the right operand of `" +
                     std::string(kind == "AndNode" ? "&&" : "||") +
                     "` calls a map operation — Ruby may skip it "
                     "(short-circuit); move it into its own statement (P002 "
                     "§1.2)",
                 true),
             failure();
    auto left = scalar(ref(node, "left"));
    auto right = scalar(ref(node, "right"));
    if (failed(left) || failed(right))
      return failure();
    if (!(*left)->range.isBool || !(*right)->range.isBool)
      return (void)diagnostic(
                 node, "SB005", "RefCheckShape",
                 "the condition is typed \"Integer\" — conditions must be "
                 "bool (Ruby treats 0 as true and nil as false, BPF does "
                 "not; compare explicitly, e.g. `x != 0`) (P002 §1.2)",
                 true),
             failure();
    e->args = {*left, *right};
    e->range.isBool = true;
    return e;
  }
  if (kind == "IfNode") {
    auto yes = array(ref(node, "statements"), "body");
    auto no = array(ref(ref(node, "subsequent"), "statements"), "body");
    if (yes.size() != 1 || no.size() != 1)
      return (void)error(
                 node,
                 "scalar conditional requires one expression in each arm"),
             failure();
    auto condition = scalar(ref(node, "predicate"));
    auto a = scalar(yes[0]);
    auto b = scalar(no[0]);
    if (failed(condition) || failed(a) || failed(b))
      return failure();
    if (!(*condition)->range.isBool || (*a)->range.isBool != (*b)->range.isBool)
      return (void)error(node, "conditional scalar types differ"), failure();
    e->kind = "select";
    e->args = {*condition, *a, *b};
    e->range = (*a)->range;
    if (!e->range.isBool) {
      auto joined =
          range::joinEnvironment({{"v", (*a)->range}}, {{"v", (*b)->range}});
      if (!joined)
        return (void)rangeFailure(joined.takeError(), node), failure();
      e->range = joined->at("v");
    }
    e->reads = (*a)->reads;
    e->reads.insert(e->reads.end(), (*b)->reads.begin(), (*b)->reads.end());
    return e;
  }
  if (kind != "CallNode")
    return (void)error(node, "unsupported scalar node " + kind.str()),
           failure();
  auto name = field(node, "strings", "name");
  auto receiver = ref(node, "receiver");
  auto as = args(node);
  if (name == "load" && text(receiver, "kind") == "LocalVariableReadNode" &&
      as.empty()) {
    e->name = field(receiver, "strings", "name").str();
    auto found = borrows.find(e->name);
    if (found == borrows.end())
      return (void)diagnostic(node, "SB005", "RefCheckShape",
                              "`" + e->name + "` may be read only as `if " +
                                  e->name + "` and as `" + e->name +
                                  ".load` / `" + e->name +
                                  ".atomic_add(d)` inside it",
                              true),
             failure();
    e->kind = "load";
    e->map = found->second.map;
    auto &m = maps[e->map];
    math::Interval iv =
        m.bits == 32
            ? math::Interval{math::Integer::from(m.isSigned ? int64_t(INT32_MIN)
                                                            : 0),
                             math::Integer::from(m.isSigned
                                                     ? int64_t(INT32_MAX)
                                                     : int64_t(UINT32_MAX))}
            : math::Interval::fullI64();
    if (m.bits == 64 && !m.isSigned) {
      auto max = math::Integer::parse("18446744073709551615");
      if (!max)
        return (void)rangeFailure(max.takeError(), node), failure();
      iv = {math::Integer::from(0), *max};
    }
    e->range = {math::MathInterval(iv), false, m.bits == 64 && !m.isSigned,
                range::Form::Load};
    e->reads.push_back({e->map, found->second.key, e->name});
    return e;
  }
  if (!text(evidence[id(node)].front(), "callee").empty())
    return (void)diagnostic(node, "SB009", "OperatorRedefined",
                            "builtin operator has a user callee"),
           failure();
  auto left = scalar(receiver);
  if (failed(left))
    return failure();
  e->op = name.str();
  if (as.empty() && (name == "-@" || name == "~" || name == "!")) {
    e->args = {*left};
    if (name == "!") {
      if (!(*left)->range.isBool)
        return (void)error(node, "logical negation requires bool"), failure();
      e->kind = "not";
      e->range.isBool = true;
      return e;
    }
    e->kind = "unary";
    e->reads = (*left)->reads;
    return outcome(e, range::transferUnary(e->op, (*left)->range, {id(node)}));
  }
  if (as.size() != 1)
    return (void)error(node, "scalar operator requires one argument"),
           failure();
  auto right = scalar(as[0]);
  if (failed(right))
    return failure();
  e->args = {*left, *right};
  e->reads = (*left)->reads;
  e->reads.insert(e->reads.end(), (*right)->reads.begin(),
                  (*right)->reads.end());
  if (name == "==" || name == "!=" || name == "<" || name == "<=" ||
      name == ">" || name == ">=") {
    if (failed(checked(range::checkIntegerUse((*left)->range, {id(receiver)}),
                       node)) ||
        failed(checked(range::checkIntegerUse((*right)->range, {id(as[0])}),
                       node)))
      return failure();
    e->kind = "compare";
    e->range.isBool = true;
    return e;
  }
  if ((name == "/" || name == "%" || name == "<<" || name == ">>") &&
      (*right)->kind != "literal") {
    std::string what = (name == "/" || name == "%")
                           ? "the divisor of `" + name.str() + "`"
                           : "the shift count of `" + name.str() + "`";
    return (void)diagnostic(as[0], "SB006", "NonConstant",
                            what + " must be an integer literal (P002 §1.1)",
                            true),
           failure();
  }
  e->kind = "binary";
  return outcome(e,
                 range::transferBinary(e->op, (*left)->range, (*right)->range,
                                       {id(node), id(as[0])}));
}

Value Consumer::emitScalar(const Expr &e) {
  if (!e || probing || blocking)
    return {};
  auto extension = dispatchEmitter(e->kind, e);
  if (extension.state == Disposition::Error)
    return {};
  if (extension.state == Disposition::Handled)
    return *extension.value;
  auto loc = outputLoc(e->node);
  auto i64 = builder.getI64Type();
  auto cst = [&](int64_t v) -> Value {
    return arith::ConstantIntOp::create(builder, loc, v, 64);
  };
  if (e->kind == "literal")
    return cst(e->literal);
  if (e->kind == "bool")
    return arith::ConstantIntOp::create(builder, loc, e->literal, 1);
  if (e->kind == "local")
    return locals.at(e->name).value;
  if (e->kind == "load") {
    auto &m = maps[e->map];
    Value raw =
        ebpf::RefLoadOp::create(builder, loc, builder.getIntegerType(m.bits),
                                borrows.at(e->name).value, false);
    if (m.bits == 64)
      return raw;
    return m.isSigned
               ? arith::ExtSIOp::create(builder, loc, i64, raw).getResult()
               : arith::ExtUIOp::create(builder, loc, i64, raw).getResult();
  }
  unsigned arity = e->kind == "not" || e->kind == "unary" ? 1
                   : e->kind == "select"                  ? 3
                                                          : 2;
  if ((e->kind != "not" && e->kind != "unary" && e->kind != "select" &&
       e->kind != "binary" && e->kind != "compare" && e->kind != "and" &&
       e->kind != "or") ||
      e->args.size() != arity) {
    (void)error(
        e->node,
        "checked expression has no registered emitter or invalid arity");
    return {};
  }
  Value a = emitScalar(e->args[0]);
  if (!a)
    return {};
  if (e->kind == "not") {
    Value one = arith::ConstantIntOp::create(builder, loc, 1, 1);
    return arith::XOrIOp::create(builder, loc, a, one);
  }
  if (e->kind == "unary") {
    if (e->op == "-@")
      return arith::SubIOp::create(builder, loc, cst(0), a);
    return arith::XOrIOp::create(builder, loc, a, cst(-1));
  }
  Value b = emitScalar(e->args[1]);
  if (!b)
    return {};
  if (e->kind == "select") {
    Value c = emitScalar(e->args[2]);
    return c ? arith::SelectOp::create(builder, loc, a, b, c).getResult()
             : Value{};
  }
  if (e->kind == "compare") {
    auto pred = llvm::StringSwitch<arith::CmpIPredicate>(e->op)
                    .Case("==", arith::CmpIPredicate::eq)
                    .Case("!=", arith::CmpIPredicate::ne)
                    .Case("<", arith::CmpIPredicate::slt)
                    .Case("<=", arith::CmpIPredicate::sle)
                    .Case(">", arith::CmpIPredicate::sgt)
                    .Default(arith::CmpIPredicate::sge);
    return arith::CmpIOp::create(builder, loc, pred, a, b);
  }
  if (e->kind == "and" || e->op == "&")
    return arith::AndIOp::create(builder, loc, a, b);
  if (e->kind == "or" || e->op == "|")
    return arith::OrIOp::create(builder, loc, a, b);
  if (e->op == "+")
    return arith::AddIOp::create(builder, loc, a, b);
  if (e->op == "-")
    return arith::SubIOp::create(builder, loc, a, b);
  if (e->op == "*")
    return arith::MulIOp::create(builder, loc, a, b);
  if (e->op == "^")
    return arith::XOrIOp::create(builder, loc, a, b);
  if (e->op == "<<")
    return arith::ShLIOp::create(builder, loc, a, b);
  if (e->op == ">>")
    return e->args[0]->range.wide
               ? arith::ShRUIOp::create(builder, loc, a, b).getResult()
               : arith::ShRSIOp::create(builder, loc, a, b).getResult();
  if (e->op == "/")
    return e->divMode == "u"
               ? arith::DivUIOp::create(builder, loc, a, b).getResult()
               : arith::FloorDivSIOp::create(builder, loc, a, b).getResult();
  if (e->divMode == "u")
    return arith::RemUIOp::create(builder, loc, a, b);
  Value r = arith::RemSIOp::create(builder, loc, a, b), zero = cst(0);
  Value nonzero =
      arith::CmpIOp::create(builder, loc, arith::CmpIPredicate::ne, r, zero);
  Value wrong =
      arith::CmpIOp::create(builder, loc,
                            e->args[1]->literal < 0 ? arith::CmpIPredicate::sgt
                                                    : arith::CmpIPredicate::slt,
                            r, zero);
  Value fix = arith::AndIOp::create(builder, loc, nonzero, wrong);
  Value sum = arith::AddIOp::create(builder, loc, r, b);
  return arith::SelectOp::create(builder, loc, fix, sum, r);
}

Value Consumer::scalarKey(const Expr &e) {
  if (e->kind == "literal")
    return arith::ConstantIntOp::create(builder, outputLoc(e->node), e->literal,
                                        32);
  Value v = emitScalar(e);
  return v ? arith::TruncIOp::create(builder, outputLoc(e->node),
                                     builder.getI32Type(), v)
                 .getResult()
           : Value{};
}

Value Consumer::scalarStore(const Expr &e, size_t map) {
  auto bits = maps[map].bits;
  auto specialized = dispatchEmitter(e->kind + ".i" + std::to_string(bits), e);
  if (specialized.state == Disposition::Error) return {};
  if (specialized.state == Disposition::Handled) return *specialized.value;
  if (e->kind == "literal")
    return arith::ConstantIntOp::create(builder, outputLoc(e->node), e->literal,
                                        bits);
  if (e->kind == "load" && maps[e->map].bits == bits)
    return ebpf::RefLoadOp::create(builder, outputLoc(e->node),
                                   builder.getIntegerType(bits),
                                   borrows.at(e->name).value, false);
  Value v = emitScalar(e);
  if (!v)
    return {};
  return bits == 64 ? v
                    : arith::TruncIOp::create(builder, outputLoc(e->node),
                                              builder.getI32Type(), v)
                          .getResult();
}

// Check read origins before evaluating the numeric value expression.
std::vector<ReadOrigin> Consumer::origins(Operation *node) {
  if (!node)
    return {};
  if (isSubprogramCall(*this, node))
    return {{0, std::nullopt, {}, ReadOrigin::Domain::CallResult, id(node)}};
  if (text(node, "kind") == "LocalVariableReadNode") {
    auto found = locals.find(field(node, "strings", "name").str());
    return found == locals.end() ? std::vector<ReadOrigin>{}
                                 : found->second.expr->reads;
  }
  if (text(node, "kind") == "CallNode" &&
      field(node, "strings", "name") == "load") {
    auto name = field(ref(node, "receiver"), "strings", "name").str();
    auto found = borrows.find(name);
    if (found != borrows.end())
      return {{found->second.map, found->second.key, name}};
  }
  std::vector<ReadOrigin> result;
  for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
    auto child = nodes.lookup(cast<IntegerAttr>(attr.getValue()).getInt());
    auto more = origins(child);
    result.insert(result.end(), more.begin(), more.end());
  }
  for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
    for (auto number : cast<ArrayAttr>(attr.getValue())) {
      auto more = origins(nodes.lookup(cast<IntegerAttr>(number).getInt()));
      result.insert(result.end(), more.begin(), more.end());
    }
  return result;
}

LogicalResult Consumer::rmwFirst(Operation *call, Operation *keyNode,
                                 Operation *value, size_t map, bool update) {
  std::optional<int64_t> literalKey;
  int64_t keyValue;
  if (keyNode && text(keyNode, "kind") == "IntegerNode" &&
      !text(keyNode, "literal_decimal").getAsInteger(10, keyValue))
    literalKey = keyValue;
  auto reads = origins(value);
  if (failed(noteSubprogramWrite(*this, call,
          {map, literalKey, {}, ReadOrigin::Domain::Map}, reads))) return failure();
  for (const auto &read : reads) {
    if (read.domain != ReadOrigin::Domain::Map)
      continue;
    if (rmwExempt(read, map))
      continue;
    if (read.map != map)
      continue;
    if (literalKey && read.key && *literalKey != *read.key)
      continue;
    auto &m = maps[map];
    if (update)
      return diagnostic(
          call, "SB019", "SharedReadModifyWrite",
          "`" + m.name + ".update` stores a value read from the same map (`" +
              read.ref + ".load`) — concurrent CPUs lose updates; use `" +
              m.name +
              ".atomic_add` (keys must be different literals to accept this "
              "form) (P002 §1.4)",
          true);
    return diagnostic(
        call, "SB019", "SharedReadModifyWrite",
        "`" + m.name + ".atomic_add` adds a value read from the same entry (`" +
            read.ref +
            ".load`) — concurrent CPUs interleave the read and the add; use "
            "a delta that does not read the map (keys must be different "
            "literals to accept this form) (P015 E063)",
        true);
  }
  return success();
}

LogicalResult Consumer::scalarBody(Operation *statements, unsigned depth) {
  if (!statements)
    return success();
  if (depth > 32)
    return error(statements, "scalar region nesting exceeds supported depth");
  auto list = array(statements, "body");
  return scalarStatements(list, depth);
}

LogicalResult Consumer::scalarStatements(ArrayRef<Operation *> list,
                                         unsigned depth) {
  if (depth > 32)
    return error(list.empty() ? nullptr : list.front(),
                 "scalar region nesting exceeds supported depth");
  for (size_t i = 0; i < list.size(); ++i) {
    auto node = list[i];
    if (skipRejectedSubprogramStatement(*this, node))
      continue;
    if (recoverySkipped.count(id(node)))
      continue;
    auto kind = text(node, "kind");
    auto name = field(node, "strings", "name").str();
    auto extension = dispatchStatement(kind, list, i, depth);
    if (extension.state == Disposition::Error)
      return failure();
    if (extension.state == Disposition::Handled) {
      i += extension.value->consumed - 1;
      continue;
    }
    if (kind == "LocalVariableWriteNode") {
      auto value = ref(node, "value");
      if (text(value, "kind") == "CallNode" &&
          field(value, "strings", "name") == "lookup") {
        if (lookupBindingNames[activeDef].count(name))
          return diagnostic(node, "SB005", "RefCheckShape", "`" + name +
              "` is assigned twice — a lookup result is bound once", true);
        auto found = llvm::find_if(maps, [&](auto &m) {
          return m.name == constant(ref(value, "receiver"));
        });
        if (found == maps.end())
          return error(value, "map receiver is not declared");
        size_t map = found - maps.begin();
        if (found->className == "ArrayMap" && failed(knownMap(value, map)))
          return failure();
        auto as = args(value);
        if ((found->className == "ArrayMap" && as.size() != 1) ||
            i + 1 >= list.size())
          return error(node, "lookup requires its immediate present check");
        auto check = list[++i];
        auto pred = ref(check, "predicate");
        if (text(check, "kind") != "IfNode" ||
            text(pred, "kind") != "LocalVariableReadNode" ||
            field(pred, "strings", "name") != name)
          return diagnostic(
              node, "SB005", "RefCheckShape",
              "`" + name + " = " + found->name +
                  ".lookup(…)` must be followed immediately by `if " + name +
                  "` (the present / absent check)",
              true);
        if (text(ref(check, "subsequent"), "kind") == "IfNode")
          return diagnostic(ref(check, "subsequent"), "SB005", "RefCheckShape",
                            "`elsif` is not accepted after `if " + name +
                                "` (P001 §3.4)",
                            true);
        if (found->className != "ArrayMap" && failed(knownMap(value, map)))
          return failure();
        auto k = checkedMapKey(map, as, value);
        if (failed(k))
          return failure();
        Value keyValue = emitMapKey(*k, map);
        if (!keyValue)
          return failure();
        if (!probing) lookupBindingNames[activeDef].insert(name);
        auto lookup = ebpf::MapLookupOp::create(
            builder, outputLoc(node),
            ebpf::MaybeRefType::get(
                ctx, found->valueType ? found->valueType
                                      : builder.getIntegerType(found->bits)),
            found->value, keyValue);
        // Preserve only the exact direct integer key evidence. A local with a
        // singleton interval or a record key is not a literal key proof.
        Expr literalKey = *k;
        if (literalKey->kind == "e017.hkey" && literalKey->map == map &&
            literalKey->args.size() == 1)
          literalKey = literalKey->args.front();
        std::optional<int64_t> key = literalKey->kind == "literal"
                                         ? std::optional<int64_t>(literalKey->literal)
                                         : std::nullopt;
        usedMap = true;
        if (failed(scalarBranch(check, lookup, {}, Borrow{map, key, {}}, name,
                                depth, node)))
          return failure();
      } else {
        const size_t beforeDiagnostics = runDiagnostics ? runDiagnostics->size() : 0;
        auto e = scalar(value);
        if (failed(e)) {
          diagnoseRejectedTracingStringLocal(*this, list, i, depth, beforeDiagnostics);
          return failure();
        }
        if (!(*e)->range.isBool &&
            failed(checked(range::checkIntegerUse((*e)->range, {id(value)}),
                           value)))
          return failure();
        Value v = emitScalar(*e);
        if (!v)
          return failure();
        locals[name] = {*e, v};
      }
    } else if (kind == "LocalVariableOperatorWriteNode") {
      auto found = locals.find(name);
      if (found == locals.end())
        return error(node, "operator assignment needs a scalar local");
      auto rhs = scalar(ref(node, "value"));
      if (failed(rhs))
        return failure();
      auto left = std::make_shared<ScalarExpr>(*found->second.expr);
      left->node = node;
      left->kind = "local";
      left->name = name;
      left->range = range::asLocal(left->range);
      auto e = std::make_shared<ScalarExpr>();
      e->node = node;
      e->kind = "binary";
      e->op = field(node, "strings", "binary_operator").str();
      e->args = {left, *rhs};
      e->reads = left->reads;
      e->reads.insert(e->reads.end(), (*rhs)->reads.begin(),
                      (*rhs)->reads.end());
      auto checked =
          outcome(e, range::transferBinary(e->op, left->range, (*rhs)->range,
                                           {id(node), id((*rhs)->node)}));
      if (failed(checked))
        return failure();
      Value v = emitScalar(*checked);
      if (!v)
        return failure();
      locals[name] = {*checked, v};
    } else if (kind == "IfNode" || kind == "UnlessNode") {
      auto condition = scalar(ref(node, "predicate"));
      if (failed(condition))
        return failure();
      if (!(*condition)->range.isBool)
        return diagnostic(
            ref(node, "predicate"), "SB005", "RefCheckShape",
            "the condition is typed \"Integer\" — conditions must be bool "
            "(Ruby treats 0 as true and nil as false, BPF does not; compare "
            "explicitly, e.g. `x != 0`) (P002 §1.2)",
            true);
      Value value = emitScalar(*condition);
      if (!value)
        return failure();
      if (kind == "UnlessNode")
        value = arith::XOrIOp::create(
            builder, outputLoc((*condition)->node), value,
            arith::ConstantIntOp::create(builder, outputLoc((*condition)->node),
                                         1, 1));
      if (failed(scalarBranch(node, value, *condition, std::nullopt, {}, depth)))
        return failure();
    } else if (kind == "CallNode" &&
               (name == "update" || name == "atomic_add")) {
      auto found = llvm::find_if(maps, [&](auto &m) {
        return m.name == constant(ref(node, "receiver"));
      });
      if (found == maps.end())
        return error(node, "map receiver is not declared");
      if (failed(knownMap(node, found - maps.begin())))
        return failure();
      size_t map = found - maps.begin();
      auto as = args(node);
      if (as.size() != 2)
        return error(node, "map store requires two arguments");
#ifndef SPINEL_E010_TEST_RMW_AFTER_RANGE
      if (failed(rmwFirst(node, as[0], as[1], map, name == "update")))
        return failure();
#endif
      auto k = checkedMapKey(map, llvm::ArrayRef<Operation *>(as).take_front(1),
                             node);
      if (failed(k))
        return failure();
      auto v = scalar(as[1]);
      if (failed(v))
        return failure();
      if ((*v)->range.isBool)
        return diagnostic(as[1], "SB001", "UnsupportedConstruct",
            std::string("a bool cannot be stored in a map (") +
            (name == "atomic_add" ? "delta" : "value") + ")", true);
      if (failed(checked(
              range::checkStoreValue((*v)->range, rangeMap(map), {id(as[1])},
                                     name == "atomic_add" ? "delta" : "value"),
              as[1])))
        return failure();
#ifdef SPINEL_E010_TEST_RMW_AFTER_RANGE
      if (failed(rmwFirst(node, as[0], as[1], map, name == "update")))
        return failure();
#endif
      Value key = emitMapKey(*k, map), val = scalarStore(*v, map);
      if (!key || !val)
        return failure();
      if (name == "update")
        ebpf::MapUpdateOp::create(builder, outputLoc(node), found->value, key,
                                  val);
      else
        ebpf::MapAtomicAddOp::create(builder, outputLoc(node), found->value,
                                     key, val);
      usedMap = true;
    } else {
      Operation *verdict = node;
      if (kind == "ReturnNode") {
        auto as = args(node);
        if (as.size() != 1)
          return error(node, "return requires one verdict");
        verdict = as[0];
      }
      auto value = constant(verdict);
      if (i + 1 != list.size() || depth != 0 ||
          (value != "BPF::XDP_PASS" && value != "BPF::XDP_DROP" &&
           value != "BPF::XDP_TX"))
        return error(node, "statement outside scalar group A support");
      ebpf::VerdictOp::create(builder, outputLoc(node),
                              value == "BPF::XDP_PASS"   ? "pass"
                              : value == "BPF::XDP_DROP" ? "drop"
                                                         : "tx");
    }
  }
  return success();
}

LogicalResult Consumer::scalarBranch(Operation *node, Value condition,
                                     const Expr &predicate,
                                     std::optional<Borrow> borrow,
                                     const std::string &name, unsigned depth,
                                     Operation *binding) {
  ScopeGuard rollback(*this);
  if (!condition || blocking)
    return failure();
  if (!borrow && !predicate)
    return error(node, "conditional branch requires its checked predicate");
  bool positive = text(node, "kind") != "UnlessNode";
  auto pre = locals;
  auto oldBorrows = borrows;
  auto yes = std::make_unique<Block>(), no = std::make_unique<Block>();
  Locals thenEnv, elseEnv;
  auto subsequent = ref(node, "subsequent");
  {
    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(yes.get());
    if (borrow) {
      borrow->value = yes->addArgument(
          ebpf::BorrowedType::get(
              ctx, maps[borrow->map].valueType
                       ? maps[borrow->map].valueType
                       : builder.getIntegerType(maps[borrow->map].bits)),
          builder.getUnknownLoc());
      borrows[name] = *borrow;
    }
    if (predicate && failed(refineLocals(predicate, positive))) return failure();
    if (failed(scalarBody(ref(node, "statements"), depth + 1)))
      return failure();
    thenEnv = locals;
    locals = pre;
    borrows = oldBorrows;
    if (predicate && failed(refineLocals(predicate, !positive))) return failure();
    builder.setInsertionPointToStart(no.get());
    if (subsequent && text(subsequent, "kind") == "IfNode") {
      auto c = scalar(ref(subsequent, "predicate"));
      if (failed(c))
        return failure();
      if (failed(scalarBranch(subsequent, emitScalar(*c), *c, std::nullopt, {},
                              depth + 1)))
        return failure();
    } else if (failed(scalarBody(ref(subsequent, "statements"), depth + 1)))
      return failure();
    elseEnv = locals;
    locals = pre;
    borrows = oldBorrows;
  }
  std::vector<std::string> names;
  SmallVector<Type> types;
  SmallVector<Value> a, b;
  range::Environment ar, br;
  for (const auto &[n, local] : thenEnv)
    ar[n] = local.expr->range;
  for (const auto &[n, local] : elseEnv)
    br[n] = local.expr->range;
  auto joined = range::joinEnvironment(ar, br);
  if (!joined)
    return rangeFailure(joined.takeError(), node);
  for (const auto &[n, local] : thenEnv) {
    auto other = elseEnv.find(n);
    if (other == elseEnv.end() || !joined->count(n))
      continue;
    auto before = pre.find(n);
    if (before != pre.end() && local.value == before->second.value &&
        other->second.value == before->second.value)
      continue;
    names.push_back(n);
    types.push_back(local.value.getType());
    a.push_back(local.value);
    b.push_back(other->second.value);
  }
  Operation *op;
  if (borrow)
    op =
        ebpf::RefCheckOp::create(builder, outputLoc(binding), types, condition);
  else
    op = ebpf::IfOp::create(builder, outputLoc(node), types, condition);
  op->getRegion(0).push_back(yes.release());
  op->getRegion(1).push_back(no.release());
  {
    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToEnd(&op->getRegion(0).front());
    if (borrow)
      ebpf::YieldOp::create(builder, outputLoc(node), a);
    else
      ebpf::IfYieldOp::create(builder, outputLoc(node), a);
    builder.setInsertionPointToEnd(&op->getRegion(1).front());
    if (borrow)
      ebpf::YieldOp::create(builder, outputLoc(node), b);
    else
      ebpf::IfYieldOp::create(builder, outputLoc(node), b);
  }
  for (size_t i = 0; i < names.size(); ++i) {
    auto e = std::make_shared<ScalarExpr>(*thenEnv.at(names[i]).expr);
    e->range = joined->at(names[i]);
    e->range.form = range::Form::Local;
    auto &more = elseEnv.at(names[i]).expr->reads;
    e->reads.insert(e->reads.end(), more.begin(), more.end());
    locals[names[i]] = {e, op->getResult(i)};
  }
  rollback.commit();
  return success();
}

std::string Consumer::json(bool schema) {
  std::string out;
  llvm::raw_string_ostream stream(out);
  {
    llvm::json::OStream j(stream, 2);
    auto empty = [] {};
    auto writeValue = [&](StringRef key, const ExportValue &value) {
      if (value.writer) {
        j.attributeBegin(key);
        value.writer(j);
        j.attributeEnd();
      } else if (value.primitive) {
        j.attribute(key, *value.primitive);
      } else {
        (void)error(nullptr, ("export field " + key + " has no value").str());
      }
    };
    auto writeFields = [&](const ExportFields &fields) {
      for (auto &field : fields)
        writeValue(field.first, field.second);
    };
    auto extensionFields = [&](DeclarationRef declaration) {
      auto result = dispatchExport(declaration, schema);
      if (result.state == Disposition::Error)
        return true;
      if (result.state == Disposition::Declined)
        return false;
      writeFields(*result.value);
      return true;
    };
    auto intType = [&](unsigned bits, bool sign = false) {
      j.attribute("kind", "int");
      j.attribute("bits", bits);
      j.attribute("signed", sign);
      j.attribute("endianness", "little");
      j.attribute("alignment", bits / 8);
    };
    j.object([&] {
      if (schema) {
        j.attribute("version", 1);
        j.attributeObject("coverage", [&] {
          for (auto name : {"programs", "maps", "records", "telemetry"})
            j.attribute(name, "complete");
        });
        j.attributeObject("core", [&] {
          // E022: kernel_types first (schema.go:156-178), omitted unless a
          // group exports it.
          {
            auto kernelTypes = dispatchCoreExport("kernel_types", schema);
            if (kernelTypes.state == Disposition::Handled)
              writeValue("kernel_types", *kernelTypes.value);
          }
          // Go's usedRecords order (schema.go:61-79): a record's id is its
          // position here (E029 — the ring tail).
          j.attributeArray("records", [&] {
            for (size_t i : usedRecordOrder())
              j.object([&] {
                if (!extensionFields({DeclarationRef::Domain::Record, i}))
                  (void)error(records[i].node,
                              "record exporter is not registered");
              });
          });
          j.attributeArray("maps", [&] {
            for (const auto &m : maps)
              if (m.used)
                j.object([&] {
                  if (extensionFields({DeclarationRef::Domain::Map,
                                       size_t(&m - maps.data())}))
                    return;
                  if (m.kind != "array") {
                    (void)error(m.node, "map exporter is not registered");
                    return;
                  }
                  j.attribute("symbol", m.name);
                  j.attribute("kind", "array");
                  j.attributeObject("key", [&] { intType(32); });
                  j.attributeObject("value",
                                    [&] { intType(m.bits, m.isSigned); });
                  j.attribute("max_entries", m.entries);
                  j.attribute("flags", 0);
                  j.attribute("record", "");
                  j.attribute("note", "Ruby constant " + m.name);
                });
            // E029: used rings after every map (schema.go:219).
            for (size_t i = 0; i < rings.size(); ++i)
              if (rings[i].used)
                j.object([&] {
                  if (!extensionFields({DeclarationRef::Domain::Ring, i}))
                    (void)error(rings[i].node,
                                "ring exporter is not registered");
                });
          });
          // Go's schema core order (schema.go:171-177): records, maps,
          // programs, then globals only when one is used.
          j.attributeArray("programs", [&] {
            for (const auto &p : programs)
              j.object([&] {
                // E022: a group's handled export is the whole object in Go's
                // schemaProgram order; declined keeps the common five fields.
                auto custom =
                    dispatchProgramExport(size_t(&p - programs.data()), schema);
                if (custom.state == Disposition::Error)
                  return;
                if (custom.state == Disposition::Handled) {
                  writeFields(*custom.value);
                  return;
                }
                j.attribute("name", p.name);
                j.attribute("kind", p.kind);
                j.attribute("attach_target", p.attachTarget);
                j.attributeArray("maps", [&] {
                  for (auto index : p.maps)
                    j.value(maps[index].name);
                });
                j.attribute("note", "Ruby def " + p.name);
              });
          });
          if (llvm::any_of(globals, [](const auto &g) { return g.used; }))
            j.attributeArray("globals", [&] {
              for (size_t i = 0; i < globals.size(); ++i)
                if (globals[i].used)
                  j.object([&] {
                    if (!extensionFields({DeclarationRef::Domain::Global, i}))
                      (void)error(globals[i].node,
                                  "global exporter is not registered");
                  });
            });
        });
        j.attributeObject("telemetry", [&] {
          for (auto name : {"clocks", "value_maps", "bounds_sets", "signals"})
            j.attributeArray(name, empty);
        });
        j.attributeObject("extensions", empty);
      } else {
        // E022: Go's maps.json keeps records in a map[string]shape
        // (schema.go:283-330), so encoding/json writes the used records in
        // byte order of their names, before maps, and omits the key if none.
        // The same set as the schema's usedRecords (E029), keyed by name.
        std::vector<size_t> used = usedRecordOrder();
        std::stable_sort(used.begin(), used.end(), [&](size_t a, size_t b) {
          return records[a].name < records[b].name;
        });
        if (!used.empty())
          j.attributeObject("records", [&] {
            for (auto i : used) {
              j.attributeBegin(records[i].name);
              j.object([&] {
                if (!extensionFields({DeclarationRef::Domain::Record, i}))
                  (void)error(records[i].node,
                              "record exporter is not registered");
              });
              j.attributeEnd();
            }
          });
        j.attributeArray("maps", [&] {
          for (const auto &m : maps)
            if (m.used)
              j.object([&] {
                if (extensionFields({DeclarationRef::Domain::Map,
                                     size_t(&m - maps.data())}))
                  return;
                if (m.kind != "array") {
                  (void)error(m.node, "map exporter is not registered");
                  return;
                }
                j.attribute("name", m.name);
                j.attribute("kind", "array");
                j.attribute("key", "u32");
                j.attribute("value", std::string(m.isSigned ? "i" : "u") +
                                         std::to_string(m.bits));
                j.attribute("max_entries", m.entries);
              });
          // E029: used rings after every map (schema.go:321).
          for (size_t i = 0; i < rings.size(); ++i)
            if (rings[i].used)
              j.object([&] {
                if (!extensionFields({DeclarationRef::Domain::Ring, i}))
                  (void)error(rings[i].node, "ring exporter is not registered");
              });
        });
        if (llvm::any_of(globals, [](const auto &g) { return g.used; }))
          j.attributeArray("globals", [&] {
            for (size_t i = 0; i < globals.size(); ++i)
              if (globals[i].used)
                j.object([&] {
                  if (!extensionFields({DeclarationRef::Domain::Global, i}))
                    (void)error(globals[i].node,
                                "global exporter is not registered");
                });
          });
      }
    });
  }
  stream << "\n";
  return out;
}

FailureOr<Artifacts> Consumer::run() {
  if (inspectionOutput) { *inspectionOutput = {}; inspectionDomain = {}; }
  inspectionGraphAvailable = false;
  inspectionRootDefinition = nullptr;
  inspectionLiteralRejected = false;
  lookupBindingNames.clear();
  programBodyRejected = false;
  sourceAuditUnknown = false;
  rootEntries.clear();
  std::vector<PendingDiagnostic> diagnostics;
  runDiagnostics = &diagnostics;
  auto inspectDone = llvm::make_scope_exit([&] {
    if (!inspectionOutput) return;
    for (const auto &d : diagnostics)
      if (d.domain) inspectionDomain.diagnostics.push_back(*d.domain);
    finishInspection(false);
  });
  auto flush = llvm::make_scope_exit([&] {
    runDiagnostics = nullptr;
    if (declarationRecovery || sourceAuditUnknown)
      std::stable_sort(diagnostics.begin(), diagnostics.end(),
                       [](const auto &a, const auto &b) {
                         return std::tie(a.line, a.col) < std::tie(b.line, b.col);
                       });
    std::set<std::string> rejected;
    const bool hasSourceDynamic = llvm::any_of(diagnostics, [](const auto &d) {
      return d.verdict != DiagnosticVerdict::Conditional && d.code == "SB016";
    });
    for (const auto &d : diagnostics) {
      bool isRejected = d.verdict == DiagnosticVerdict::Rejected;
      // Go analyze.go:708 -> record.go:811: the semantic SB009 still stops
      // this root, but is redundant beside the actual source-wide SB016.
      if (hasSourceDynamic && isRejected && d.code == "SB009") continue;
      // oneReasonEach keys blocking reasons by position and SB code; its
      // conditional lines remain distinct even at an identical position.
      auto reasonKey = d.text.substr(0, d.text.find(" ("));
      if (declarationRecovery && isRejected && !rejected.insert(reasonKey).second)
        continue;
      llvm::errs() << d.text << "\n";
      if (d.verdict != DiagnosticVerdict::Conditional)
        ++printedRejections;
    }
  });
  if (!registry.valid || blocking)
    return (void)error(nullptr, "invalid consumer registry"), failure();
  Operation *root = nullptr;
  for (auto table : input.getOps<ir::TableOp>())
    if (text(table, "phase") == "pristine")
      root =
          nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  if (!root)
    return failure();
  if (failed(select(root)))
    return failure();
  if (text(root, "kind") != "ProgramNode")
    return (void)error(root, "E001 requires a ProgramNode root"), failure();
  Operation *def = nullptr, *entry = nullptr;
  std::map<std::string, Operation *> defs;
  std::set<std::string> declaredRoots;
  for (auto node : selectedTop) {
    auto beforeDiagnostics = diagnostics.size();
    bool duplicateRootRejected = false;
    auto consumeTop = [&]() -> LogicalResult {
    auto declaration = dispatchDeclaration(node);
    if (declaration.state == Disposition::Error)
      return failure();
    if (declaration.state == Disposition::Handled)
      return success();
    if (text(node, "kind") == "ConstantWriteNode") {
      auto declaredName = field(node, "strings", "name").str();
      if (llvm::any_of(maps, [&](auto &m) { return m.name == declaredName; }))
        return (void)diagnostic(node, "SB013", "MapDeclShape",
                                "constant " + declaredName +
                                    " is assigned twice"),
               failure();
      auto call = ref(node, "value");
      auto as = args(call);
      if (text(call, "kind") != "CallNode" ||
          field(call, "strings", "name") != "new" ||
          constant(ref(call, "receiver")) != "BPF::ArrayMap" ||
          as.size() != 3 || text(as[0], "kind") != "StringNode" ||
          text(as[1], "kind") != "SymbolNode" ||
          (spelling(as[1], true) != "u64" && spelling(as[1], true) != "i64" &&
           spelling(as[1], true) != "u32" && spelling(as[1], true) != "i32") ||
          failed(known(call, true)))
        return (void)error(node,
                           "E001 supports an ArrayMap u64 literal declaration"),
               failure();
      mapName = field(node, "strings", "name").str();
      if (mapName.empty() || spelling(as[0], false) != mapName)
        return (void)diagnostic(
                   as[0], "SB013", "MapDeclShape",
                   "the map name \"" + spelling(as[0], false).str() +
                       "\" differs from its constant " + mapName +
                       " — both sides look the map up by this name, so they "
                       "must be the same"),
               failure();
      auto max = integer(as[2]);
      if (failed(max))
        return failure();
      entries = *max;
      if (entries < 1 || uint64_t(entries) > UINT32_MAX)
        return (void)error(node, "map max_entries must fit a positive u32"),
               failure();
      auto valueType = spelling(as[1], true);
      MapDecl declaration{};
      declaration.node = node;
      declaration.name = mapName;
      declaration.bits = valueType.ends_with("32") ? 32u : 64u;
      declaration.isSigned = valueType.starts_with("i");
      declaration.entries = entries;
      maps.push_back(std::move(declaration));
      declarationOrder.push_back(
          {DeclarationRef::Domain::Map, maps.size() - 1});
    } else if (text(node, "kind") == "DefNode") {
      auto name = field(node, "strings", "name").str();
      if (!defs.emplace(name, node).second)
        return (void)error(node, "duplicate method declaration"), failure();
    } else if (text(node, "kind") == "CallNode" &&
               (field(node, "strings", "name") == "xdp" ||
                llvm::any_of(registry.roots,
                             [&](const auto &h) {
                               return h.first == field(node, "strings", "name");
                             })) &&
               constant(ref(node, "receiver")) == "BPF") {
      auto rootArgs = args(node);
      auto name = spelling(rootArgs[0], true);
      if (!declaredRoots.insert(name.str()).second) {
        duplicateRootRejected = true;
        return diagnostic(node, "SB008", "ProgramShape",
                          "`BPF.xdp :" + name.str() + "` is declared twice");
      }
      rootEntries.push_back(node);
    } else {
      return (void)error(node, "unsupported top-level declaration in E001"),
             failure();
    }
    return success();
    };
    if (failed(consumeTop())) {
      // A repeated valid XDP declaration is still rejected. Only its exact
      // diagnosed SB008 permits the first root and unused declarations to finish.
      if (duplicateRootRejected) {
        if (diagnostics.size() == beforeDiagnostics ||
            diagnostics.back().rejectedCode != "SB008") return failure();
        declarationRecovery = true;
        blocking = false;
        continue;
      }
      // scanTop continues only after a real semantic data rejection. Missing
      // facts / internal unsupported shapes remain blocking, not fallback.
      bool data = text(node, "kind") == "ConstantWriteNode" ||
                  (text(node, "kind") == "CallNode" &&
                   constant(ref(node, "receiver")) == "BPF" &&
                   (field(node, "strings", "name") == "record" ||
                    field(node, "strings", "name") == "kernel_type"));
      bool diagnosedDependency = declarationRecovery &&
          dependentDeclarationErrors.erase(id(node)) &&
          llvm::any_of(diagnostics, [](const auto &d) {
            return StringRef(d.text).contains(": rejected ");
          });
      if (!data || (diagnostics.size() == beforeDiagnostics && !diagnosedDependency) ||
          StringRef(diagnostics.back().text).contains("rejected SB001"))
        return failure();
#ifdef SPINEL_E034_TEST_STOP_AFTER_DECLARATION_ERROR
      return failure();
#endif
      declarationRecovery = true;
      if (text(node, "kind") == "ConstantWriteNode")
        failedDataDeclarations.insert(field(node, "strings", "name").str());
      blocking = false;
    }
  }
  for (const auto &audit : registry.sourceAudits) {
    auto before = diagnostics.size();
    if (failed(audit(*this, rootEntries))) {
      auto fresh = llvm::drop_begin(diagnostics,before);
      bool onlySourceUnknown = !fresh.empty() && llvm::all_of(fresh,[](const auto &d) {
        return d.verdict == DiagnosticVerdict::Unknown && d.code == "SB016";
      });
      if (onlySourceUnknown) {
        sourceAuditUnknown = true;
        blocking = false;
        continue;
      }
      if (llvm::any_of(fresh,[](const auto &d) { return d.verdict == DiagnosticVerdict::Unknown; })) return failure();
      if (diagnostics.size() == before ||
          StringRef(diagnostics.back().text).contains("rejected SB001")) return failure();
      declarationRecovery = true;
      blocking = false;
    }
  }
  if (failed(prepareSubprogramSemantics(*this))) return failure();
  auto output = ModuleOp::create(builder.getUnknownLoc());
  OwningOpRef<ModuleOp> owned(output);
  auto version = input->getAttrOfType<IntegerAttr>("spinel_facts.version");
  auto requests =
      input->getAttrOfType<ArrayAttr>("spinel_facts.analysis_roots");
  if (version.getInt() == 2 && requests.size() != rootEntries.size())
    return (void)error(root,
                       "analysis root set differs from selected BPF roots"),
           failure();
  allRootsXdp = !rootEntries.empty() &&
      llvm::all_of(rootEntries, [&](Operation *rootEntry) {
        return constant(ref(rootEntry, "receiver")) == "BPF" &&
            field(rootEntry, "strings", "name") == "xdp";
      });
  for (auto rootEntry : rootEntries) {
    ScopeGuard rootScope(*this);
    SmallVector<Value> mapValues, ringValues;
    for (const auto &map : maps) mapValues.push_back(map.value);
    for (const auto &ring : rings) ringValues.push_back(ring.value);
    entry = rootEntry;
    if (inspectionOutput) inspectionRootDefinition = inspectionRootDefinitions.lookup(entry);
    auto extensionRoot = dispatchRoot(entry);
    if (extensionRoot.state == Disposition::Error)
      return failure();
    bool custom = extensionRoot.state == Disposition::Handled;
    ProgramDecl rootInfo =
        custom ? std::move(*extensionRoot.value) : ProgramDecl{};
    locals.clear();
    borrows.clear();
    usedMap = false;
    for (auto &m : maps)
      m.used = false;
    auto rootArgs = args(entry);
    if (!entry || (!custom && rootArgs.size() != 1) || rootArgs.empty() ||
        text(rootArgs[0], "kind") != "SymbolNode" ||
        (!custom && !isProducer() && mapName.empty()))
      return (void)error(root,
                         "E001 requires one map and a BPF.xdp symbol root"),
             failure();
    programName = spelling(rootArgs[0], true).str();
    rootInfo.name = programName;
    auto found = defs.find(programName);
    if (found == defs.end())
      return (void)error(entry, "root target must be a declared method"),
             failure();
    def = found->second;
    activeDef = def;
    activeKind = rootInfo.kind;
    rootInfo.def = def;
    rootInfo.entry = entry;
    if (inspectionOutput && !inspectionGraphAvailable) {
      inspectionGraphAvailable = true;
      snapshotDomainGraph();
    }
    auto params = ref(def, "parameters");
    if (!params || array(params, "requireds").size() != 1)
      return (void)error(def,
                         "E001 root requires one unused context parameter"),
             failure();
    if (failed(known(def)))
      return failure();
    if (version.getInt() == 2) {
      DictionaryAttr request;
      for (auto candidate : requests) {
        auto item = cast<DictionaryAttr>(candidate);
        if (item.getAs<StringAttr>("method").getValue() == programName)
          request = item;
      }
      if (!request ||
          request.getAs<IntegerAttr>("def_node_id").getInt() != id(def))
        return (void)error(
                   def,
                   "E006 analysis root differs from the selected BPF root"),
               failure();
      auto requested = request.getAs<ArrayAttr>("requested_arg_types");
      if (requested.size() != 1 ||
          cast<StringAttr>(requested[0]).getValue() != rootInfo.analysisContext)
        return (void)error(def,
                           "E006 XDP analysis root requires obj_BPF::XdpMd"),
               failure();
    }
    if (!custom && failed(known(entry, true)))
      return failure();
    // Establish the argument list before emitting instructions. Walk only the
    // selected BPF body, never User methods or the complete producer module.
    llvm::DenseSet<int64_t> visited;
    prepareDeclarationRecovery(ref(def, "body"));
    prepareSubprogramRecovery(*this, ref(def, "body"));
    auto collect = [&](auto &&self, Operation *node) -> void {
      if (!node || recoverySkipped.count(id(node)) ||
          !visited.insert(id(node)).second)
        return;
      auto name = constant(node);
      for (auto &m : maps)
        if (m.name == name)
          m.used = true;
      for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
        auto n = cast<IntegerAttr>(attr.getValue()).getInt();
        if (n >= 0)
          self(self, nodes.lookup(n));
      }
      for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
        for (auto n : cast<ArrayAttr>(attr.getValue()))
          self(self, nodes.lookup(cast<IntegerAttr>(n).getInt()));
    };
    collect(collect, ref(def, "body"));
    builder.setInsertionPointToEnd(output.getBody());
    SmallVector<Attribute> symbols;
    for (auto &m : maps)
      if (m.used)
        symbols.push_back(FlatSymbolRefAttr::get(ctx, m.name));
    auto program = ebpf::ProgramOp::create(
        builder, outputLoc(def), programName, rootInfo.kind,
        rootInfo.attachTarget.empty()
            ? StringAttr{}
            : builder.getStringAttr(rootInfo.attachTarget),
        ArrayAttr{},
        rootInfo.arch.empty() ? StringAttr{}
                              : builder.getStringAttr(rootInfo.arch),
        /*sleepable=*/false,
        symbols.empty() ? ArrayAttr{} : builder.getArrayAttr(symbols));
    auto *block = new Block();
    program.getBody().push_back(block);
    contextValue = block->addArgument(
        rootInfo.contextType ? rootInfo.contextType
                             : ebpf::ContextType::get(ctx, rootInfo.kind),
        builder.getUnknownLoc());
    for (auto &m : maps)
      if (m.used)
        m.value = block->addArgument(
            m.mapType
                ? m.mapType
                : ebpf::MapType::get(
                      ctx, m.kind,
                      m.keyType ? m.keyType : builder.getIntegerType(m.keyBits),
                      m.valueType ? m.valueType
                                  : builder.getIntegerType(m.bits)),
            builder.getUnknownLoc());
    builder.setInsertionPointToStart(block);
    const size_t bodyDiagnostics = diagnostics.size();
    auto bodyResult = isProducer() ? scalarBody(ref(def, "body"))
                                   : body(ref(def, "body"));
    if (failed(bodyResult)) {
      bool rejectedBody = isProducer() && diagnostics.size() > bodyDiagnostics &&
          llvm::all_of(llvm::drop_begin(diagnostics, bodyDiagnostics),
                       [](const PendingDiagnostic &d) {
                         return d.rejectedCode == "SB019";
                       });
#ifdef SPINEL_E043_TEST_IMMEDIATE_RETURN
      rejectedBody = false;
#endif
      if (!rejectedBody || failed(recoverRejectedProgram("SB019")))
        return failure();
      for (size_t i = 0; i < maps.size(); ++i) maps[i].value = mapValues[i];
      for (size_t i = 0; i < rings.size(); ++i) rings[i].value = ringValues[i];
      program.erase();
      continue;
    }
    if (blocking)
      return failure();
    if (custom && rootInfo.finalizeBody) {
      builder.setInsertionPointToEnd(block);
      if (failed(rootInfo.finalizeBody(*this)) || blocking)
        return failure();
    }
    if (blocking ||
        (!custom && ((!usedMap && !isProducer()) || block->empty() ||
                     !isa<ebpf::VerdictOp>(block->back()))))
      return (void)error(def, "E001 requires map use and a final XDP verdict"),
             failure();
    ProgramDecl info = std::move(rootInfo);
    for (size_t i = 0; i < maps.size(); ++i)
      if (maps[i].used)
        info.maps.push_back(i);
    programs.push_back(std::move(info));
    rootScope.commit();
  }
  for (auto &m : maps)
    m.used = false;
  for (const auto &p : programs)
    for (auto i : p.maps)
      maps[i].used = true;
  if (!declarationRecovery) {
    auto before = diagnostics.size();
    if (failed(analyzeSubprograms(*this, output))) {
      auto added = ArrayRef<PendingDiagnostic>(diagnostics).drop_front(before);
      if (added.empty() || llvm::any_of(added, [](const auto &d) {
            return d.rejectedCode != "SB019" && d.rejectedCode != "SB034";
          }) || failed(recoverRejectedProgram(added.front().rejectedCode)))
        return failure();
    }
  }
  if (!declarationRecovery && failed(verify(output)))
    return failure();
  std::set<size_t> customUnusedMaps;
  for (auto declaration : declarationOrder) {
    if (programs.empty())
      break;
    bool used = declaration.domain == DeclarationRef::Domain::Map
                    ? maps.at(declaration.index).used
                : declaration.domain == DeclarationRef::Domain::Global
                    ? globals.at(declaration.index).used
                : declaration.domain == DeclarationRef::Domain::Ring
                    ? rings.at(declaration.index).used
                    : records.at(declaration.index).used;
    if (used)
      continue;
    for (const auto &handler : registry.unusedDiagnostics) {
      auto result = handler(*this, declaration);
      if (result.state == Disposition::Error ||
          (result.state == Disposition::Handled && !result.value))
        return failure();
      if (result.state == Disposition::Handled) {
        if (declaration.domain == DeclarationRef::Domain::Map)
          customUnusedMaps.insert(declaration.index);
        break;
      }
    }
  }
  std::vector<PendingDiagnostic> conditional = std::move(pendingConditionals);
  for (const auto &m : maps)
    if (!programs.empty() && !m.used &&
        !customUnusedMaps.count(&m - maps.data())) {
      auto loc = cast<FileLineColLoc>(m.node->getLoc());
      conditional.push_back(
          {loc.getLine(), loc.getColumn(),
           renderDiagnostic(m.node, "conditional", "SB013", "MapDeclShape",
                            "map " + m.name +
                                " is declared but no eBPF program uses it — "
                                "it is left out of the ELF, the schema and "
                                "maps.json (user space cannot read it)")});
      if (inspectionOutput)
        conditional.back().domain = domainDiagnostic(m.node, "conditional", "SB013", "MapDeclShape",
          "map " + m.name + " is declared but no eBPF program uses it — it is left out of the ELF, the schema and maps.json (user space cannot read it)");
    }
  // E029: an unused ring (analyze.go:701-707). Go prints the conditional
  // lines sorted by position (Diags.Sorted), so a ring line joins the maps'.
  bool unusedRing = false;
  if (!programs.empty())
    for (const auto &r : rings)
      if (!r.used) {
        auto loc = cast<FileLineColLoc>(r.node->getLoc());
        conditional.push_back(
            {loc.getLine(), loc.getColumn(),
             renderDiagnostic(r.node, "conditional", "SB013", "MapDeclShape",
                              "ring buffer " + r.name +
                                  " is declared but no eBPF program outputs "
                                  "to it — it is left out of the ELF, the "
                                  "schema and maps.json")});
        if (inspectionOutput)
          conditional.back().domain = domainDiagnostic(r.node, "conditional", "SB013", "MapDeclShape",
            "ring buffer " + r.name + " is declared but no eBPF program outputs to it — it is left out of the ELF, the schema and maps.json");
        unusedRing = true;
      }
  if (unusedRing)
    std::stable_sort(conditional.begin(), conditional.end(),
                     [](const PendingDiagnostic &a, const PendingDiagnostic &b) {
                       return std::tie(a.line, a.col) < std::tie(b.line, b.col);
                     });
  // E021: SB003 after lowering. Rejected, Go prints every diagnostic in
  // position order without the warning prefix; accepted, the conditional
  // lines keep the prefix as before.
  auto userSide = userSideFindings();
  if (failed(userSide))
    return failure();
  if (declarationRecovery || sourceAuditUnknown || !userSide->empty()) {
    conditional.insert(conditional.end(), userSide->begin(), userSide->end());
    std::stable_sort(conditional.begin(), conditional.end(),
                     [](const PendingDiagnostic &a, const PendingDiagnostic &b) {
                       return std::tie(a.line, a.col) < std::tie(b.line, b.col);
                     });
    diagnostics.insert(diagnostics.end(), conditional.begin(), conditional.end());
    if (declarationRecovery || sourceAuditUnknown)
      programs.clear(); // analyze.go:708-712: diagnostics precede final rejection.
    blocking = true;
    return failure();
  }
  std::stable_sort(conditional.begin(), conditional.end(),
                   [](const auto &a, const auto &b) {
                     return std::tie(a.line, a.col) < std::tie(b.line, b.col);
                   });
  if (failed(checkTypingProbe(*this))) {
    diagnostics.insert(diagnostics.end(),conditional.begin(),conditional.end());
    std::stable_sort(diagnostics.begin(),diagnostics.end(),[](const auto &a,const auto &b) {
      return std::tie(a.line,a.col,a.code)<std::tie(b.line,b.col,b.code);
    });
    return failure();
  }
  for (const auto &d : conditional)
    llvm::errs() << "spinelbpf: warning: " << d.text << "\n";
  auto schema = json(true), mapJson = json(false);
  if (blocking)
    return failure();
  Artifacts artifacts{std::move(schema), std::move(mapJson), {}, {}};
  artifacts.records = exportRecords();
  artifacts.uprobeTargets = exportUprobeTargets();
  if (blocking) return failure();
  if (inspectionOutput) {
    for (const auto &d : conditional)
      if (d.domain) inspectionDomain.diagnostics.push_back(*d.domain);
    for (const auto &p : programs)
      inspectionDomain.roots.push_back({p.name, p.kind,
        domainDiagnostic(p.entry,"","","","").pos,
        domainDiagnostic(p.def,"","","","").pos});
    finishInspection(true);
    inspectDone.release();
  }
  input.getBodyRegion().takeBody(output.getBodyRegion());
  input->setAttrs(builder.getDictionaryAttr({}));
  input->setLoc(builder.getUnknownLoc());
  return artifacts;
}

LogicalResult checkLiteralNode(ir::NodeOp node, std::optional<inspection::Diagnostic> *record) {
  auto raw = text(node, "literal_text");
  auto backend = text(node, "backend_decimal");
  int64_t value = 0, stored = 0;
  std::string digits = raw.str();
  digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
  bool valid = !StringRef(digits).getAsInteger(0, value) &&
               !backend.getAsInteger(10, stored) &&
               value != std::numeric_limits<int64_t>::min() && value == stored;
  if (!valid) {
    auto loc = dyn_cast<FileLineColLoc>(node.getLoc());
    if (!loc)
      return node.emitOpError("source-backed literal location missing");
    std::string message = "integer literal " + raw.str() +
        " is not an Integer Spinel can hold (Spinel reads it as \"" + backend.str() +
        "\") — literals must be within [-2^63+1, 2^63-1] (P001 §3.8)";
    auto file = llvm::sys::path::filename(loc.getFilename().getValue()).str();
    llvm::errs() << file << ":" << loc.getLine() << ":" << loc.getColumn()
                 << ": rejected SB014 (SemanticGap): " << message << "\n";
    if (record)
      *record = inspection::Diagnostic{"rejected","SB014","SemanticGap",
          {file,loc.getLine(),loc.getColumn()},{},std::move(message)};
    return failure();
  }

  return success();
}
} // namespace spinel::consumer
