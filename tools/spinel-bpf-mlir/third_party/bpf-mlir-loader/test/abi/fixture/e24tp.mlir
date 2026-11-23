// E024 の fixture: tp_btf/sched_process_fork — 親の tgid が hits[7] の fork だけ hits[0] += 1、hits[1] に子の pid (引数を読む — 6.6.157 は
// E247 の arg_nullable で load の前に止まる見込み)。形は bpf-mlir kernel/kfieldw/mlir/comm.mlir と同じ
ebpf.program @tp "tp_btf" attach "sched_process_fork" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"tp_btf">, %hits: !ebpf.map<"array", i32, i64>):
  %parent = ebpf.ctx.arg %ctx[0] : !ebpf.ctx<"tp_btf"> -> !ebpf.kptr<"task_struct">
  %child = ebpf.ctx.arg %ctx[1] : !ebpf.ctx<"tp_btf"> -> !ebpf.kptr<"task_struct">
  %k0 = arith.constant 0 : i32
  %k1 = arith.constant 1 : i32
  %k7 = arith.constant 7 : i32
  %one = arith.constant 1 : i64
  %w = ebpf.map.lookup %hits[%k7] : !ebpf.map<"array", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %w : !ebpf.maybe_ref<i64> present {
  ^p(%r: !ebpf.borrowed<i64>):
    %want = ebpf.ref.load %r : !ebpf.borrowed<i64> -> i64
    %ptg = ebpf.kfield.load %parent "tgid" : !ebpf.kptr<"task_struct"> -> i32
    %ptg64 = arith.extui %ptg : i32 to i64
    %same = arith.cmpi eq, %ptg64, %want : i64
    scf.if %same {
      %cpid = ebpf.kfield.load %child "pid" : !ebpf.kptr<"task_struct"> -> i32
      %cpid64 = arith.extui %cpid : i32 to i64
      ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
      ebpf.map.update %hits[%k1], %cpid64 : !ebpf.map<"array", i32, i64>, i32, i64
    }
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "done"
}
