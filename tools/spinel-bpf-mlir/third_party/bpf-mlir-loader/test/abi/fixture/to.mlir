// E017 の fixture (試験の口): ring buffer ev (record evr — 8 byte の v)・array cnt (freeze の試験)・.rodata の want (load の後の直の書き込みの試験)。
// xp: cnt[0] += 1、ev に v = want を 1 つ送る
ebpf.program @xp "xdp" maps [@cnt] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %cnt: !ebpf.map<"array", i32, i64>):
  %w = ebpf.global.load @want : i64
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %cnt[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  %r = ebpf.ringbuf.reserve "ev" : !ebpf.maybe_reservation<!ebpf.record<"evr", 8>>
  ebpf.ringbuf.if_reserved %r : !ebpf.maybe_reservation<!ebpf.record<"evr", 8>> present {
  ^q(%res: !ebpf.reservation<!ebpf.record<"evr", 8>>):
    %e = ebpf.record.make ["v"] (%w) : (i64) -> !ebpf.record<"evr", 8>
    ebpf.ringbuf.store_record %res, %e : !ebpf.reservation<!ebpf.record<"evr", 8>>, !ebpf.record<"evr", 8>
    ebpf.ringbuf.submit %res : !ebpf.reservation<!ebpf.record<"evr", 8>>
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "pass"
}
