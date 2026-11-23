// E055 の H7 の fixture: test/dwarf/fixture/e55 の e55_alias(uint64_t a, uint64_t b) の入口の uprobe で a + b を足す (引数を読む — DWARF の照合が要る)。
// schema の binary_sha256 は scripts/split-load-target.sh が作った本体の sha256 に置き換える (fixture は走らせるごとに作る)
ebpf.program @count "uprobe" attach "e55_alias" arch "x86_64" maps [@sums] {
^bb0(%ctx: !ebpf.ctx<"uprobe">, %sums: !ebpf.map<"array", i32, i64>):
  %a = ebpf.uprobe.arg %ctx 1 : !ebpf.ctx<"uprobe"> -> i64
  %b = ebpf.uprobe.arg %ctx 2 : !ebpf.ctx<"uprobe"> -> i64
  %s = arith.addi %a, %b : i64
  %k0 = arith.constant 0 : i32
  ebpf.map.atomic_add %sums[%k0], %s : !ebpf.map<"array", i32, i64>, i32, i64
  ebpf.verdict "done"
}
