require "bpf"

# 例 tlvwalk (P015 E061): Ethernet (14 byte) の後の TLV (type 1 byte・len 1 byte・value len byte) を最大 8 個 walk する XDP。
# 有界の loop (8.times — ebpf.loop の (U) 展開) の本体で packet の窓を検査して読む。type 0 か窓の外で止まる。
Types = BPF::ArrayMap.new("Types", :u64, 8) # type & 7 ごとの TLV の数
Walks = BPF::ArrayMap.new("Walks", :u64, 2) # [0] 読んだ TLV の数の和、[1] 8 個で打ち切った packet の数

def tlv(ctx)
  off = 14
  n = 0
  8.times do |i|
    t = 0
    l = 0
    w = ctx.check(off, 2)
    if w
      t = w.u8(0)
      l = w.u8(1) & 0x3F
    end
    break if t == 0
    Types.atomic_add(t & 7, 1)
    n += 1
    off += 2 + l
  end
  Walks.atomic_add(0, n)
  if n == 8
    Walks.atomic_add(1, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :tlv

# user 空間の側 — 普通の Ruby (Spinel)。
#   tlvwalk --selftest   attach せずに、組み立てた 4 つの packet で BPF_PROG_TEST_RUN し数を確かめる
#   tlvwalk --dump       load して map を出すだけ
require "spinelbpf"

USAGE = "usage: tlvwalk --selftest | --dump"
if ARGV.length != 1 || (ARGV[0] != "--selftest" && ARGV[0] != "--dump")
  raise USAGE
end

# packet は Ethernet の 14 byte の 0 の後に tlvs (byte の列) を置き、長さ n に 0 で満たす。
def packet(tlvs, n)
  f = Array.new(14, 0) + tlvs
  while f.length < n
    f.push(0)
  end
  f
end

def show(obj)
  ts = []
  k = 0
  while k < 8
    ts.push(obj.map_get(Types, k))
    k += 1
  end
  puts "types=#{ts.join(",")} walked=#{obj.map_get(Walks, 0)} capped=#{obj.map_get(Walks, 1)}"
  ts
end

obj = SpinelBPF.load_embedded # 照合付きの load だけ (attach しない)
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
if ARGV[0] == "--selftest"
  pkts = [
    packet([1, 2, 9, 9, 2, 0, 3, 1, 7, 0], 64),       # 3 個と終わりの 0
    packet([4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0], 64), # 10 個 — 8 個で打ち切り
    packet([5, 60, 1, 2, 3], 30),                      # 1 個 — 次の窓 (76) が packet の外
    packet([], 14)                                     # Ethernet だけ — 最初の窓が外
  ]
  pkts.each do |p|
    ret = obj.test_run_xdp_packet("tlv", p)
    if ret != BPF::XDP_PASS
      raise "selftest: ret=#{ret}"
    end
  end
  ts = show(obj)
  want = [0, 1, 1, 1, 8, 1, 0, 0]
  ok = ts == want && obj.map_get(Walks, 0) == 12 && obj.map_get(Walks, 1) == 1
  obj.close
  if !ok
    puts "selftest FAILED (want types=#{want.join(",")} walked=12 capped=1)"
    exit 1
  end
  puts "selftest ok"
else
  show(obj)
  obj.close
end
