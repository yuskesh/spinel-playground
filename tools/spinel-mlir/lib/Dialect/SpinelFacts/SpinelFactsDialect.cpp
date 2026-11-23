#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"
#include "llvm/ADT/DenseSet.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOpsDialect.cpp.inc"
#define GET_TYPEDEF_CLASSES
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOpsTypes.cpp.inc"
#define GET_OP_CLASSES
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOps.cpp.inc"

using namespace mlir;
namespace spinel::ir {
void SpinelFactsDialect::initialize() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOpsTypes.cpp.inc"
  >();
  addOperations<
#define GET_OP_LIST
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsOps.cpp.inc"
  >();
}
static bool stringAttr(Operation *op, StringRef key) {
  return bool(op->getAttrOfType<StringAttr>(key));
}
static bool intAttr(Operation *op, StringRef key) {
  auto attr = op->getAttrOfType<IntegerAttr>(key);
  return attr && attr.getType().isInteger(64);
}
static StringRef text(Operation *op, StringRef key) {
  auto attr = op->getAttrOfType<StringAttr>(key);
  return attr ? attr.getValue() : StringRef();
}
LogicalResult SourceOp::verify() {
  if (!intAttr(*this, "file_id") || !stringAttr(*this, "path") ||
      !stringAttr(*this, "text"))
    return emitOpError("source requires file_id:i64, path:string, text:string");
  return success();
}
LogicalResult SpliceOp::verify() {
  if (!intAttr(*this, "file_id") || !intAttr(*this, "before_line") ||
      !stringAttr(*this, "path") || !stringAttr(*this, "origin"))
    return emitOpError("splice requires file_id/before_line:i64 and path/origin:string");
  if ((*this)->getAttrOfType<IntegerAttr>("file_id").getInt() < 0 ||
      (*this)->getAttrOfType<IntegerAttr>("before_line").getInt() < 1 ||
      text(*this, "path").empty())
    return emitOpError("splice requires file_id >= 0, before_line >= 1 and a nonempty path");
  auto origin = text(*this, "origin");
  if (origin != "set" && origin != "io_buffer" && origin != "enumerable" &&
      origin != "builtin_extra" && origin != "enumerator")
    return emitOpError("unknown splice origin");
  return success();
}
LogicalResult NodeOp::verify() {
  if (!getOperation()->getParentOfType<TableOp>())
    return emitOpError("node must be in a table");
  if (!intAttr(*this, "id") || !intAttr(*this, "file_id") || !stringAttr(*this, "kind"))
    return emitOpError("node requires id:i64, file_id:i64 and kind:string");
  for (auto key : {"strings", "integers", "refs", "arrays"}) {
    auto dict = (*this)->getAttrOfType<DictionaryAttr>(key);
    if (!dict)
      return emitOpError() << "node requires " << key << ":DictionaryAttr";
    for (auto entry : dict) {
      bool valid = false;
      if (StringRef(key) == "strings" || StringRef(key) == "integers")
        valid = isa<StringAttr>(entry.getValue());
      else if (StringRef(key) == "refs")
        valid = isa<IntegerAttr>(entry.getValue()) &&
                cast<IntegerAttr>(entry.getValue()).getType().isInteger(64);
      else if (auto array = dyn_cast<ArrayAttr>(entry.getValue()))
        valid = llvm::all_of(array, [](Attribute x) {
          auto integer = dyn_cast<IntegerAttr>(x);
          return integer && integer.getType().isInteger(64);
        });
      if (!valid)
        return emitOpError() << "invalid node field " << key << "." << entry.getName();
    }
  }
  auto span = (*this)->getAttrOfType<ArrayAttr>("span");
  if (!span || (span.size() != 0 && span.size() != 4))
    return emitOpError("span must be empty or have four i64 values");
  for (auto item : span)
    if (!isa<IntegerAttr>(item) || !cast<IntegerAttr>(item).getType().isInteger(64))
      return emitOpError("span values must be i64");
  auto fileID = (*this)->getAttrOfType<IntegerAttr>("file_id").getInt();
  if (span.empty()) {
    if (fileID != -1 || !isa<UnknownLoc>(getLoc()))
      return emitOpError("missing position requires file_id=-1, empty span, unknown loc");
  } else {
    auto beginLine = cast<IntegerAttr>(span[0]).getInt();
    auto beginCol = cast<IntegerAttr>(span[1]).getInt();
    auto endLine = cast<IntegerAttr>(span[2]).getInt();
    auto endCol = cast<IntegerAttr>(span[3]).getInt();
    auto loc = dyn_cast<FileLineColLoc>(getLoc());
    if (fileID < 0 || beginLine < 1 || beginCol < 0 || endLine < beginLine ||
        endCol < 0 || (endLine == beginLine && endCol < beginCol) ||
        !loc || loc.getLine() != uint64_t(beginLine) ||
        loc.getColumn() != uint64_t(beginCol + 1))
      return emitOpError("span and FileLineColLoc disagree");
  }
  auto table = getOperation()->getParentOfType<TableOp>();
  if (text(*this, "kind") == "IntegerNode") {
    for (auto field : {"literal_decimal", "backend_decimal"})
      if (!stringAttr(*this, field))
        return emitOpError() << "IntegerNode requires " << field;
    auto integers = (*this)->getAttrOfType<DictionaryAttr>("integers");
    auto stored = integers.getAs<StringAttr>("value");
    if (!stored || stored.getValue() != text(*this, "backend_decimal"))
      return emitOpError("integers.value disagrees with backend_decimal");
    if (text(table, "phase") == "pristine" && !span.empty() &&
        !stringAttr(*this, "literal_text"))
      return emitOpError("source-backed pristine IntegerNode requires literal_text");
  }
  return success();
}
LogicalResult TableOp::verify() {
  auto phase = text(*this, "phase");
  if ((phase != "pristine" && phase != "analyzed") || !intAttr(*this, "root_id"))
    return emitOpError("table requires phase pristine/analyzed and root_id:i64");
  if (getBody().empty())
    return emitOpError("table requires one block");
  llvm::DenseSet<int64_t> ids;
  for (auto &op : getBody().front()) {
    if (!isa<NodeOp>(op) || !intAttr(&op, "id"))
      return emitOpError("table accepts only nodes with id:i64");
    auto id = op.getAttrOfType<IntegerAttr>("id").getInt();
    if (id < 0 || !ids.insert(id).second)
      return emitOpError() << "duplicate node ID " << id << " in " << phase;
  }
  if (!ids.contains((*this)->getAttrOfType<IntegerAttr>("root_id").getInt()))
    return emitOpError("root_id has no node");
  for (auto &op : getBody().front()) {
    for (auto key : {"refs", "arrays"}) {
      auto dict = op.getAttrOfType<DictionaryAttr>(key);
      if (!dict)
        return emitOpError("node references dictionary missing");
      for (auto field : dict) {
        SmallVector<Attribute> refs;
        if (StringRef(key) == "refs")
          refs.push_back(field.getValue());
        else if (auto array = dyn_cast<ArrayAttr>(field.getValue()))
          refs.append(array.begin(), array.end());
        else
          return emitOpError("node arrays must contain arrays");
        for (auto ref : refs) {
          auto attr = dyn_cast<IntegerAttr>(ref);
          if (!attr || (attr.getInt() != -1 && !ids.contains(attr.getInt())))
            return emitOpError("node reference has no target in this phase");
        }
      }
    }
  }
  return success();
}
static LogicalResult verifyMetadata(Operation *op) {
  if (!intAttr(op, "node_id") || !stringAttr(op, "kind") ||
      text(op, "phase") != "analyzed")
    return op->emitOpError("metadata requires analyzed phase, node_id:i64, kind:string");
  return success();
}
LogicalResult TypeOp::verify() {
  if (failed(verifyMetadata(*this)))
    return failure();
  if (auto nilable = (*this)->getAttr("nilable"))
    if (!isa<BoolAttr>(nilable))
      return emitOpError("nilable must be bool when present");
  return success();
}
LogicalResult EvidenceOp::verify() { return verifyMetadata(*this); }
LogicalResult DiagnosticOp::verify() {
  if (!stringAttr(*this, "severity") || !stringAttr(*this, "file") ||
      !stringAttr(*this, "message") || !intAttr(*this, "line") || !intAttr(*this, "col"))
    return emitOpError("diagnostic requires severity/file/message:string and line/col:i64");
  return success();
}
} // namespace spinel::ir
