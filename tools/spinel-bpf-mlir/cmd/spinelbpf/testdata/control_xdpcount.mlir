// E005 の対照: examples/xdpcount の eBPF の側 (count_pkts) を手で書いた .mlir (loc 無し)。frontend の出力の写しではなく、
// P001 §3.4 の表 (atomic_add → map.atomic_add、lookup + if → map.lookup + ref.check、p.load → ref.load、update → map.update、XDP_PASS → verdict) から書いた。
ebpf.program @count_pkts "xdp" maps [@Counts] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %counts: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %counts[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  %k0b = arith.constant 0 : i32
  %r = ebpf.map.lookup %counts[%k0b] : !ebpf.map<"array", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %r : !ebpf.maybe_ref<i64> present {
  ^present(%p: !ebpf.borrowed<i64>):
    %k1 = arith.constant 1 : i32
    %v = ebpf.ref.load %p : !ebpf.borrowed<i64> -> i64
    ebpf.map.update %counts[%k1], %v : !ebpf.map<"array", i32, i64>, i32, i64
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "pass"
}
