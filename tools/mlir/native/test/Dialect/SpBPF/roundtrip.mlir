// Correct SpBPF programs parse, verify and print. Standard arith/control-flow dialects retain
// ordinary computation; SpBPF holds only eBPF-specific contracts.
// RUN: spinel-mlirgen --spbpf-roundtrip %s | FileCheck %s
// Printed output must parse again and meet the same CHECK assertions.
// RUN: spinel-mlirgen --spbpf-roundtrip %s | spinel-mlirgen --spbpf-roundtrip - | FileCheck %s
//
// MLIR omits a dialect prefix in its own operation type positions: maybe_ref prints as <i64>, not
// !spbpf.maybe_ref<i64>. Block argument types remain qualified. The second RUN checks the
// abbreviated form parses.

// Map arguments bind positionally to schema symbols.
// CHECK-LABEL: spbpf.program @count_packets "xdp" maps [@exec_count]
// CHECK: ^bb0(%[[CTX:.*]]: !spbpf.ctx<"xdp">, %[[M:.*]]: !spbpf.map<"hash", i32, i64>):
spbpf.program @count_packets "xdp" maps [@exec_count] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %counts: !spbpf.map<"hash", i32, i64>):
  %off = arith.constant 0 : i32
  // CHECK: spbpf.packet.load
  %key = spbpf.packet.load %ctx[%off] : !spbpf.ctx<"xdp">, i32 -> i32

  // lookup returns an unchecked nullable reference.
  // CHECK: spbpf.map.lookup {{.*}} -> <i64>
  %maybe = spbpf.map.lookup %counts[%key]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>

  // Borrowed references exist only as present-region block arguments and live only there.
  // CHECK: spbpf.ref.check {{.*}} present {
  // CHECK: ^bb0(%[[REF:.*]]: !spbpf.borrowed<i64>):
  // CHECK: spbpf.ref.load
  // CHECK: spbpf.yield
  // CHECK: } absent {
  // CHECK: spbpf.yield
  %zero = arith.constant 0 : i64
  %cur = spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> -> i64 present {
  ^present(%ref: !spbpf.borrowed<i64>):
    %v = spbpf.ref.load %ref : !spbpf.borrowed<i64> -> i64
    spbpf.yield %v : i64
  } absent {
    spbpf.yield %zero : i64
  }

  %one = arith.constant 1 : i64
  // CHECK: spbpf.map.atomic_add
  spbpf.map.atomic_add %counts[%key], %one
      : !spbpf.map<"hash", i32, i64>, i32, i64
  // CHECK: spbpf.map.update
  spbpf.map.update %counts[%key], %cur
      : !spbpf.map<"hash", i32, i64>, i32, i64

  // Reservation can fail; writes require the checked present region.
  // CHECK: spbpf.ringbuf.reserve "events"
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  // CHECK: spbpf.ringbuf.if_reserved
  // CHECK: ^bb0(%{{.*}}: !spbpf.reservation<i64>):
  // CHECK: spbpf.ringbuf.store
  // CHECK: spbpf.ringbuf.submit
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ringbuf.store %r, %cur : !spbpf.reservation<i64>, i64
    spbpf.ringbuf.submit %r : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }

  // CHECK: spbpf.verdict "pass"
  spbpf.verdict "pass"
}

// Programs with no maps may omit the maps clause. discard also consumes a reservation.
// CHECK-LABEL: spbpf.program @drop_all "xdp"
// CHECK-NOT: maps
spbpf.program @drop_all "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  // CHECK: spbpf.ringbuf.discard
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ringbuf.discard %r : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  // CHECK: spbpf.verdict "drop"
  spbpf.verdict "drop"
}

// ref.check may return no values and test presence only.
// CHECK-LABEL: spbpf.program @probe "xdp" maps [@a, @b]
spbpf.program @probe "xdp" maps [@a, @b] {
^bb0(%ctx: !spbpf.ctx<"xdp">,
     %a: !spbpf.map<"array", i32, i64>,
     %b: !spbpf.map<"hash", i64, i64>):
  %k = arith.constant 0 : i32
  %m = spbpf.map.lookup %a[%k]
      : !spbpf.map<"array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  // CHECK: spbpf.ref.check
  spbpf.ref.check %m : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}

// Roundtrip record reservation/field writes/ktime/ref.store/percpu_array.
// CHECK-LABEL: spbpf.program @emit_record_roundtrip "xdp" maps [@lost]
spbpf.program @emit_record_roundtrip "xdp" maps [@lost] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %lost: !spbpf.map<"percpu_array", i32, i64>):
  // CHECK: spbpf.ringbuf.reserve "events" : <!spbpf.record<"pair_event", 32>>
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"pair_event", 32>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"pair_event", 32>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"pair_event", 32>>):
    // CHECK: spbpf.ktime.ns : i64
    %ts = spbpf.ktime.ns : i64
    // CHECK: spbpf.ringbuf.store_field {{.*}}[8]
    spbpf.ringbuf.store_field %res[8], %ts : !spbpf.reservation<!spbpf.record<"pair_event", 32>>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"pair_event", 32>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  %k = arith.constant 0 : i32
  %p = spbpf.map.lookup %lost[%k]
      : !spbpf.map<"percpu_array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %p : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    %cur = spbpf.ref.load %ref : !spbpf.borrowed<i64> -> i64
    %one = arith.constant 1 : i64
    %next = arith.addi %cur, %one : i64
    // CHECK: spbpf.ref.store
    spbpf.ref.store %ref, %next : !spbpf.borrowed<i64>, i64
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
