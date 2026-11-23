# E401: 知らない `via:`。黙って auto に落とすと「指定したのに効かない」に
# なるので落とす。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write], via: :kprobe_multi do
    @n = @n + 1
  end
end
