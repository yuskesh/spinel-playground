# E401 (P011 S12): 136 と同じ body を kprobe_multi (via: :multi) に載せる。
# 生成される _inner は 136 と byte 一致し、wrapper だけが変わる
# (リテラルの index -> bpf_get_attach_cookie)。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write], via: :multi do
    @calls = @calls + 1
    if attached_symbol_eq("vfs_read")
      @reads = @reads + 1
    end
    spnl_emit(attached_index)
  end
end
