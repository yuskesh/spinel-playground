# E401: リストに同じシンボルが 2 回。展開なら二重計上、kprobe_multi なら
# libbpf が link ごと拒否する — 挙動が分かれるので両方で同じく落とす。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_read] do
    @n = @n + 1
  end
end
