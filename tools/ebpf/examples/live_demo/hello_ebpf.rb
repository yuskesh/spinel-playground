# ライブデモ: メソッドが「カーネルの eBPF VM の中」で動く。
# --ebpf-dispatch で add/square の呼び出しは bpf_prog_test_run 経由になる。
def add(a, b)
  a + b
end

def square(n)
  n * n
end

puts add(2, 3)     # => 5   (カーネル内 eBPF で計算)
puts square(7)     # => 49  (同上)
