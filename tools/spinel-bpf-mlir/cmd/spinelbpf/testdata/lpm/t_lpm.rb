require "bpf"

# E121 H5: lpm_trie の差動 — frame の宛先の IPv4 (byte 30〜33) の最長一致を Out に写す。Out[0] / Out[2] は 0 = 短い frame (window の外)・1 = 在る・2 = 無い、
# Out[1] / Out[3] は値 (無ければ 0)。Big は境界と乱数の表、Small (max_entries 4) は満杯、Neg は符号付きの値。
Big = BPF::LpmTrieMap.new("Big", :u32, 128)
Small = BPF::LpmTrieMap.new("Small", :u32, 4)
Neg = BPF::LpmTrieMap.new("Neg", :i32, 8)
Out = BPF::ArrayMap.new("Out", :i64, 4)

def t_big(ctx)
  hit = 0
  v = 0
  w = ctx.check(0, 34)
  if w
    hit = 2
    p = Big.lookup(w.u8(30), w.u8(31), w.u8(32), w.u8(33))
    if p
      hit = 1
      v = p.load
    end
  end
  Out.update(0, hit)
  Out.update(1, v)
  BPF::XDP_PASS
end

def t_small(ctx)
  hit = 0
  v = 0
  w = ctx.check(0, 34)
  if w
    hit = 2
    p = Small.lookup(w.u8(30), w.u8(31), w.u8(32), w.u8(33))
    if p
      hit = 1
      v = p.load
    end
  end
  Out.update(0, hit)
  Out.update(1, v)
  BPF::XDP_PASS
end

def t_neg(ctx)
  hit = 0
  v = 0
  w = ctx.check(0, 34)
  if w
    hit = 2
    p = Neg.lookup(w.u8(30), w.u8(31), w.u8(32), w.u8(33))
    if p
      hit = 1
      v = p.load
    end
  end
  Out.update(2, hit)
  Out.update(3, v)
  BPF::XDP_PASS
end

BPF.xdp :t_big
BPF.xdp :t_small
BPF.xdp :t_neg
