// SpBPF operations, the add_mlir_dialect root. Only eBPF-specific helpers/maps/attach/ownership
// belong here; arithmetic, branches and loops use arith/cf/scf/func.

#ifndef SPBPF_OPS
#define SPBPF_OPS

include "mlir/IR/OpBase.td"
include "mlir/IR/SymbolInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "SpBPFTypes.td"

class SpBPF_Op<string mnemonic, list<Trait> traits = []>
    : Op<SpBPF_Dialect, mnemonic, traits>;

// spbpf.program is an attach unit: accepts entry-block context and ends with verdict. Its verifier
// checks reservation linearity across the entire region.
def SpBPF_ProgramOp : SpBPF_Op<"program",
    [IsolatedFromAbove, SingleBlock, Symbol]> {
  let summary = "eBPF program (with the kind of attach point)";
  let description = [{
    Entry arguments are one context plus zero or more map handles. Schema owns capacity/flags/BTF; maps [...] positionally associates handles with schema symbols, which lowering turns into ELF map-symbol relocations.
  }];
  let arguments = (ins SymbolNameAttr:$sym_name, StrAttr:$kind,
                       OptionalAttr<SymbolRefArrayAttr>:$map_symbols);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat =
      "$sym_name $kind (`maps` $map_symbols^)? attr-dict-with-keyword $body";
  let hasVerifier = 1;
}

// spbpf.verdict terminates a program; allowed verdicts depend on attach kind.
def SpBPF_VerdictOp : SpBPF_Op<"verdict",
    [Terminator, HasParent<"ProgramOp">]> {
  let summary = "return the program's verdict and end";
  let arguments = (ins StrAttr:$action);
  let assemblyFormat = "$action attr-dict";
  let hasVerifier = 1;
}

// Map key/value operands must match the map type parameters.
def SpBPF_MapLookupOp : SpBPF_Op<"map.lookup"> {
  let summary = "look up a map (the result is an unchecked nullable reference)";
  let arguments = (ins SpBPF_MapType:$map, AnyType:$key);
  let results = (outs SpBPF_MaybeRefType:$result);
  let assemblyFormat =
      "$map `[` $key `]` attr-dict `:` type($map) `,` type($key) `->` type($result)";
  let hasVerifier = 1;
}

def SpBPF_MapUpdateOp : SpBPF_Op<"map.update"> {
  let summary = "update a map";
  let arguments = (ins SpBPF_MapType:$map, AnyType:$key, AnyType:$value);
  let assemblyFormat =
      "$map `[` $key `]` `,` $value attr-dict `:` type($map) `,` type($key) `,` type($value)";
  let hasVerifier = 1;
}

def SpBPF_MapAtomicAddOp : SpBPF_Op<"map.atomic_add"> {
  let summary = "add atomically to a map value";
  let arguments = (ins SpBPF_MapType:$map, AnyType:$key, AnyType:$delta);
  let assemblyFormat =
      "$map `[` $key `]` `,` $delta attr-dict `:` type($map) `,` type($key) `,` type($delta)";
  let hasVerifier = 1;
}

// Reference checking/loading. The initial operation list omitted both producer and consumer of
// borrowed<T>, leaving that type unusable. Add the minimal ref.check/ref.load pair to close that
// specification gap.
def SpBPF_RefCheckOp : SpBPF_Op<"ref.check", [RecursiveMemoryEffects]> {
  let summary = "check a nullable reference, and derive a borrowed reference only inside the present region";
  let description = [{
    This is not an unsafe unwrap: borrowed<T> exists only as a present-region block argument and lives only there. No operation produces it as a result, so no direct nullable-to-borrowed path exists. The verifier refuses yielding it outside, retaining it across blocks, or storing it in maps/aggregates.
  }];
  let arguments = (ins SpBPF_MaybeRefType:$ref);
  let results = (outs Variadic<AnyType>:$results);
  let regions = (region AnyRegion:$presentRegion, AnyRegion:$absentRegion);
  let assemblyFormat = [{
    $ref attr-dict `:` type($ref) (`->` type($results)^)?
    `present` $presentRegion `absent` $absentRegion
  }];
  let hasVerifier = 1;
}

def SpBPF_YieldOp : SpBPF_Op<"yield",
    [Terminator, ParentOneOf<["RefCheckOp", "RingbufIfReservedOp"]>]> {
  let summary = "yield a value from the region of spbpf.ref.check";
  let arguments = (ins Variadic<AnyType>:$results);
  let assemblyFormat = "($results^ `:` type($results))? attr-dict";
  let hasVerifier = 1;
}

