// E025 の fixture: 存在しない kernel の関数への kprobe (attach は libbpf の perf event の作成で失敗し、libbpf が warning を print する)。
// 照合する load は Unmet で止まる — 試験は試験の口の照合しない load で
ebpf.program @kp "kprobe" attach "bml_e025_no_such_function" arch "x86_64" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"kprobe">, %hits: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
