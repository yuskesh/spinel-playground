spbpf.program @count_packets "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m0: !spbpf.map<"array", i32, i64>):
  %v0 = arith.constant 0 : i32
  %v1 = spbpf.packet.load %ctx[%v0] : !spbpf.ctx<"xdp">, i32 -> i32
  %v2 = arith.constant 1 : i64
  spbpf.map.atomic_add %m0[%v1], %v2 : !spbpf.map<"array", i32, i64>, i32, i64
  %v3 = spbpf.map.lookup %m0[%v1] : !spbpf.map<"array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %v4 = spbpf.ref.check %v3 : !spbpf.maybe_ref<i64> -> i64 present {
  ^present(%v5: !spbpf.borrowed<i64>):
    %v6 = spbpf.ref.load %v5 : !spbpf.borrowed<i64> -> i64
    spbpf.yield %v6 : i64
  } absent {
    %v7 = arith.constant 0 : i64
    spbpf.yield %v7 : i64
  }
  spbpf.map.update %m0[%v1], %v4 : !spbpf.map<"array", i32, i64>, i32, i64
  %v8 = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"tick", 8>>
  spbpf.ringbuf.if_reserved %v8 : !spbpf.maybe_reservation<!spbpf.record<"tick", 8>> present {
  ^present(%v9: !spbpf.reservation<!spbpf.record<"tick", 8>>):
    spbpf.ringbuf.store_field %v9[0], %v4 : !spbpf.reservation<!spbpf.record<"tick", 8>>, i64
    spbpf.ringbuf.submit %v9 : !spbpf.reservation<!spbpf.record<"tick", 8>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
