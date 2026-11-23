require "bpf"

# tcpconnect — 能動の TCP の connect (CLOSE → SYN_SENT) を 1 つずつ印字 (bcc の tcpconnect、spinel-ebpf 23fa4b0 tools/tcpconnect.rb の移植 — P029 E153)。
# eBPF の側: tracepoint sock/inet_sock_set_state で TCP (6) の oldstate 7 → newstate 2 なら、宛先の port と daddr[4] / daddr_v6[16] を ctx.copy(:f) で
# ring の event の配列の member に写す (bpf-mlir E552 — u32 に再解釈しない)。connect の syscall の中で起きるので Cfg[0] の tgid で絞れる。
# bcc の tcpconnect は kprobe tcp_v4_connect / tcp_v6_connect — この移植は spinel-ebpf と同じ tracepoint (attach が違う)。
# offset と型は記録した host 7.1.8 の format (testdata/tracefs-7.1.8 — TestBccTracepointFormats が照らす)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tgid, :family, :dport, :daddr, :daddr_v6)
BPF.record(Ev, tgid: :u32, family: :u16, dport: :u16, daddr: [:u8, 4], daddr_v6: [:u8, 16])
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, Array.new(4, 0), Array.new(16, 0)), 65536)

def on_state(ctx)
  if ctx.field(:protocol) == 6 && ctx.field(:oldstate) == 7 && ctx.field(:newstate) == 2
    tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
    c = Cfg.lookup(0)
    if c
      if c.load == 0 || c.load == tgid
        unless Events.output(Ev.new(tgid, ctx.field(:family), ctx.field(:dport), ctx.copy(:daddr), ctx.copy(:daddr_v6)))
          Drops.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.tracepoint :on_state, "sock/inet_sock_set_state", fields: {oldstate: [16, :i32], newstate: [20, :i32], dport: [26, :u16], family: [28, :u16], protocol: [30, :u16], daddr: [36, [:u8, 4]], daddr_v6: [56, [:u8, 16]]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   tcpconnect [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の能動の connect を印字
#   tcpconnect --selftest                         自分の tgid に絞り、自分の 127.0.0.1 と [::1] の listen の port に connect — event がちょうど 2 つ:
#                                                 family 2 で daddr 127.0.0.1・family 10 で daddr_v6 ::1、dport がそれぞれの port
require "spinelbpf"

# TC は自分の pid と、自分の loopback の listen への connect と accept (例の中の inline C — 戻り値は listen の port、誤りは負)。
module TC
  ffi_source <<~C
    #include <arpa/inet.h>
    #include <netinet/in.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <unistd.h>
    long tc_pid(void) { return (long)getpid(); }
    long tc_connect(long fam) {
      struct sockaddr_storage ss;
      socklen_t sl;
      memset(&ss, 0, sizeof ss);
      if (fam == 6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ss;
        a->sin6_family = AF_INET6;
        a->sin6_addr = in6addr_loopback;
        sl = sizeof *a;
      } else {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss;
        a->sin_family = AF_INET;
        a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sl = sizeof *a;
      }
      int l = socket(ss.ss_family, SOCK_STREAM, 0);
      if (l < 0) return -1;
      if (bind(l, (struct sockaddr *)&ss, sl) != 0 || listen(l, 1) != 0 || getsockname(l, (struct sockaddr *)&ss, &sl) != 0) { close(l); return -2; }
      int c = socket(ss.ss_family, SOCK_STREAM, 0);
      if (c < 0) { close(l); return -3; }
      if (connect(c, (struct sockaddr *)&ss, sl) != 0) { close(c); close(l); return -4; }
      int s = accept(l, NULL, NULL);
      if (s >= 0) close(s);
      close(c);
      close(l);
      return fam == 6 ? (long)ntohs(((struct sockaddr_in6 *)&ss)->sin6_port) : (long)ntohs(((struct sockaddr_in *)&ss)->sin_port);
    }
  C
  ffi_func :tc_pid, [], :long
  ffi_func :tc_connect, [:long], :long
end

# addr4 / addr6 は read_record の平らな値の daddr (v[3..6]) と daddr_v6 (v[7..22]) の印字。
def addr4(v)
  "#{v[3]}.#{v[4]}.#{v[5]}.#{v[6]}"
end

def addr6(v)
  s = ""
  k = 0
  while k < 16
    s += ":" if k > 0 && k % 2 == 0
    s += v[7 + k].to_s(16).rjust(2, "0")
    k += 1
  end
  s
end

USAGE = "usage: tcpconnect [--duration-ms MS] [--pid TGID] | --selftest"
selftest = false
pid = 0
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--pid" && i + 1 < ARGV.length
    pid = ARGV[i + 1].to_i
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
obj.map_put(Cfg, 0, selftest ? TC.tc_pid : pid)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_state")
p4 = 0
p6 = 0
if selftest
  p4 = TC.tc_connect(4)
  p6 = TC.tc_connect(6)
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1)
else
  puts "tracing TCP connects for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "    TGID  FAM  DPORT  DADDR"
events = 0
ok4 = 0
ok6 = 0
v = r.read_record(200)
while v.length > 0
  addr = v[1] == 10 ? addr6(v) : addr4(v)
  puts "#{v[0].to_s.rjust(8)} #{v[1].to_s.rjust(4)} #{v[2].to_s.rjust(6)}  #{addr}"
  events += 1
  ok4 += 1 if v[1] == 2 && v[2] == p4 && addr4(v) == "127.0.0.1"
  ok6 += 1 if v[1] == 10 && v[2] == p6 && addr6(v) == "0000:0000:0000:0000:0000:0000:0000:0001"
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  puts "ports=#{p4},#{p6} v4=#{ok4} v6=#{ok6}"
  if p4 <= 0 || p6 <= 0 || events != 2 || ok4 != 1 || ok6 != 1
    puts "selftest FAILED: want exactly 2 events of this process — family 2 to 127.0.0.1 and family 10 to ::1, each to its own listen port"
    exit 1
  end
  puts "selftest ok"
end
