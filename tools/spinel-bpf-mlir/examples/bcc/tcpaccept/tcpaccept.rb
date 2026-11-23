require "bpf"

# tcpaccept — 受け身の TCP の open (SYN_RECV → ESTABLISHED の子の socket) を 1 つずつ印字 (bcc の tcpaccept、spinel-ebpf 23fa4b0 tools/tcpaccept.rb の移植 — P029 E153)。
# eBPF の側: tracepoint sock/inet_sock_set_state で TCP (6) の oldstate 3 → newstate 1 なら、受けた側の port (sport) と相手の port と daddr[4] / daddr_v6[16]
# (相手 — client の address) を ctx.copy(:f) で ring の event の配列の member に写す (bpf-mlir E552)。この遷移は 3 つ目の ACK の処理 (softirq の文脈) で
# 起き、今の task は不定 — tgid でなく Cfg[0] の listen の port (sport) で絞る。bcc の tcpaccept は kretprobe inet_csk_accept (accept した process の
# pid と comm を出せる) — この移植は spinel-ebpf と同じ tracepoint で、process は出さない (attach が違う)。
# offset と型は記録した host 7.1.8 の format (testdata/tracefs-7.1.8 — TestBccTracepointFormats が照らす)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:family, :sport, :dport, :pad, :daddr, :daddr_v6)
BPF.record(Ev, family: :u16, sport: :u16, dport: :u16, pad: :u16, daddr: [:u8, 4], daddr_v6: [:u8, 16])
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, Array.new(4, 0), Array.new(16, 0)), 65536)

def on_state(ctx)
  if ctx.field(:protocol) == 6 && ctx.field(:oldstate) == 3 && ctx.field(:newstate) == 1
    sp = ctx.field(:sport)
    c = Cfg.lookup(0)
    if c
      if c.load == 0 || c.load == sp
        unless Events.output(Ev.new(ctx.field(:family), sp, ctx.field(:dport), 0, ctx.copy(:daddr), ctx.copy(:daddr_v6)))
          Drops.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.tracepoint :on_state, "sock/inet_sock_set_state", fields: {oldstate: [16, :i32], newstate: [20, :i32], sport: [24, :u16], dport: [26, :u16], family: [28, :u16], protocol: [30, :u16], daddr: [36, [:u8, 4]], daddr_v6: [56, [:u8, 16]]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   tcpaccept [--duration-ms MS] [--port PORT]   MS の間 (既定 5000) の受け身の open を印字 (PORT が 0 でなければその listen の port だけ)
#   tcpaccept --selftest                          自分の 127.0.0.1 と [::1] の listen の port を Cfg に置き、自分で connect して accept — event がちょうど 2 つ:
#                                                 sport がそれぞれの port、family 2 で daddr 127.0.0.1 と daddr_v6 v4-mapped (::ffff:127.0.0.1)、family 10 で daddr_v6 ::1
require "spinelbpf"

# TA は自分の loopback の listen (port を返す) と、その listen への connect と accept と後始末 (例の中の inline C — 誤りは負)。
module TA
  ffi_source <<~C
    #include <arpa/inet.h>
    #include <netinet/in.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <unistd.h>
    static int ta_l = -1;
    static struct sockaddr_storage ta_ss;
    static socklen_t ta_sl;
    long ta_listen(long fam) {
      memset(&ta_ss, 0, sizeof ta_ss);
      if (fam == 6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ta_ss;
        a->sin6_family = AF_INET6;
        a->sin6_addr = in6addr_loopback;
        ta_sl = sizeof *a;
      } else {
        struct sockaddr_in *a = (struct sockaddr_in *)&ta_ss;
        a->sin_family = AF_INET;
        a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        ta_sl = sizeof *a;
      }
      ta_l = socket(ta_ss.ss_family, SOCK_STREAM, 0);
      if (ta_l < 0) return -1;
      if (bind(ta_l, (struct sockaddr *)&ta_ss, ta_sl) != 0 || listen(ta_l, 1) != 0 || getsockname(ta_l, (struct sockaddr *)&ta_ss, &ta_sl) != 0) { close(ta_l); return -2; }
      return fam == 6 ? (long)ntohs(((struct sockaddr_in6 *)&ta_ss)->sin6_port) : (long)ntohs(((struct sockaddr_in *)&ta_ss)->sin_port);
    }
    long ta_accept(void) {
      int c = socket(ta_ss.ss_family, SOCK_STREAM, 0);
      if (c < 0) { close(ta_l); return -3; }
      if (connect(c, (struct sockaddr *)&ta_ss, ta_sl) != 0) { close(c); close(ta_l); return -4; }
      int s = accept(ta_l, NULL, NULL);
      long ok = s >= 0 ? 0 : -5;
      if (s >= 0) close(s);
      close(c);
      close(ta_l);
      return ok;
    }
  C
  ffi_func :ta_listen, [:long], :long
  ffi_func :ta_accept, [], :long
end

# addr4 / addr6 は read_record の平らな値の daddr (v[4..7]) と daddr_v6 (v[8..23]) の印字。
def addr4(v)
  "#{v[4]}.#{v[5]}.#{v[6]}.#{v[7]}"
end

def addr6(v)
  s = ""
  k = 0
  while k < 16
    s += ":" if k > 0 && k % 2 == 0
    s += v[8 + k].to_s(16).rjust(2, "0")
    k += 1
  end
  s
end

USAGE = "usage: tcpaccept [--duration-ms MS] [--port PORT] | --selftest"
selftest = false
port = 0
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--port" && i + 1 < ARGV.length
    port = ARGV[i + 1].to_i
    i += 2
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end

obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, port)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_state")
p4 = 0
p6 = 0
a4 = -9
a6 = -9
if selftest
  p4 = TA.ta_listen(4)
  if p4 > 0
    obj.map_put(Cfg, 0, p4)
    a4 = TA.ta_accept
  end
  p6 = TA.ta_listen(6)
  if p6 > 0
    obj.map_put(Cfg, 0, p6)
    a6 = TA.ta_accept
  end
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (port 1)
else
  puts "tracing TCP accepts for #{duration_ms} ms#{port > 0 ? " (port #{port})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "  FAM  LPORT  RPORT  RADDR"
events = 0
ok4 = 0
ok6 = 0
v = r.read_record(200)
while v.length > 0
  addr = v[0] == 10 ? addr6(v) : addr4(v)
  puts "#{v[0].to_s.rjust(5)} #{v[1].to_s.rjust(6)} #{v[2].to_s.rjust(6)}  #{addr}"
  events += 1
  ok4 += 1 if v[0] == 2 && v[1] == p4 && addr4(v) == "127.0.0.1" && addr6(v) == "0000:0000:0000:0000:0000:ffff:7f00:0001"
  ok6 += 1 if v[0] == 10 && v[1] == p6 && addr6(v) == "0000:0000:0000:0000:0000:0000:0000:0001"
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  puts "ports=#{p4},#{p6} accept=#{a4},#{a6} v4=#{ok4} v6=#{ok6}"
  if a4 != 0 || a6 != 0 || events != 2 || ok4 != 1 || ok6 != 1
    puts "selftest FAILED: want exactly 2 accepted connections on this process's listen ports — family 2 from 127.0.0.1 (daddr_v6 v4-mapped) and family 10 from ::1"
    exit 1
  end
  puts "selftest ok"
end
