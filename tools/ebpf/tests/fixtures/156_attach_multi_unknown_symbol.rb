# E401 (P011 S12): 宣言していない名前で attached_symbol_eq を呼ぶ。
# 「一致しない定数」に畳まず compile 時に落とす (ADR-003) ことの negative control。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write] do
    if attached_symbol_eq("vfs_open")
      @n = @n + 1
    end
  end
end
