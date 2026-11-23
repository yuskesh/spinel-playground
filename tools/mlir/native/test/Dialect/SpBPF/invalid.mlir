// Negative verifier tests establish four acceptance requirements:
//   (1) Unknown program kind; (2) key/value mismatch.
//   (3) Direct unchecked nullable-reference use and borrowed-reference escape.\n(4) Double reservation consumption.\nThese checks express eBPF-specific rules absent from standard dialects.
//
// The standard split-input marker matches substrings, not only whole lines. Never write the literal
// marker in explanatory comments or it splits the input there.
// RUN: not spinel-mlirgen --spbpf-roundtrip %s 2>&1 | FileCheck %s

//===----------------------------------------------------------------------===//
// (1) Unknown program kind.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.program' op unknown program kind "kprobe"
// CHECK-SAME: known: "xdp"
spbpf.program @unknown_kind "kprobe" {
^bb0(%ctx: !spbpf.ctx<"kprobe">):
  spbpf.verdict "pass"
}

// -----
// Context/program kinds disagree, violating the attach contract.
// CHECK: 'spbpf.program' op context kind "tc" does not match program kind "xdp"
spbpf.program @ctx_mismatch "xdp" {
^bb0(%ctx: !spbpf.ctx<"tc">):
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// (2) Key/value mismatch.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.map.lookup' op key type 'i64' does not match map key type 'i32'
spbpf.program @bad_key "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i64
  %v = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i64 -> !spbpf.maybe_ref<i64>
  spbpf.verdict "pass"
}

// -----
// CHECK: 'spbpf.map.update' op value type 'i32' does not match map value type 'i64'
spbpf.program @bad_value "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %v = arith.constant 1 : i32
  spbpf.map.update %m[%k], %v : !spbpf.map<"hash", i32, i64>, i32, i32
  spbpf.verdict "pass"
}

// -----
// Lookup result does not reference the map value type.
// CHECK: 'spbpf.map.lookup' op result '!spbpf.maybe_ref<i32>' does not reference the map value type 'i64'
spbpf.program @bad_result "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %v = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i32>
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// (3) Read an unchecked nullable reference without ref.check.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.ref.load' op operand is an unchecked nullable reference '!spbpf.maybe_ref<i64>'
// CHECK: note: {{.*}}spbpf.ref.check
spbpf.program @unchecked_ref "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %cur = spbpf.ref.load %maybe : !spbpf.maybe_ref<i64> -> i64
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// (3-a) Borrowed reference escapes via region yield.
//
// The ref.check use scan reports this before yield verification: parent verification runs before
// nested-region verification.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.ref.check' op a borrowed reference may only be consumed by spbpf.ref.{load,store}
// CHECK-SAME: spbpf.yield
spbpf.program @escape_by_yield "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    spbpf.yield %ref : !spbpf.borrowed<i64>
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// (3-b) Store a borrowed reference in a map; aggregate storage follows the same refusal path.
// CHECK: 'spbpf.ref.check' op a borrowed reference may only be consumed by spbpf.ref.{load,store}
// CHECK-SAME: spbpf.map.update
spbpf.program @escape_into_map "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    spbpf.map.update %m[%k], %ref
        : !spbpf.map<"hash", i32, i64>, i32, !spbpf.borrowed<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// (3-c) Retain a borrowed reference across blocks.
// CHECK: 'spbpf.ref.check' op a borrowed reference may only be consumed by spbpf.ref.{load,store}
// CHECK-SAME: cf.br
spbpf.program @escape_across_blocks "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    cf.br ^later(%ref : !spbpf.borrowed<i64>)
  ^later(%held: !spbpf.borrowed<i64>):
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// (4) Double reservation consumption.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.ringbuf.if_reserved' op the reservation must be consumed exactly once
// CHECK-SAME: found 2
// CHECK: note: {{.*}}use-after-free
spbpf.program @double_consume "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ringbuf.submit %r : !spbpf.reservation<i64>
    spbpf.ringbuf.discard %r : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// An unconsumed reservation leaks and violates the same linearity rule.
// CHECK: 'spbpf.ringbuf.if_reserved' op the reservation must be consumed exactly once
// CHECK-SAME: found 0
// CHECK: note: {{.*}}leaks
spbpf.program @leaked "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// Unchecked reservations cannot pass directly to submit: explicit dialect nullability lets ODS
// reject them before custom verification. The kernel equivalent rejects ringbuf_mem_or_null where
// ringbuf_mem is required.
//
// The verifier also forbids store/submit/discard in absent regions, but this is structurally
// unreachable: an in-scope reservation there must have escaped an outer present region, already
// rejected by escape/linearity checks. Keep the rule defensively.
// CHECK: custom op 'spbpf.ringbuf.submit' invalid kind of type specified
// CHECK-SAME: expected spbpf.reservation, but found '!spbpf.maybe_reservation<i64>' 
spbpf.program @unchecked_reservation "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.submit %res : !spbpf.maybe_reservation<i64>
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// (4) Double reservation consumption.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.ringbuf.if_reserved' op the reservation must be consumed exactly once
// CHECK-SAME: found 2
// CHECK: note: {{.*}}use-after-free
spbpf.program @double_consume "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ringbuf.submit %r : !spbpf.reservation<i64>
    spbpf.ringbuf.discard %r : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// An unconsumed reservation leaks and violates the same linearity rule.
