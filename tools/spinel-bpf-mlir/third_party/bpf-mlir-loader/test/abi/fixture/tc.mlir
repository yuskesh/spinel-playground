// E013 の fixture: ti (tcx ingress — cnt[0] += 1、[0, 16) が在り byte 12 / 13 が 0x08 0x00 (IPv4) なら drop、他は pass)・te (tcx egress —
// cnt[1] += 1、pass)・xp (xdp — 種類の取り違えの対照)。drop は 2 (TC_ACT_SHOT)、pass は 0
ebpf.program @ti "sched_cls" attach "ingress" maps [@cnt] {
^bb0(%ctx: !ebpf.ctx<"sched_cls">, %cnt: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %cnt[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  %c0 = arith.constant 0 : i32
  %drop = ebpf.packet.check %ctx[%c0] len 16 : !ebpf.ctx<"sched_cls">, i32 -> i1 in_range {
  ^bb0(%w: !ebpf.pkt_window<16>):
    %o12 = arith.constant 12 : i32
    %b12 = ebpf.packet.load %ctx[%o12] : !ebpf.ctx<"sched_cls">, i32 -> i8
    %o13 = arith.constant 13 : i32
    %b13 = ebpf.packet.load %ctx[%o13] : !ebpf.ctx<"sched_cls">, i32 -> i8
    %x08 = arith.constant 8 : i8
    %x00 = arith.constant 0 : i8
    %e12 = arith.cmpi eq, %b12, %x08 : i8
    %e13 = arith.cmpi eq, %b13, %x00 : i8
    %ip = arith.andi %e12, %e13 : i1
    ebpf.yield %ip : i1
  } out_of_range {
    %f = arith.constant false
    ebpf.yield %f : i1
  }
  ebpf.verdict.if %drop "drop" else "pass"
}

ebpf.program @te "sched_cls" attach "egress" maps [@cnt] {
^bb0(%ctx: !ebpf.ctx<"sched_cls">, %cnt: !ebpf.map<"array", i32, i64>):
  %k1 = arith.constant 1 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %cnt[%k1], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "pass"
}

ebpf.program @xp "xdp" maps [] {
^bb0(%ctx: !ebpf.ctx<"xdp">):
  ebpf.verdict "pass"
}
