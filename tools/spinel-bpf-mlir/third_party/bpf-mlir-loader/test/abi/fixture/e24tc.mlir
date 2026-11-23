// E024 の fixture: tp_btf/sched_process_fork (引数を読まない — 全ての fork で hits[0] += 1、6.6.157 の arg_nullable に止まらない形) と
// fentry (bpf_fentry_test1 — hits[2] += 1、種類の取り違えの対照)
ebpf.program @tc "tp_btf" attach "sched_process_fork" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"tp_btf">, %hits: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
ebpf.program @fe "fentry" attach "bpf_fentry_test1" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"fentry">, %hits: !ebpf.map<"array", i32, i64>):
  %k2 = arith.constant 2 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k2], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
