require "bpf"

# E095 (レビュー役の足し — E094 の Honest): 共有の hash の借用の helper (読み・atomic_add) の双子 = kernel と inline = helper。
H = BPF::HashMap.new("H", :u32, :u64, 16)
Out = BPF::ArrayMap.new("Out", :u64, 4)

def peek(q)
  q.load & 0xFFFF
end

def bump(q, d)
  q.atomic_add(d & 0xFF)
  0
end

def h_inline(ctx)
  p = H.lookup(1)
  if p
    Out.update(0, p.load & 0xFFFF)
    p.atomic_add(5)
  end
  BPF::XDP_PASS
end
BPF.xdp :h_inline

def h_helper(ctx)
  p = H.lookup(2)
  if p
    Out.update(1, peek(p) & 0xFFFF)
    bump(p, 5)
  end
  BPF::XDP_PASS
end
BPF.xdp :h_helper
