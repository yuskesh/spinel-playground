// E015: bpf-mlir kernel/uprobe/mlir/arg_sum.mlir (v0.17.0 — 72e700bb) の読むだけの複写 — 引数を読む uprobe (E008 まで bml は uprobearg_unknown で止め、Go の loader は load する — 名指しの差)
// E104 case arg_sum — fixture の probe_target(uint32_t a, uint64_t b) の入口の uprobe で、a と b を tgid ごとに足し、呼び出しの回数も数える (C の arg_sum と同じ意味)
ebpf.program @prog "uprobe" attach "probe_target" arch "x86_64" maps [@counts, @suma, @sumb] {
^bb0(%ctx: !ebpf.ctx<"uprobe">, %counts: !ebpf.map<"hash", i32, i64>, %suma: !ebpf.map<"hash", i32, i64>, %sumb: !ebpf.map<"hash", i32, i64>):
  %pt = ebpf.task.pid_tgid : i64
  %c32 = arith.constant 32 : i64
  %hi = arith.shrui %pt, %c32 : i64
  %tg = arith.trunci %hi : i64 to i32
  %a = ebpf.uprobe.arg %ctx 1 : !ebpf.ctx<"uprobe"> -> i32
  %a64 = arith.extui %a : i32 to i64
  %b64 = ebpf.uprobe.arg %ctx 2 : !ebpf.ctx<"uprobe"> -> i64
  %one = arith.constant 1 : i64
  %m = ebpf.map.lookup %counts[%tg] : !ebpf.map<"hash", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %m : !ebpf.maybe_ref<i64> present {
  ^p(%r: !ebpf.borrowed<i64>):
    ebpf.ref.atomic_add %r, %one : !ebpf.borrowed<i64>, i64
    ebpf.yield
  } absent {
    %st = ebpf.map.try_update %counts[%tg], %one flags "noexist" : !ebpf.map<"hash", i32, i64>, i32, i64 -> i64
    ebpf.yield
  }
  %sa = ebpf.map.lookup %suma[%tg] : !ebpf.map<"hash", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %sa : !ebpf.maybe_ref<i64> present {
  ^p(%r: !ebpf.borrowed<i64>):
    ebpf.ref.atomic_add %r, %a64 : !ebpf.borrowed<i64>, i64
    ebpf.yield
  } absent {
    %st = ebpf.map.try_update %suma[%tg], %a64 flags "noexist" : !ebpf.map<"hash", i32, i64>, i32, i64 -> i64
    ebpf.yield
  }
  %sb = ebpf.map.lookup %sumb[%tg] : !ebpf.map<"hash", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %sb : !ebpf.maybe_ref<i64> present {
  ^p(%r: !ebpf.borrowed<i64>):
    ebpf.ref.atomic_add %r, %b64 : !ebpf.borrowed<i64>, i64
    ebpf.yield
  } absent {
    %st = ebpf.map.try_update %sumb[%tg], %b64 flags "noexist" : !ebpf.map<"hash", i32, i64>, i32, i64 -> i64
    ebpf.yield
  }
  ebpf.verdict "done"
}
