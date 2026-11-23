// E014 の fixture: .rodata の設定値 want (u32) が 0 なら何もせず pass、0 でなければ cnt[0] += 1・cnt[1] += want。want を置かない (optional —
// ELF の初期値 0) load では kernel の verifier が凍結した .rodata の定数で else の枝を死んだ code として刈り込み、line_info が減る (spinel E059 の
// pollwatch と同じ形 — bml の B4 の数の完全一致が拒否した)
// (E014 の事後の訂正: op に loc を付けた — ebpf-compile は明示の loc だけを line_info に写す (bpf-mlir E255)。loc の無い 1 回目は line_info が 1 つで刈り込みを試せなかった)
ebpf.program @prog "xdp" maps [@cnt] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %cnt: !ebpf.map<"array", i32, i64>):
  %w = ebpf.global.load @want : i32 loc("dead.src":10:3)
  %z = arith.constant 0 : i32 loc("dead.src":11:3)
  %off = arith.cmpi eq, %w, %z : i32 loc("dead.src":12:3)
  ebpf.if %off {
    ebpf.if.yield
  } else {
    %k0 = arith.constant 0 : i32 loc("dead.src":13:3)
    %k1 = arith.constant 1 : i32 loc("dead.src":14:3)
    %one = arith.constant 1 : i64 loc("dead.src":15:3)
    %w64 = arith.extui %w : i32 to i64 loc("dead.src":16:3)
    ebpf.map.atomic_add %cnt[%k0], %one : !ebpf.map<"array", i32, i64>, i32, i64 loc("dead.src":17:3)
    ebpf.map.atomic_add %cnt[%k1], %w64 : !ebpf.map<"array", i32, i64>, i32, i64 loc("dead.src":18:3)
    ebpf.if.yield
  }
  ebpf.verdict "pass" loc("dead.src":19:3)
}
