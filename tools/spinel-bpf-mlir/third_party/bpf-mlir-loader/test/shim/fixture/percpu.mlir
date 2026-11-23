// E007 H4 の fixture: percpu_array の i32 (4 byte — kernel の stride 8) と percpu_hash の 12 byte の record (stride 16)。
// 各 run で pa[0] += 1 (走った CPU の slot だけ)、ph は user 空間の読み書きだけ (program は lookup で参照する)。
ebpf.program @prog "xdp" maps [@pa, @ph] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %pa: !ebpf.map<"percpu_array", i32, i32>, %ph: !ebpf.map<"percpu_hash", i32, !ebpf.record<"tri", 12>>):
  %k = arith.constant 0 : i32
  %one = arith.constant 1 : i32
  ebpf.map.atomic_add %pa[%k], %one : !ebpf.map<"percpu_array", i32, i32>, i32, i32
  %m = ebpf.map.lookup %ph[%k] : !ebpf.map<"percpu_hash", i32, !ebpf.record<"tri", 12>>, i32 -> !ebpf.maybe_ref<!ebpf.record<"tri", 12>>
  ebpf.ref.check %m : !ebpf.maybe_ref<!ebpf.record<"tri", 12>> present {
  ^p(%r: !ebpf.borrowed<!ebpf.record<"tri", 12>>):
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "pass"
}
