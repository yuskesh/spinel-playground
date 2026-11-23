#include "spinel/Import/Import.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/Support/raw_ostream.h"
#include <limits>
#include <algorithm>
#include <tuple>
using namespace mlir;
namespace spinel {
static StringRef text(Operation *op, StringRef key) {
  auto attr = op->getAttrOfType<StringAttr>(key);
  return attr ? attr.getValue() : StringRef();
}
static FailureOr<size_t> sourceOffset(StringRef source, int64_t line, int64_t col) {
  if (line < 1 || col < 0) return failure();
  size_t offset = 0;
  for (int64_t n = 1; n < line; ++n) {
    auto newline = source.find('\n', offset);
    if (newline == StringRef::npos) return failure();
    offset = newline + 1;
  }
  auto end = source.find('\n', offset);
  if (end == StringRef::npos) end = source.size();
  if (uint64_t(col) > end - offset) return failure();
  return offset + size_t(col);
}
static LogicalResult verifyAnalysisRoots(ModuleOp module, int64_t version,
                                         bool rejected) {
  Attribute raw = module->getAttr("spinel_facts.analysis_roots");
  if (version == 1)
    return raw ? module.emitOpError("version 1 cannot contain analysis_roots")
               : success();
  auto roots = dyn_cast_or_null<ArrayAttr>(raw);
  if (!roots || roots.empty())
    return module.emitOpError("version 2 requires nonempty analysis_roots");
  llvm::DenseMap<int64_t, Operation *> nodes;
  llvm::DenseMap<int64_t, SmallVector<Operation *>> types;
  if (!rejected) {
    for (auto table : module.getOps<ir::TableOp>()) {
      if (text(table, "phase") != "analyzed") continue;
      for (auto node : table.getBody().front().getOps<ir::NodeOp>())
        nodes[node->getAttrOfType<IntegerAttr>("id").getInt()] = node;
    }
    for (auto type : module.getOps<ir::TypeOp>())
      types[type->getAttrOfType<IntegerAttr>("node_id").getInt()].push_back(type);
  }
  llvm::DenseSet<int64_t> seen;
  for (Attribute attr : roots) {
    auto root = dyn_cast<DictionaryAttr>(attr);
    if (!root) return module.emitOpError("analysis root must be a dictionary");
    auto method = root.getAs<StringAttr>("method");
    auto requested = root.getAs<ArrayAttr>("requested_arg_types");
    if (!method || method.getValue().empty() || !requested)
      return module.emitOpError("analysis root requires method and requested_arg_types");
    for (Attribute arg : requested) {
      auto type = dyn_cast<StringAttr>(arg);
      if (!type || type.getValue().empty())
        return module.emitOpError("requested argument type must be a nonempty string");
    }
    if (rejected) {
      if (root.get("def_node_id") || root.get("resolved_arg_types"))
        return module.emitOpError("rejected analysis root must not contain resolved metadata");
      continue;
    }
    auto id = root.getAs<IntegerAttr>("def_node_id");
    auto resolved = root.getAs<ArrayAttr>("resolved_arg_types");
    if (!id || !id.getType().isInteger(64) || !nodes.contains(id.getInt()) ||
        text(nodes.lookup(id.getInt()), "kind") != "DefNode")
      return module.emitOpError("analysis root def_node_id must reference an analyzed DefNode");
    if (!seen.insert(id.getInt()).second)
      return module.emitOpError("duplicate analysis root def_node_id");
    if (!resolved || resolved.size() != requested.size())
      return module.emitOpError("analysis root argument array length mismatch");
    Operation *def = nodes.lookup(id.getInt());
    auto strings = def->getAttrOfType<DictionaryAttr>("strings");
    auto refs = def->getAttrOfType<DictionaryAttr>("refs");
    if (strings.getAs<StringAttr>("name") != method)
      return module.emitOpError("analysis root method differs from analyzed DefNode");
    auto receiver = refs.getAs<IntegerAttr>("receiver");
    if (receiver && receiver.getInt() >= 0)
      return module.emitOpError("analysis root requires receiver-free DefNode");
    SmallVector<int64_t> parameters;
    auto paramRef = refs.getAs<IntegerAttr>("parameters");
    if (paramRef && paramRef.getInt() >= 0) {
      Operation *params = nodes.lookup(paramRef.getInt());
      if (!params || text(params, "kind") != "ParametersNode")
        return module.emitOpError("analysis root requires analyzed ParametersNode");
      auto arrays = params->getAttrOfType<DictionaryAttr>("arrays");
      auto paramRefs = params->getAttrOfType<DictionaryAttr>("refs");
      for (auto key : {"optionals", "keywords", "posts"})
        if (auto list = arrays.getAs<ArrayAttr>(key); list && !list.empty())
          return module.emitOpError("analysis root requires fixed positional signature");
      for (auto key : {"rest", "keyword_rest", "block"})
        if (auto ref = paramRefs.getAs<IntegerAttr>(key); ref && ref.getInt() >= 0)
          return module.emitOpError("analysis root requires fixed positional signature");
      if (auto required = arrays.getAs<ArrayAttr>("requireds")) {
        for (auto value : required) {
          auto param = cast<IntegerAttr>(value).getInt();
          if (!nodes.contains(param) || text(nodes.lookup(param), "kind") != "RequiredParameterNode")
            return module.emitOpError("analysis root requires named positional parameters");
          parameters.push_back(param);
        }
      }
    }
    if (parameters.size() != requested.size())
      return module.emitOpError("analysis root arity differs from analyzed DefNode");
    for (auto [index, param] : llvm::enumerate(parameters)) {
      auto actual = dyn_cast<StringAttr>(resolved[index]);
      auto &records = types[param];
      if (!actual || actual.getValue().empty() || records.size() != 1 || text(records.front(), "kind") != actual.getValue())
        return module.emitOpError("analysis root resolved type differs from parameter TypeOp.kind");
    }
  }
  return success();
}
LogicalResult verifyImport(ModuleOp module) {
  auto version = module->getAttrOfType<IntegerAttr>("spinel_facts.version");
  if (!version || !version.getType().isInteger(64) ||
      (version.getInt() != 1 && version.getInt() != 2))
    return module.emitOpError("unsupported spinel_facts version");
  for (auto key : {"producer", "producer_revision", "profile", "status", "overflow"})
    if (!module->getAttrOfType<StringAttr>(std::string("spinel_facts.") + key))
      return module.emitOpError() << "missing module attribute " << key;
  auto checked = module->getAttrOfType<BoolAttr>("spinel_facts.refusal_checked");
  if (!checked || !checked.getValue())
    return module.emitOpError("codegen refusal was not checked");
  auto count = module->getAttrOfType<IntegerAttr>("spinel_facts.refusal_count");
  auto bits = module->getAttrOfType<IntegerAttr>("spinel_facts.integer_bits");
  if (!count || !count.getType().isInteger(64) || !bits ||
      !bits.getType().isInteger(64) || bits.getInt() <= 0)
    return module.emitOpError("requires refusal_count and positive integer_bits");
  auto status = text(module, "spinel_facts.status");
  auto profile = text(module, "spinel_facts.profile");
  if ((version.getInt() == 1 && profile != "handwritten-v1" && profile != "spinel-codegen-v1") ||
      (version.getInt() == 2 && profile != "spinel-codegen-v2"))
    return module.emitOpError("unsupported evidence profile");
  if (status == "rejected") {
    unsigned errors = 0;
    for (auto &op : module.getBody()->getOperations()) {
      if (!isa<ir::DiagnosticOp>(op))
        return module.emitOpError("rejected module must contain only diagnostics");
      errors += text(&op, "severity") == "error";
    }
    if (!errors || count.getInt() <= 0)
      return module.emitOpError("rejected module requires an error diagnostic and positive refusal_count");
    return verifyAnalysisRoots(module, version.getInt(), true);
  }
  if (status != "success" || count.getInt() != 0)
    return module.emitOpError("successful import requires success status and refusal_count=0");
  auto overflow = text(module, "spinel_facts.overflow");
  if (overflow != "raise" && overflow != "wrap" && overflow != "promote")
    return module.emitOpError("unsupported Spinel overflow mode");
  llvm::DenseMap<int64_t, Operation *> sources;
  llvm::DenseSet<int64_t> analyzed;
  bool pristineSeen = false, analyzedSeen = false;
  for (auto &op : module.getBody()->getOperations()) {
    if (auto source = dyn_cast<ir::SourceOp>(op)) {
      auto id = source->getAttrOfType<IntegerAttr>("file_id").getInt();
      if (id < 0 || sources.contains(id))
        return source.emitOpError("duplicate or negative source file_id");
      sources[id] = source;
    } else if (auto splice = dyn_cast<ir::SpliceOp>(op)) {
      // Provenance only: spans already are original-file positions.
      if (pristineSeen || analyzedSeen)
        return splice.emitOpError("splice must precede the tables");
      if (!sources.contains(splice->getAttrOfType<IntegerAttr>("file_id").getInt()))
        return splice.emitOpError("splice file_id has no preceding source");
    } else if (auto table = dyn_cast<ir::TableOp>(op)) {
      bool pristine = text(table, "phase") == "pristine";
      bool &seen = pristine ? pristineSeen : analyzedSeen;
      if (seen)
        return table.emitOpError("duplicate table phase");
      seen = true;
      for (auto node : table.getBody().front().getOps<ir::NodeOp>()) {
        auto id = node->getAttrOfType<IntegerAttr>("file_id").getInt();
        if (id >= 0 && !sources.contains(id))
          return node.emitOpError("file_id has no preceding source");
        if (id >= 0) {
          auto *source = sources.lookup(id);
          auto loc = cast<FileLineColLoc>(node.getLoc());
          if (loc.getFilename().getValue() != text(source, "path"))
            return node.emitOpError("loc filename differs from source path");
          if (pristine && text(node, "kind") == "IntegerNode") {
            auto span = node->getAttrOfType<ArrayAttr>("span");
            auto rawSource = text(source, "text");
            auto begin = sourceOffset(rawSource, cast<IntegerAttr>(span[0]).getInt(),
                                      cast<IntegerAttr>(span[1]).getInt());
            auto end = sourceOffset(rawSource, cast<IntegerAttr>(span[2]).getInt(),
                                    cast<IntegerAttr>(span[3]).getInt());
            if (failed(begin) || failed(end) || *end < *begin ||
                rawSource.slice(*begin, *end) != text(node, "literal_text"))
              return node.emitOpError("literal_text differs from source span");
          }
        }
        if (!pristine)
          analyzed.insert(node->getAttrOfType<IntegerAttr>("id").getInt());
      }
    } else if (isa<ir::TypeOp, ir::EvidenceOp>(op)) {
      if (!analyzed.contains(op.getAttrOfType<IntegerAttr>("node_id").getInt()))
        return op.emitOpError("metadata has no analyzed node");
    } else if (isa<ir::DiagnosticOp>(op) && text(&op, "severity") == "error") {
      return op.emitOpError("success module contains error diagnostic");
    } else if (!isa<ir::DiagnosticOp>(op)) {
      return op.emitOpError("unexpected operation in import module");
    }
  }
  if (!pristineSeen || !analyzedSeen)
    return module.emitOpError("requires pristine and analyzed tables");
  return verifyAnalysisRoots(module, version.getInt(), false);
}
} // namespace spinel
