// E019 の fixture: xdp だけ (hits[0] += 1)
ebpf.program @xp "xdp" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %hits: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "pass"
}
