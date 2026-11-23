spbpf.program @count_packets "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m0: !spbpf.map<"array", i32, i64>):
  %v0 = arith.constant 0 : i32
  %v1 = arith.constant 1 : i64
  spbpf.map.atomic_add %m0[%v0], %v1 : !spbpf.map<"array", i32, i64>, i32, i64
  %v2 = arith.constant 0 : i32
  %v3 = spbpf.packet.load %ctx[%v2] : !spbpf.ctx<"xdp">, i32 -> i32
  %v4 = arith.constant 1 : i32
  %v5 = arith.extui %v3 : i32 to i64
  spbpf.map.update %m0[%v4], %v5 : !spbpf.map<"array", i32, i64>, i32, i64
  %v6 = spbpf.map.lookup %m0[%v0] : !spbpf.map<"array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %v7 = spbpf.ref.check %v6 : !spbpf.maybe_ref<i64> -> i64 present {
  ^present(%v8: !spbpf.borrowed<i64>):
    %v9 = spbpf.ref.load %v8 : !spbpf.borrowed<i64> -> i64
    spbpf.yield %v9 : i64
  } absent {
    %v10 = arith.constant 0 : i64
    spbpf.yield %v10 : i64
  }
  %v11 = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"tick", 8>>
  spbpf.ringbuf.if_reserved %v11 : !spbpf.maybe_reservation<!spbpf.record<"tick", 8>> present {
  ^present(%v12: !spbpf.reservation<!spbpf.record<"tick", 8>>):
    spbpf.ringbuf.store_field %v12[0], %v7 : !spbpf.reservation<!spbpf.record<"tick", 8>>, i64
    spbpf.ringbuf.submit %v12 : !spbpf.reservation<!spbpf.record<"tick", 8>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
