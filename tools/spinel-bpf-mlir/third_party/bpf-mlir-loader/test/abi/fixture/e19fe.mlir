// E019 の fixture: fentry だけ (bpf_fentry_test1 — hits[0] += 1) — 権限の組ごとの load の表
ebpf.program @fe "fentry" attach "bpf_fentry_test1" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"fentry">, %hits: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
