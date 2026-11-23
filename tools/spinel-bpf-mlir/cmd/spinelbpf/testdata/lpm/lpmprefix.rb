require "bpf"

# E121 H4: prefix の確かめ (object 無し — kernel に触らない、root なし)。program は build のためだけ (load しない)
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

def try(label)
  begin
    n = yield
    puts "#{label} ok #{n}"
  rescue => e
    puts "#{label} err=#{e.class}"
  end
end

try("10.0.0.0/8") { SpinelBPF.lpm_prefix_len("10.0.0.0/8") }
try("0.0.0.0/0") { SpinelBPF.lpm_prefix_len("0.0.0.0/0") }
try("255.255.255.255/32") { SpinelBPF.lpm_prefix_len("255.255.255.255/32") }
try("IPv6") { SpinelBPF.lpm_prefix_len("::1/128") }
try("host bits") { SpinelBPF.lpm_prefix_len("10.1.2.3/8") }
try("/33") { SpinelBPF.lpm_prefix_len("10.0.0.0/33") }
try("no length") { SpinelBPF.lpm_prefix_len("10.0.0.0") }
try("octet 256") { SpinelBPF.lpm_prefix_len("10.0.0.256/32") }
try("empty") { SpinelBPF.lpm_prefix_len("") }
