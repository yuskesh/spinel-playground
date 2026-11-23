// Schema-matching positive control. Record ring buffers reserve !spbpf.record<symbol,size> and
// write fields by byte offset; match symbol/size/offset/width. The earlier i64 reservation bypassed
// layout checks, a gap now closed.
// RUN: spbpf-opt --spbpf-verify-schema=schema=%S/Inputs/schema-ok.json %s | FileCheck %s
// CHECK-LABEL: spbpf.program @agrees "xdp" maps [@counts, @lost]
spbpf.program @agrees "xdp" maps [@counts, @lost] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>,
     %lost: !spbpf.map<"percpu_array", i32, i64>):
  // percpu_array lost counter: lookup, check, +1, ref.store.
  %lk = arith.constant 0 : i32
  %lp = spbpf.map.lookup %lost[%lk]
      : !spbpf.map<"percpu_array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %lp : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    %cur = spbpf.ref.load %ref : !spbpf.borrowed<i64> -> i64
    %one = arith.constant 1 : i64
    %next = arith.addi %cur, %one : i64
    spbpf.ref.store %ref, %next : !spbpf.borrowed<i64>, i64
    spbpf.yield
  } absent {
    spbpf.yield
  }
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"event", 48>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"event", 48>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"event", 48>>):
    // Nested record_ref hdr field offsets are accumulated during matching.
    %kind = arith.constant 1 : i32
    spbpf.ringbuf.store_field %res[0], %kind : !spbpf.reservation<!spbpf.record<"event", 48>>, i32
    %ts = spbpf.ktime.ns : i64
    spbpf.ringbuf.store_field %res[8], %ts : !spbpf.reservation<!spbpf.record<"event", 48>>, i64
    %pid = arith.constant 42 : i32
    spbpf.ringbuf.store_field %res[32], %pid : !spbpf.reservation<!spbpf.record<"event", 48>>, i32
    %dur = arith.constant 7 : i64
    spbpf.ringbuf.store_field %res[40], %dur : !spbpf.reservation<!spbpf.record<"event", 48>>, i64
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"event", 48>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
