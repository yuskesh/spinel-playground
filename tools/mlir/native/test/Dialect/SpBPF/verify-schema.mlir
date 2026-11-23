// Match map bindings with canonical schema, connecting the former structure/duplicate-only verifier
// to schema-side validation.
//
// Schema: %S/../../Target/SpBPF/schema-roundtrip.json (counts: hash<i32,i64>,
// events: ringbuf).
//
// RUN: not spbpf-opt --spbpf-verify-schema=schema=%S/Inputs/schema-verify.json %s 2>&1 \
// RUN:   | FileCheck %s

// Symbol absent from schema.
// CHECK: 'spbpf.program' op map symbol @nosuch is not declared in the schema
spbpf.program @unknown_symbol "xdp" maps [@nosuch] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  spbpf.verdict "pass"
}

// Kind mismatch: counts is hash.
// CHECK: 'spbpf.program' op map @counts is declared "hash" in the schema but bound as "array"
spbpf.program @wrong_kind "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"array", i32, i64>):
  spbpf.verdict "pass"
}

// Key mismatch: counts key is 32-bit.
// CHECK: 'spbpf.program' op map @counts key type 'i64' does not match the schema (u32)
spbpf.program @wrong_key "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i64, i64>):
  spbpf.verdict "pass"
}

// Value mismatch: counts value is 64-bit.
// CHECK: 'spbpf.program' op map @counts value type 'i32' does not match the schema (u64)
spbpf.program @wrong_value "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i32>):
  spbpf.verdict "pass"
}

// Match ring-buffer string names too.
// CHECK: 'spbpf.ringbuf.reserve' op ring buffer "nosuchrb" is not declared in the schema
spbpf.program @unknown_ringbuf "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "nosuchrb" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<i64> present {
  ^present(%res: !spbpf.reservation<i64>):
    spbpf.ringbuf.submit %res : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Use a non-ringbuf map as a ring buffer.
// CHECK: 'spbpf.ringbuf.reserve' op "counts" is declared in the schema but is not a ringbuf map
spbpf.program @not_a_ringbuf "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "counts" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<i64> present {
  ^present(%res: !spbpf.reservation<i64>):
    spbpf.ringbuf.discard %res : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Match record reservations and store_field.

// Scalar reservation for a record ring buffer, formerly unchecked.
// CHECK: 'spbpf.ringbuf.reserve' op the schema ringbuf "events" carries record "event" but the reservation type is 'i64'
spbpf.program @scalar_reserve_on_record_ringbuf "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<i64> present {
  ^present(%res: !spbpf.reservation<i64>):
    spbpf.ringbuf.discard %res : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Reserve a different record.
// CHECK: 'spbpf.ringbuf.reserve' op reserves record "hdr" but the schema ringbuf "events" carries record "event"
spbpf.program @wrong_record_symbol "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"hdr", 16>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"hdr", 16>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"hdr", 16>>):
    spbpf.ringbuf.discard %res : !spbpf.reservation<!spbpf.record<"hdr", 16>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Size mismatch: embedded reservation size would reserve different storage.
// CHECK: 'spbpf.ringbuf.reserve' op record "event" is 48 bytes in the schema but the reservation type says 40
spbpf.program @wrong_record_size "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 40>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 40>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 40>>):
    spbpf.ringbuf.discard %res : !spbpf.reservation<!spbpf.record<"event", 40>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Store at an offset with no integer field, inside comm[16] array payload.
// CHECK: 'spbpf.ringbuf.store_field' op no integer field of record "event" sits at offset 20 with width 32 bits
spbpf.program @store_field_bad_offset "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 48>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 48>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 48>>):
    %v = arith.constant 1 : i32
    spbpf.ringbuf.store_field %res[20], %v : !spbpf.reservation<!spbpf.record<"event", 48>>, i32
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"event", 48>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Field exists but width differs: pid is u32.
// CHECK: 'spbpf.ringbuf.store_field' op no integer field of record "event" sits at offset 32 with width 64 bits
spbpf.program @store_field_wrong_width "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 48>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 48>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 48>>):
    %v = arith.constant 1 : i64
    spbpf.ringbuf.store_field %res[32], %v : !spbpf.reservation<!spbpf.record<"event", 48>>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"event", 48>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// Undeclared program: earlier schema checks allowed another-name declaration, discovering it only
// at load time.
// CHECK: 'spbpf.program' op program @nosuchprog is not declared in the schema
spbpf.program @nosuchprog "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  spbpf.verdict "pass"
}
