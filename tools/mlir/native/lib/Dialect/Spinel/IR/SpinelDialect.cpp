// Spinel dialect implementation: instantiate ODS-generated definitions and provide checked-binary
// verifier hooks.

#include "spinel-mlir/Dialect/Spinel/IR/SpinelDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace mlir::spinel;

#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsDialect.cpp.inc"
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsEnums.cpp.inc"

#define GET_ATTRDEF_CLASSES
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsAttributes.cpp.inc"

void SpinelDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOps.cpp.inc"
      >();
  addAttributes<
#define GET_ATTRDEF_LIST
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOpsAttributes.cpp.inc"
      >();
}

// Verifier history: initially ODS checked type equality, I64, required policy and enum keywords
// before custom Spinel checks; the diagnostic adapter normalized
// type-mismatch/unsupported-integer-type/missing-policy/unknown-policy to one spinel-arith line.
// The later checkpoint moved canonical signless-i64 enforcement into this verifier: AllTypesMatch
// already ensures all three types agree, then unsupported widths get unsupported-integer-type. The
// driver adds the line prefix. Unknown enum values cannot exist after EnumAttr construction; never
// default them.
static LogicalResult verifyCheckedBinary(Operation *op) {
  // Generic syntax discardable policy (the second policy in <{policy=...}> {policy=...}) is
  // silently discarded by core MLIR parsing: the property wins. getDiscardableAttr("policy") is
  // already null at verification, so this layer cannot refuse it. Record this asymmetry with custom
  // syntax, whose handwritten parser can refuse it.
  Type ty = op->getResult(0).getType();
  auto intTy = dyn_cast<IntegerType>(ty);
  if (!intTy || (!intTy.isSignlessInteger(32) && !intTy.isSignlessInteger(64)))
    return op->emitError() << "unsupported-integer-type: " << op->getName()
                           << " uses " << ty
                           << " (Integer bodies support i32 or i64)";
  return success();
}

LogicalResult CheckedAddOp::verify() { return verifyCheckedBinary(*this); }
LogicalResult CheckedSubOp::verify() { return verifyCheckedBinary(*this); }
LogicalResult CheckedMulOp::verify() { return verifyCheckedBinary(*this); }

// Handwritten assembly parsing prevents attr-dict from silently overriding inherent policy.
// Otherwise policy raise {policy=...none} would violate observable raise retention. Refuse policy
// inside attr-dict while preserving generated enum/expected-policy diagnostic spelling, pinned by
// invalid.test and driver categories. Printing stays byte-identical.
template <typename OpT>
static ParseResult parseCheckedBinary(OpAsmParser &parser,
                                      OperationState &result) {
  OpAsmParser::UnresolvedOperand lhs, rhs;
  if (parser.parseOperand(lhs) || parser.parseComma() ||
      parser.parseOperand(rhs) || parser.parseKeyword("policy"))
    return failure();
  llvm::SMLoc kwLoc = parser.getCurrentLocation();
  StringRef kw;
  if (parser.parseKeyword(&kw))
    return failure();
  std::optional<OverflowPolicy> policy = symbolizeOverflowPolicy(kw);
  if (!policy)
    return parser.emitError(kwLoc)
           << "expected ::mlir::spinel::OverflowPolicy to be one of: raise, "
              "wrap, none, trap";
  result.getOrAddProperties<typename OpT::Properties>().policy =
      OverflowPolicyAttr::get(parser.getContext(), *policy);
  llvm::SMLoc dictLoc = parser.getCurrentLocation();
  NamedAttrList attrs;
  if (parser.parseOptionalAttrDict(attrs))
    return failure();
  if (attrs.get("policy"))
    return parser.emitError(dictLoc)
           << "an attr-dict entry cannot override the policy keyword "
              "(policy must be spelled exactly once)";
  result.addAttributes(attrs);
  Type ty;
  if (parser.parseColonType(ty))
    return failure();
  if (parser.resolveOperand(lhs, ty, result.operands) ||
      parser.resolveOperand(rhs, ty, result.operands))
    return failure();
  result.addTypes(ty);
  return success();
}

template <typename OpT>
static void printCheckedBinary(OpT op, OpAsmPrinter &p) {
  p << ' ' << op.getLhs() << ", " << op.getRhs() << " policy "
    << stringifyOverflowPolicy(op.getPolicy());
  p.printOptionalAttrDict(op->getAttrs(), /*elidedAttrs=*/{"policy"});
  p << " : " << op.getType();
}

ParseResult CheckedAddOp::parse(OpAsmParser &parser, OperationState &result) {
  return parseCheckedBinary<CheckedAddOp>(parser, result);
}
ParseResult CheckedSubOp::parse(OpAsmParser &parser, OperationState &result) {
  return parseCheckedBinary<CheckedSubOp>(parser, result);
}
ParseResult CheckedMulOp::parse(OpAsmParser &parser, OperationState &result) {
  return parseCheckedBinary<CheckedMulOp>(parser, result);
}
void CheckedAddOp::print(OpAsmPrinter &p) { printCheckedBinary(*this, p); }
void CheckedSubOp::print(OpAsmPrinter &p) { printCheckedBinary(*this, p); }
void CheckedMulOp::print(OpAsmPrinter &p) { printCheckedBinary(*this, p); }

// Policy-dependent effects: raise is observable on overflow (exception/trap), preventing
// deletion/merging/speculation; conservative Write granularity awaited lowering evidence. trap is
// equally observable because it invokes a nonreturning hook; treating it differently would
// reproduce raise canonicalization/CSE failures. wrap/none are effect-free speculatable integer
// operations, equivalent to Pure.
template <typename OpT>
static void getCheckedBinaryEffects(
    OpT op, SmallVectorImpl<SideEffects::EffectInstance<MemoryEffects::Effect>>
                &effects) {
  if (op.getPolicy() == OverflowPolicy::Raise ||
      op.getPolicy() == OverflowPolicy::Trap)
    effects.emplace_back(MemoryEffects::Write::get());
}

template <typename OpT>
static Speculation::Speculatability getCheckedBinarySpeculatability(OpT op) {
  return (op.getPolicy() == OverflowPolicy::Raise ||
          op.getPolicy() == OverflowPolicy::Trap)
             ? Speculation::NotSpeculatable
             : Speculation::Speculatable;
}

void CheckedAddOp::getEffects(
    SmallVectorImpl<SideEffects::EffectInstance<MemoryEffects::Effect>>
        &effects) {
  getCheckedBinaryEffects(*this, effects);
}
void CheckedSubOp::getEffects(
    SmallVectorImpl<SideEffects::EffectInstance<MemoryEffects::Effect>>
        &effects) {
  getCheckedBinaryEffects(*this, effects);
}
void CheckedMulOp::getEffects(
    SmallVectorImpl<SideEffects::EffectInstance<MemoryEffects::Effect>>
        &effects) {
  getCheckedBinaryEffects(*this, effects);
}

Speculation::Speculatability CheckedAddOp::getSpeculatability() {
  return getCheckedBinarySpeculatability(*this);
}
Speculation::Speculatability CheckedSubOp::getSpeculatability() {
  return getCheckedBinarySpeculatability(*this);
}
Speculation::Speculatability CheckedMulOp::getSpeculatability() {
  return getCheckedBinarySpeculatability(*this);
}

#define GET_OP_CLASSES
#include "spinel-mlir/Dialect/Spinel/IR/SpinelOps.cpp.inc"
