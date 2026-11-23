// E056 の H3 の fixture: test/abi/fixture/e56/e56.c の e56_fn の入口の uprobe (hits[0] += 1) と戻りの uretprobe (hits[1] += 1)。引数も戻り値も読まない
// (DWARF の照合は要らない — symbol の解決だけを試す)。schema の binary_sha256 は scripts/e56-attach-target.sh が作った dynsym の本体の sha256 に置き換える
ebpf.program @up "uprobe" attach "e56_fn" arch "x86_64" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"uprobe">, %hits: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}

ebpf.program @ur "uretprobe" attach "e56_fn" arch "x86_64" maps [@hits] {
^bb0(%ctx: !ebpf.ctx<"uretprobe">, %hits: !ebpf.map<"array", i32, i64>):
  %k1 = arith.constant 1 : i32
  %one = arith.constant 1 : i64
  ebpf.map.atomic_add %hits[%k1], %one : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
