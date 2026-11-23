# E401 (P011 S12): `via:` を書かない = codegen がリスト長で選ぶ。
# 2 < ATTACH_MULTI_THRESHOLD なので展開。このしきい値を動かすとこの golden が
# 変わる — それは黙って起きてよい変更ではないので、ここで見えるようにしてある。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write] do
    @calls = @calls + 1
  end
end
