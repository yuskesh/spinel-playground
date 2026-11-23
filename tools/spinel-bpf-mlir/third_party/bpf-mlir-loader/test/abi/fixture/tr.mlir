// E012 の fixture: fentry / fexit (bpf_fentry_test1 — kernel の BPF_PROG_TEST_RUN の tracing が呼ぶ)・kprobe (do_sys_poll — ctl[0] の tid の
// 呼び出しだけ)・xdp (種類の取り違えの対照)。hits: 0 fe の回数・1 fe の最後の pid_tgid・2 fx の回数・3 fx の最後の戻り値 (i64)・
// 4 kp の回数・5 kp の最後の nfds・6 kp の最後の pid_tgid
ebpf.program @fe "fentry" attach "bpf_fentry_test1" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"fentry">, %hits: !ebpf.map<"array", i32, i64>):
  %pt = ebpf.task.pid_tgid : i64
  %k0 = arith.constant 0 : i32
  %k1 = arith.constant 1 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.map.update %hits[%k1], %pt : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}

ebpf.program @fx "fexit" attach "bpf_fentry_test1" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"fexit">, %hits: !ebpf.map<"array", i32, i64>):
  %ret = ebpf.ctx.retval %ctx after 1 : !ebpf.ctx<"fexit"> -> i32
  %v = arith.extsi %ret : i32 to i64
  %k2 = arith.constant 2 : i32
  %k3 = arith.constant 3 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k2], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.map.update %hits[%k3], %v : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}

ebpf.program @kp "kprobe" attach "do_sys_poll" arch "x86_64" maps [@ctl, @hits] {
^bb0(%ctx: !ebpf.ctx<"kprobe">, %ctl: !ebpf.map<"array", i32, i64>, %hits: !ebpf.map<"array", i32, i64>):
  %pt = ebpf.task.pid_tgid : i64
  %c32 = arith.constant 0xffffffff : i64
  %tid = arith.andi %pt, %c32 : i64
  %k0 = arith.constant 0 : i32
  %m = ebpf.map.lookup %ctl[%k0] : !ebpf.map<"array", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %m : !ebpf.maybe_ref<i64> present {
  ^p(%w: !ebpf.borrowed<i64>):
    %want = ebpf.ref.load %w : !ebpf.borrowed<i64> -> i64
    %eq = arith.cmpi eq, %tid, %want : i64
    ebpf.if %eq {
      %a = ebpf.kprobe.arg %ctx 2 : !ebpf.ctx<"kprobe"> -> i32
      %a64 = arith.extui %a : i32 to i64
      %k4 = arith.constant 4 : i32
      %k5 = arith.constant 5 : i32
      %k6 = arith.constant 6 : i32
      %one = arith.constant 1 : i64
      ebpf.map.atomic_add %hits[%k4], %one : !ebpf.map<"array", i32, i64>, i32, i64
      ebpf.map.update %hits[%k5], %a64 : !ebpf.map<"array", i32, i64>, i32, i64
      ebpf.map.update %hits[%k6], %pt : !ebpf.map<"array", i32, i64>, i32, i64
      ebpf.if.yield
    } else {
      ebpf.if.yield
    }
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "done"
}

ebpf.program @xp "xdp" maps [] {
^bb0(%ctx: !ebpf.ctx<"xdp">):
  ebpf.verdict "pass"
}
