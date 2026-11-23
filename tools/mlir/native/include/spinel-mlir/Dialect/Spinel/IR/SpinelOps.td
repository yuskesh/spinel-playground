// Spinel dialect operations; the root TableGen file for add_mlir_dialect().
// Only the three checked-arithmetic operations belong here. Floor div/mod,
// Ruby AST names, target names, tensor vocabulary and generic kind attributes
// do not. Ordinary arithmetic uses arith; these operations retain the
// Spinel-specific overflow policy that standard operations cannot express.

#ifndef SPINEL_OPS
#define SPINEL_OPS

include "mlir/IR/OpBase.td"
include "mlir/IR/EnumAttr.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

def Spinel_Dialect : Dialect {
  let name = "spinel";
  let cppNamespace = "::mlir::spinel";
  let summary = "dialect of Spinel-specific semantics (E161 checked arithmetic)";
  let description = [{
    Retain only Spinel-specific semantics that standard dialects would lose.
    Checked add/sub/mul accept signed i32 or i64 with an explicit overflow policy.
    Admission was reserved for the later checkpoint decision record.
  }];
  let useDefaultAttributePrinterParser = 1;
}

// Overflow policy is the closed set raise | wrap | none | trap. Target names
// (hosted/freestanding) belong at pass boundaries, not here. On overflow, trap
// calls the freestanding profile hook and never returns. Like raise, it has
// observable effects and must not be deleted by canonicalization or merged
// by CSE (common subexpression elimination); effects/speculation follow raise.
// Only freestanding-hook may lower trap; the pass refuses other targets.
// Write summaries in English: ODS constraint failures embed them in the
// single-line stderr diagnostic contract.
def Spinel_OverflowPolicy : I32EnumAttr<"OverflowPolicy",
    "overflow policy (raise | wrap | none | trap)", [
  I32EnumAttrCase<"Raise", 0, "raise">,
  I32EnumAttrCase<"Wrap",  1, "wrap">,
  I32EnumAttrCase<"None",  2, "none">,
  I32EnumAttrCase<"Trap",  3, "trap">
]> {
  let cppNamespace = "::mlir::spinel";
  let genSpecializedAttr = 0;
}

def Spinel_OverflowPolicyAttr
    : EnumAttr<Spinel_Dialect, Spinel_OverflowPolicy, "policy">;

class Spinel_Op<string mnemonic, list<Trait> traits = []>
    : Op<Spinel_Dialect, mnemonic, traits>;

// Checked binary operations use matching signless i32 or i64 operands/results.
// The verifier owns this width restriction (decision 0019).
// Historical rationale follows; its i64-only restriction is superseded.
// Operands/results admit signless integers so the verifier, rather than an ODS
// I64 constraint, reports unsupported-integer-type for a uniform i32 operation.
// AllTypesMatch owns type equality and supports custom-form inference; the
// driver normalizes its mismatch diagnostic to type-mismatch.
// Policy is required: the ODS parser/EnumAttr refuse missing or unknown values
// without defaults; the adapter normalizes missing-policy / unknown-policy.
// Effects depend on policy: raise has observable exception/trap effects in
// hosted and freestanding shapes, so cannot be Pure (removable/speculatable).
// The original Pure sketch let canonicalize delete raise and CSE merge it.
// Use policy-dependent ConditionallySpeculatable and MemoryEffectsOpInterface
// instead. wrap/none have no effects and permit speculation, equivalent to Pure.
class Spinel_CheckedBinaryOp<string mnemonic> : Spinel_Op<mnemonic,
    [AllTypesMatch<["lhs", "rhs", "result"]>,
     DeclareOpInterfaceMethods<ConditionallySpeculatable>,
     DeclareOpInterfaceMethods<MemoryEffectsOpInterface>]> {
  // detail optionally carries the complete trap message. Frozen Python uses
  // "<fn>: integer overflow in <op>", where fn is the Ruby method name. Lowering
  // sees @sp_<fn> (the export wrapper is @spinel_<fn>); stripping prefixes would
  // misidentify methods such as sp_x. Only the importer knows both names, so it
  // supplies the full message. This also preserves -@ after lowering unary minus
  // to checked_sub(0, x), matching overflow_op(..., detail_op="-@"). Without
  // detail, lowering constructs it from the operation; hosted raise ignores the
  // attribute and is unchanged.
  let arguments = (ins AnySignlessInteger:$lhs, AnySignlessInteger:$rhs,
                       Spinel_OverflowPolicyAttr:$policy,
                       OptionalAttr<StrAttr>:$detail);
  let results = (outs AnySignlessInteger:$result);
  // Assembly parsing is handwritten: generated attr-dict parsing could silently
  // override the keyword policy with a policy attribute. For example, policy
  // raise {policy = #spinel<policy none>} became none, violating raise retention.
  // Refuse policy in attr-dict as unknown-policy. Grammar matches the canonical
  // fixture: $lhs `,` $rhs `policy` <keyword> attr-dict `:` type($result).
  // Printing matches the generated form byte for byte (printed=canonical checks).
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
}

def Spinel_CheckedAddOp : Spinel_CheckedBinaryOp<"checked_add"> {
  let summary = "signed addition with an overflow policy";
}
def Spinel_CheckedSubOp : Spinel_CheckedBinaryOp<"checked_sub"> {
  let summary = "signed subtraction with an overflow policy";
}
def Spinel_CheckedMulOp : Spinel_CheckedBinaryOp<"checked_mul"> {
  let summary = "signed multiplication with an overflow policy";
}

#endif // SPINEL_OPS
