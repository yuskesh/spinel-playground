// E019 の fixture: fexit だけ (bpf_fentry_test1 — hits[0] += 1)
ebpf.program @fx "fexit" attach "bpf_fentry_test1" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"fexit">, %hits: !ebpf.map<"array", i32, i64>):
  %ret = ebpf.ctx.retval %ctx after 1 : !ebpf.ctx<"fexit"> -> i32
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
