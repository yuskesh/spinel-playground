require "bpf"

# eBPF の側 — Ethernet の EtherType ごとの数、IPv4 の protocol ごとの数、UDP の dst port 9999 の数 (P004 E017)。
# 読みは全て検査済みの window (`w = ctx.check(off, len)` の直後の `if w`) — 短い frame は out_of_range の腕で数える。
Ether = BPF::ArrayMap.new("Ether", :u64, 8)   # 0 IPv4・1 IPv6・2 ARP・3 VLAN・4 その他・5 短い frame・6 IPv4 の header が短い・7 IHL < 5
Proto = BPF::ArrayMap.new("Proto", :u64, 256) # IPv4 の protocol ごと
Udp = BPF::ArrayMap.new("Udp", :u64, 2)       # 0 dst port 9999 の数・1 最後の dst port

def count_ether(ctx)
  eth = ctx.check(0, 14)
  if eth
    et = eth.be16(12)
    if et == 0x0800
      Ether.atomic_add(0, 1)
      ip = ctx.check(14, 20)
      if ip
        ihl = ip.u8(0) & 0x0F
        if ihl < 5
          Ether.atomic_add(7, 1) # 意味の壊れた header — verifier は通すが読まない (利用者の分岐)
        else
          proto = ip.u8(9)
          Proto.atomic_add(proto, 1)
          if proto == 17
            l4 = ctx.check(14 + ihl * 4, 4) # 可変の offset (root でない loader は CAP_PERFMON が要る)
            if l4
              port = l4.be16(2)
              Udp.update(1, port)
              if port == 9999
                Udp.atomic_add(0, 1)
              end
            end
          end
        end
      else
        Ether.atomic_add(6, 1)
      end
    elsif et == 0x86DD
      Ether.atomic_add(1, 1)
    elsif et == 0x0806
      Ether.atomic_add(2, 1)
    elsif et == 0x8100
      Ether.atomic_add(3, 1)
    else
      Ether.atomic_add(4, 1)
    end
  else
    Ether.atomic_add(5, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :count_ether

# user 空間の側 — 普通の Ruby (Spinel)。
#   ethertype --iface IF [--duration-ms MS]   attach して MS の間待ち、数を出す
#   ethertype --selftest                     attach せずに、組み立てた frame で BPF_PROG_TEST_RUN (E017 で VM でも)
require "spinelbpf"

USAGE = "usage: ethertype --iface IF [--duration-ms MS] | --selftest"
iface = ""
duration_ms = 0
selftest = false
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--iface" && i + 1 < ARGV.length
    iface = ARGV[i + 1]
    i += 2
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  elsif a == "--selftest"
    selftest = true
    i += 1
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end
if iface == "" && !selftest
  raise USAGE
end

# frame は長さ n の 0 の frame に EtherType と IPv4 の header (vihl・protocol) と L4 の dst port を置く (0 の値は置かない)。
def frame(n, et, vihl, proto, port)
  f = Array.new(n, 0)
  f[12] = et >> 8
  f[13] = et & 0xFF
  if vihl > 0 && n > 23
    f[14] = vihl
    f[23] = proto
    l4 = 14 + (vihl & 0x0F) * 4
    if port > 0 && n >= l4 + 4
      f[l4 + 2] = port >> 8
      f[l4 + 3] = port & 0xFF
    end
  end
  f
end

def show(obj)
  e = []
  k = 0
  while k < 8
    e.push(obj.map_get(Ether, k))
    k += 1
  end
  puts "ether=#{e.join(",")} proto17=#{obj.map_get(Proto, 17)} proto6=#{obj.map_get(Proto, 6)} proto1=#{obj.map_get(Proto, 1)} udp9999=#{obj.map_get(Udp, 0)} last_port=#{obj.map_get(Udp, 1)}"
  e
end

obj = SpinelBPF.load_embedded # 照合付きの load だけ
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
if selftest
  frames = [
    frame(64, 0x0800, 0x45, 17, 9999), # IPv4 UDP 9999
    frame(64, 0x0800, 0x45, 17, 53),   # IPv4 UDP 53
    frame(64, 0x0800, 0x46, 17, 9999), # IPv4 (IHL 6) UDP 9999
    frame(64, 0x0800, 0x45, 6, 80),    # IPv4 TCP
    frame(64, 0x0800, 0x45, 1, 0),     # IPv4 ICMP
    frame(64, 0x0800, 0x44, 17, 9999), # IPv4 IHL 4 (意味の壊れた header)
    frame(33, 0x0800, 0, 0, 0),        # IPv4 の header が短い (check(14, 20) の外)
    frame(34, 0x0800, 0x45, 17, 9999), # IPv4 UDP — L4 の窓 (34..38) が外
    frame(64, 0x86DD, 0, 0, 0),
    frame(60, 0x0806, 0, 0, 0),
    frame(64, 0x8100, 0, 0, 0),
    frame(64, 0x88CC, 0, 0, 0)
  ]
  frames.each do |f|
    ret = obj.test_run_xdp_packet("count_ether", f)
    if ret != BPF::XDP_PASS
      raise "selftest: ret=#{ret}"
    end
  end
  e = show(obj)
  want = [8, 1, 1, 1, 1, 0, 1, 1]
  ok = e == want && obj.map_get(Proto, 17) == 4 && obj.map_get(Proto, 6) == 1 && obj.map_get(Proto, 1) == 1 &&
    obj.map_get(Udp, 0) == 2 && obj.map_get(Udp, 1) == 9999
  obj.close
  if !ok
    puts "selftest FAILED (want ether=#{want.join(",")} proto17=4 proto6=1 proto1=1 udp9999=2 last_port=9999)"
    exit 1
  end
  puts "selftest ok"
else
  link = obj.attach_xdp("count_ether", iface)
  puts "attached count_ether to #{iface}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  show(obj)
  link.detach
  obj.close
end
