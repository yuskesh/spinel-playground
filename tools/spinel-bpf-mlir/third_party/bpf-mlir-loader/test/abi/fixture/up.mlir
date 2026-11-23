// E015 の fixture: up (uprobe — bpf-mlir kernel/uprobe/fixture/bin/fixture の probe_target の入口、引数を読まない — hits[0] += 1・hits[1] =
// pid_tgid)・xp (xdp — 種類の取り違えの対照)。引数を読む uprobe は bpf-mlir の kernel/uprobe/mlir/arg_sum.mlir (E008 まで bml は uprobearg_unknown)
ebpf.program @up "uprobe" attach "probe_target" arch "x86_64" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"uprobe">, %hits: !ebpf.map<"array", i32, i64>):
  %pt = ebpf.task.pid_tgid : i64
  %k0 = arith.constant 0 : i32
  %k1 = arith.constant 1 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.map.update %hits[%k1], %pt : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}

ebpf.program @xp "xdp" maps [] {
^bb0(%ctx: !ebpf.ctx<"xdp">):
  ebpf.verdict "pass"
}