// CHECK: 'spbpf.ringbuf.if_reserved' op the reservation must be consumed exactly once
// CHECK-SAME: found 0
// CHECK: note: {{.*}}leaks
spbpf.program @leaked "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// Unchecked reservations cannot pass directly to submit: explicit dialect nullability lets ODS
// reject them before custom verification. The kernel equivalent rejects ringbuf_mem_or_null where
// ringbuf_mem is required.
//
// The verifier also forbids store/submit/discard in absent regions, but this is structurally
// unreachable: an in-scope reservation there must have escaped an outer present region, already
// rejected by escape/linearity checks. Keep the rule defensively.
// CHECK: custom op 'spbpf.ringbuf.submit' invalid kind of type specified
// CHECK-SAME: expected spbpf.reservation, but found '!spbpf.maybe_reservation<i64>' 
spbpf.program @unchecked_reservation "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.submit %res : !spbpf.maybe_reservation<i64>
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// Map argument/schema-symbol binding: initial checking covered structure/duplicates; later passes
// check existence and kind/key/value.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.program' op every map argument must be bound to a schema symbol: 1 map argument(s) but 0 symbol(s)
spbpf.program @unbound_map "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  spbpf.verdict "pass"
}

// -----
// CHECK: 'spbpf.program' op map symbol @dup is bound twice
spbpf.program @double_bound "xdp" maps [@dup, @dup] {
^bb0(%ctx: !spbpf.ctx<"xdp">,
     %a: !spbpf.map<"hash", i32, i64>,
     %b: !spbpf.map<"hash", i32, i64>):
  spbpf.verdict "pass"
}

// -----
// Attempt to bind context as a map.
// CHECK: 'spbpf.program' op only the first entry block argument may be a context
// CHECK-SAME: cannot be bound to a map symbol
spbpf.program @ctx_as_map "xdp" maps [@nope] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %ctx2: !spbpf.ctx<"xdp">):
  spbpf.verdict "pass"
}

// -----
//===----------------------------------------------------------------------===//
// Other refusals: invalid attach verdict, noninteger atomic add, unknown map kind.
//===----------------------------------------------------------------------===//
// CHECK: 'spbpf.verdict' op verdict "reject" is not valid for program kind "xdp"
spbpf.program @bad_verdict "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  spbpf.verdict "reject"
}

// -----
// CHECK: 'spbpf.map.atomic_add' op atomic add requires a signless integer map value type
spbpf.program @atomic_on_float "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, f64>):
  %k = arith.constant 0 : i32
  %d = arith.constant 1.0 : f64
  spbpf.map.atomic_add %m[%k], %d : !spbpf.map<"hash", i32, f64>, i32, f64
  spbpf.verdict "pass"
}

// -----
// CHECK: 'spbpf.map.lookup' op unknown map kind "lru_hash"
spbpf.program @unknown_map "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"lru_hash", i32, i64>):
  %k = arith.constant 0 : i32
  %v = spbpf.map.lookup %m[%k]
      : !spbpf.map<"lru_hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.verdict "pass"
}

// -----
// Record reservations require field writes; refuse whole-record stores.
// CHECK: 'spbpf.ringbuf.store' op a record reservation is written field by field
spbpf.program @whole_store_on_record "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 32>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 32>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 32>>):
    %v = arith.constant 1 : i64
    spbpf.ringbuf.store %res, %v : !spbpf.reservation<!spbpf.record<"event", 32>>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"event", 32>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// store_field requires a record reservation, not a scalar.
// CHECK: 'spbpf.ringbuf.store_field' op field stores need a record reservation
spbpf.program @field_store_on_scalar "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<i64> present {
  ^present(%res: !spbpf.reservation<i64>):
    %v = arith.constant 1 : i64
    spbpf.ringbuf.store_field %res[0], %v : !spbpf.reservation<i64>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// Refuse field stores beyond record size before schema matching; type alone establishes this.
// CHECK: 'spbpf.ringbuf.store_field' op field store at offset 28 (8 bytes) does not fit record "event" (32 bytes)
spbpf.program @field_store_out_of_range "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 32>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 32>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 32>>):
    %v = arith.constant 1 : i64
    spbpf.ringbuf.store_field %res[28], %v : !spbpf.reservation<!spbpf.record<"event", 32>>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"event", 32>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// -----
// Refuse writing unchecked nullable references, as for ref.load.
// CHECK: 'spbpf.ref.store' op operand is an unchecked nullable reference
spbpf.program @store_through_unchecked "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %v = arith.constant 1 : i64
  spbpf.ref.store %maybe, %v : !spbpf.maybe_ref<i64>, i64
  spbpf.verdict "pass"
}
