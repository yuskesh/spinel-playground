# E401 (P011 S12): 1 定義 -> 複数 attach、展開 (via: :expand)。
# body は `attached_symbol_eq` / `attached_index` の 1 通りだけで書かれており、
# どちらの下回りが選ばれたかは body から見えない。137 と対で、この 2 本の
# golden の _inner が一致することが D1 (「body は 1 通り」) の常設の証拠。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write], via: :expand do
    @calls = @calls + 1
    if attached_symbol_eq("vfs_read")
      @reads = @reads + 1
    end
    spnl_emit(attached_index)
  end
end
