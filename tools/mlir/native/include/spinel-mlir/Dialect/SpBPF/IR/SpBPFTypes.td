// SpBPF types. Use namespace spbpf rather than ebpf to avoid existing dialect
// collisions. Only eBPF-specific types not expressible in standard dialects
// belong here; operations/control flow use arith/scf/cf/func. The dialect is
// also defined here: add_mlir_dialect accepts one root (SpBPFOps.td), whose
// included types need the dialect first. The original file list had no Base.td.

#ifndef SPBPF_TYPES
#define SPBPF_TYPES

include "mlir/IR/AttrTypeBase.td"
include "mlir/IR/OpBase.td"

def SpBPF_Dialect : Dialect {
  let name = "spbpf";
  let cppNamespace = "::mlir::spbpf";
  let summary = "general-purpose dialect holding only eBPF's own ownership, map and attach contracts";
  let description = [{
    Exclude Spinel/Ruby vocabulary. Spinel-specific facts belong to the spinel-ebpf extension layer.
  }];
  let useDefaultTypePrinterParser = 1;
}

class SpBPF_Type<string name, string typeMnemonic>
    : TypeDef<SpBPF_Dialect, name> {
  let mnemonic = typeMnemonic;
}

// !spbpf.ctx<"xdp"> retains the attach kind and its contract, such as permission to read a packet, which standard types cannot express.
def SpBPF_ContextType : SpBPF_Type<"Context", "ctx"> {
  let summary = "eBPF program context (the kind of attach point is part of the type)";
  let parameters = (ins StringRefParameter<"program kind">:$kind);
  let assemblyFormat = "`<` $kind `>`";
}

// !spbpf.map<"hash", i32, i64> retains key/value type parameters. Standard memrefs lack keyed lookup; these parameters enable key/value consistency checks.
def SpBPF_MapType : SpBPF_Type<"Map", "map"> {
  let summary = "BPF map (kind + key type + value type)";
  let parameters = (ins StringRefParameter<"map kind">:$kind,
                        "::mlir::Type":$keyType,
                        "::mlir::Type":$valueType);
  let assemblyFormat = "`<` $kind `,` $keyType `,` $valueType `>`";
}

// !spbpf.maybe_ref<i64> is an unchecked nullable map.lookup result. Standard types cannot enforce checking before obtaining a real reference; refuse dereference before reaching the kernel verifier.
def SpBPF_MaybeRefType : SpBPF_Type<"MaybeRef", "maybe_ref"> {
  let summary = "unchecked nullable reference";
  let parameters = (ins "::mlir::Type":$pointee);
  let assemblyFormat = "`<` $pointee `>`";
}

// !spbpf.borrowed<i64> is a checked borrowed reference obtainable only through maybe_ref checking.
def SpBPF_BorrowedType : SpBPF_Type<"Borrowed", "borrowed"> {
  let summary = "checked borrowed reference (does not own)";
  let parameters = (ins "::mlir::Type":$pointee);
  let assemblyFormat = "`<` $pointee `>`";
}

// !spbpf.record<"event", 48> identifies a schema payload by symbol and byte size. Schema core.records owns field order/offsets. The embedded size lets lowering reserve space without reading schema; --spbpf-verify-schema checks symbol/size agreement.
def SpBPF_RecordType : SpBPF_Type<"Record", "record"> {
  let summary = "ring buffer payload type pointing at a schema record (symbol + byte count)";
  let parameters = (ins StringRefParameter<"record symbol">:$symbol,
                        "int64_t":$size);
  let assemblyFormat = "`<` $symbol `,` $size `>`";
}

// !spbpf.reservation<i64> is linear: consume it exactly once with submit or discard. Standard dialect types/traits cannot express SSA-value consumption counts.
def SpBPF_ReservationType : SpBPF_Type<"Reservation", "reservation"> {
  let summary = "a **successful** ring buffer reservation (linear: consumed exactly once)";
  let parameters = (ins "::mlir::Type":$recordType);
  let assemblyFormat = "`<` $recordType `>`";
}

// !spbpf.maybe_reservation<i64> is unchecked. bpf_ringbuf_reserve may return NULL; omitting that fact forces lowering to invent null branches at each store/submit, hiding actual control flow from high-level IR. Mirror maybe_ref/ref.check to make checking explicit.
def SpBPF_MaybeReservationType : SpBPF_Type<"MaybeReservation", "maybe_reservation"> {
  let summary = "unchecked reservation (may not have succeeded)";
  let parameters = (ins "::mlir::Type":$recordType);
  let assemblyFormat = "`<` $recordType `>`";
}

#endif // SPBPF_TYPES
