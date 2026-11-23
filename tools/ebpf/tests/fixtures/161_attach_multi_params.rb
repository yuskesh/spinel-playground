# E401 (P011 S12): 多シンボル handler の block params。
# ATTACH_KINDS は「PT_REGS_PARM<N>(ctx) — kprobe と同じ」と宣言しているが、
# kprobe_multi は fprobe backed なのでこれはカーネルへの主張であり、
# 実測した (results/E401/args_control.sh: 両下回りで calls=50/buf_nonzero=50)。
# ここでは <bpf/bpf_tracing.h> が include されることを golden で固定する —
# 入れ忘れると clang が `PT_REGS_PARM2` 未宣言で落ちる (E401 で実際に踏んだ)。
module A
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write], via: :multi do |file, buf|
    @calls = @calls + 1
    if buf > 0
      @nonzero = @nonzero + 1
    end
  end
end
