require "bpf"

# E121 追補 1: flags の照合 — 変異の無い build は load と lpm_put が通り、埋め込みの宣言の flags を落とせば load が、SpinelBPF.decl の flags を落とせば lpm_put が MapMismatch
R = BPF::LpmTrieMap.new("R", :u32, 4)

def prog(ctx)
  hit = 0
  p = R.lookup(10, 0, 0, 1)
  if p
    hit = p.load
  end
  return BPF::XDP_DROP if hit == 1
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load ok"
  begin
    obj.lpm_put(R, "10.0.0.0/8", 1)
    puts "put ok match=#{obj.lpm_match(R, "10.0.0.1")}"
  rescue => e
    puts "put err=#{e.class}"
  end
  obj.close
rescue => e
  puts "load err=#{e.class}"
end