// Write through a borrowed reference, paired with ref.load for per-CPU lost-counter increments
// (lookup, load, +1, store). Its lifetime remains restricted to the present region.
def SpBPF_RefStoreOp : SpBPF_Op<"ref.store"> {
  // AnyType is deliberate, as for ref.load: a borrowed-only ODS constraint would replace the
  // unchecked-reference cause with a generic type-mismatch diagnostic.
  let summary = "write through a borrowed reference (unchecked references are rejected)";
  let arguments = (ins AnyType:$ref, AnyType:$value);
  let assemblyFormat = "$ref `,` $value attr-dict `:` type($ref) `,` type($value)";
  let hasVerifier = 1;
}

def SpBPF_RefLoadOp : SpBPF_Op<"ref.load"> {
  // AnyType is deliberate: a borrowed-only ODS constraint would hide the unchecked-reference cause
  // behind a generic type-mismatch diagnostic.
  let summary = "read through a borrowed reference (unchecked references are rejected)";
  let arguments = (ins AnyType:$ref);
  let results = (outs AnyType:$result);
  let assemblyFormat = "$ref attr-dict `:` type($ref) `->` type($result)";
  let hasVerifier = 1;
}

// Read a packet; the context type determines whether the attach kind supplies one.
def SpBPF_PacketLoadOp : SpBPF_Op<"packet.load"> {
  let summary = "read an integer from the context's packet";
  let arguments = (ins SpBPF_ContextType:$ctx, AnySignlessInteger:$offset);
  let results = (outs AnySignlessInteger:$result);
  let assemblyFormat =
      "$ctx `[` $offset `]` attr-dict `:` type($ctx) `,` type($offset) `->` type($result)";
  let hasVerifier = 1;
}

// spbpf.ktime.ns reads the monotonic clock for record hdr.timestamp. Only the lowering target
// profile knows helper numbers.
def SpBPF_KtimeOp : SpBPF_Op<"ktime.ns"> {
  let summary = "the value of bpf_ktime_get_ns()";
  let results = (outs I64:$result);
  let assemblyFormat = "attr-dict `:` type($result)";
}

// Every ring-buffer reservation must be consumed exactly once by submit or discard.
def SpBPF_RingbufReserveOp : SpBPF_Op<"ringbuf.reserve"> {
  let summary = "reserve space in a ring buffer (may fail)";
  let arguments = (ins StrAttr:$ringbuf);
  let results = (outs SpBPF_MaybeReservationType:$result);
  let assemblyFormat = "$ringbuf attr-dict `:` type($result)";
}

// spbpf.ringbuf.if_reserved checks success. A successful !spbpf.reservation<T> exists only as a
// present-region block argument, never as an operation result; unchecked use is structurally
// impossible, as with ref.check.
def SpBPF_RingbufIfReservedOp : SpBPF_Op<"ringbuf.if_reserved",
    [RecursiveMemoryEffects]> {
  let summary = "run the present region only when the reservation succeeded";
  let arguments = (ins SpBPF_MaybeReservationType:$reservation);
  let regions = (region AnyRegion:$presentRegion, AnyRegion:$absentRegion);
  let assemblyFormat = [{
    $reservation attr-dict `:` type($reservation)
    `present` $presentRegion `absent` $absentRegion
  }];
  let hasVerifier = 1;
}

// The initial operation list also omitted reservation writes, preventing ring buffers from carrying
// contents. Add this operation as with ref.check/ref.load.
def SpBPF_RingbufStoreOp : SpBPF_Op<"ringbuf.store"> {
  let summary = "write a value into the reserved space";
  let arguments = (ins SpBPF_ReservationType:$reservation, AnyType:$value);
  let assemblyFormat =
      "$reservation `,` $value attr-dict `:` type($reservation) `,` type($value)";
  let hasVerifier = 1;
}

// Write a record field by byte offset. Schema owns field layout; --spbpf-verify-schema checks that
// the offset names a field. The dialect verifier checks only record-size bounds, keeping schema out
// of the dialect.
def SpBPF_RingbufStoreFieldOp : SpBPF_Op<"ringbuf.store_field"> {
  let summary = "write an integer to a field (byte offset) of the reserved record";
  let arguments = (ins SpBPF_ReservationType:$reservation,
                       AnySignlessInteger:$value, I64Attr:$offset);
  let assemblyFormat =
      "$reservation `[` $offset `]` `,` $value attr-dict `:` type($reservation) `,` type($value)";
  let hasVerifier = 1;
}

def SpBPF_RingbufSubmitOp : SpBPF_Op<"ringbuf.submit"> {
  let summary = "commit the reservation (consumes it)";
  let arguments = (ins SpBPF_ReservationType:$reservation);
  let assemblyFormat = "$reservation attr-dict `:` type($reservation)";
}

def SpBPF_RingbufDiscardOp : SpBPF_Op<"ringbuf.discard"> {
  let summary = "discard the reservation (consumes it)";
  let arguments = (ins SpBPF_ReservationType:$reservation);
  let assemblyFormat = "$reservation attr-dict `:` type($reservation)";
}

#endif // SPBPF_OPS
