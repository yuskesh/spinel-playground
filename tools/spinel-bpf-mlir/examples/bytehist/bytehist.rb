require "bpf"

# 例 bytehist (P016 E069): Ethernet の後の最初の byte の上位 4 bit ごとの packet の数を per-CPU の record の配列の member に数える XDP。
# 可変の添字 b ∈ [0, 15] (w.u8(0) >> 4 — frontend が区間で証明) の要素の read-modify-write は per-CPU の map なので受ける (P009 の免除 — 数え落とさない)。
Hist = Struct.new(:counts)
BPF.record(Hist, counts: [:u32, 16])
Hists = BPF::PerCpuRecordMap.new("Hists", Hist.new(Array.new(16, 0)), 1)

def byte_hist(ctx)
  w = ctx.check(14, 1)
  if w
    b = w.u8(0) >> 4
    p = Hists.lookup(0)
    if p
      p.load.counts[b] = (p.load.counts[b] + 1) & 0xFFFF_FFFF
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :byte_hist

# user 空間の側 — 普通の Ruby (Spinel)。
#   bytehist --selftest   attach せずに、組み立てた packet で BPF_PROG_TEST_RUN し CPU ごとの和を確かめる
#   bytehist --dump       load して CPU ごとの和を出すだけ
require "spinelbpf"

USAGE = "usage: bytehist --selftest | --dump"
if ARGV.length != 1 || (ARGV[0] != "--selftest" && ARGV[0] != "--dump")
  raise USAGE
end

# sums は CPU ごとの値 (平らな Array — 配列の member の要素ごと) の和。
def sums(obj)
  rows = obj.percpu_get_record(Hists, 0)
  s = Array.new(16, 0)
  j = 0
  while j < rows.length
    b = 0
    while b < 16
      s[b] += rows[j][b]
      b += 1
    end
    j += 1
  end
  s
end

# packet は 14 byte の 0 の Ethernet の後に first (無ければ付けない) を置き、長さ n に 0 で満たす。
def packet(first, n)
  f = Array.new(14, 0)
  if first >= 0
    f.push(first)
  end
  while f.length < n
    f.push(0)
  end
  f
end

obj = SpinelBPF.load_embedded # 照合付きの load だけ (attach しない)
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
if ARGV[0] == "--selftest"
  pkts = [packet(0x45, 64), packet(0x45, 64), packet(0x45, 64), packet(0x60, 64), packet(0x60, 64), packet(0xFF, 64), packet(-1, 14)]
  pkts.each do |pk|
    ret = obj.test_run_xdp_packet("byte_hist", pk)
    if ret != BPF::XDP_PASS
      raise "selftest: ret=#{ret}"
    end
  end
  s = sums(obj)
  puts "counts=#{s.join(",")}"
  want = [0, 0, 0, 0, 3, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 1]
  obj.close
  if s != want
    puts "selftest FAILED (want counts=#{want.join(",")})"
    exit 1
  end
  puts "selftest ok"
else
  puts "counts=#{sums(obj).join(",")}"
  obj.close
end
