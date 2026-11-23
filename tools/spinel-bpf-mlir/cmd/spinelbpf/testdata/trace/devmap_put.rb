require "bpf"

# E124 (P026) の H0 — bml の口の確かめ (†): devmap を持つ ELF の load、user の側の ifindex の put / get (lo の 1 — 全ての netns に在る)、
# 存在しない ifindex (999999) の put は kernel が devmap の更新を拒む (bml の誤り — 黙って入らない)。
Ports = BPF::DevMap.new("Ports", :u32, 4)

def redir(ctx)
  Ports.redirect(0, BPF::XDP_PASS)
end
BPF.xdp :redir

require "spinelbpf"

obj = SpinelBPF.load_embedded
puts "load kind=OK"
obj.map_put(Ports, 0, 1)
puts "put lo kind=OK"
puts "get=#{obj.map_get(Ports, 0)}"
begin
  obj.map_put(Ports, 1, 999999)
  puts "put 999999 kind=OK"
rescue SpinelBPF::Error => e
  puts "put 999999 kind=#{e.class} msg=#{e.message}"
end
obj.close
