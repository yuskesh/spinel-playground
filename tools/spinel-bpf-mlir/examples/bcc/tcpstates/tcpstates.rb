require "bpf"

# tcpstates — TCP の状態の遷移を 1 つずつ印字 (bcc の tcpstates、spinel-ebpf 23fa4b0 tools/tcpstates.rb の移植 — P027 E138)。
# eBPF の側: tracepoint sock/inet_sock_set_state の (oldstate・newstate・sport・dport) を ring に。protocol は TCP (6) だけ。
# Cfg[0] が 0 でなければ sport か dport がその port の遷移だけ。状態の番号は kernel の tcp_states (1 = ESTABLISHED・2 = SYN_SENT・3 = SYN_RECV・
# 4 = FIN_WAIT1・5 = FIN_WAIT2・6 = TIME_WAIT・7 = CLOSE・8 = CLOSE_WAIT・9 = LAST_ACK・10 = LISTEN・11 = CLOSING)。
# offset と型は記録した host 7.1.8 の format (testdata/tracefs-7.1.8 — TestBccTracepointFormats が照らす)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:old, :new, :sport, :dport)
BPF.record(Ev, old: :u32, new: :u32, sport: :u32, dport: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0), 65536)

def on_state(ctx)
  if ctx.field(:protocol) == 6
    sp = ctx.field(:sport)
    dp = ctx.field(:dport)
    c = Cfg.lookup(0)
    if c
      if c.load == 0 || c.load == sp || c.load == dp
        unless Events.output(Ev.new(ctx.field(:oldstate) & 0xFF, ctx.field(:newstate) & 0xFF, sp, dp))
          Drops.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.tracepoint :on_state, "sock/inet_sock_set_state",
  fields: {oldstate: [16, :i32], newstate: [20, :i32], sport: [24, :u16], dport: [26, :u16], protocol: [30, :u16]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   tcpstates [--duration-ms MS] [--port P]   MS の間 (既定 5000) の TCP の状態の遷移を印字
#   tcpstates --selftest                       自分の netns の 127.0.0.1:46139 に接続を 1 つ作り close — 遷移の列を印字し、
#                                              CLOSE→SYN_SENT (7→2) と SYN_RECV→ESTABLISHED (3→1) がちょうど 1 つずつを照らす
require "spinelbpf"

# TC は自分の netns と lo、127.0.0.1 の listen と接続 (例の中の inline C)。
module TC
  ffi_source <<~C
    #include <arpa/inet.h>
    #include <linux/sched.h>
    #include <net/if.h>
    #include <netinet/in.h>
    #include <string.h>
    #include <sys/ioctl.h>
    #include <sys/socket.h>
    #include <sys/syscall.h>
    #include <time.h>
    #include <unistd.h>
    static int tc_lfd = -1;
    long tc_netns(void) {
      if (syscall(SYS_unshare, CLONE_NEWNET) != 0) return -1;
      int s = socket(AF_INET, SOCK_DGRAM, 0); if (s < 0) return -2;
      struct ifreq r; memset(&r, 0, sizeof r); strncpy(r.ifr_name, "lo", IFNAMSIZ - 1);
      if (ioctl(s, SIOCGIFFLAGS, &r) != 0) { close(s); return -3; }
      r.ifr_flags |= IFF_UP;
      long rc = ioctl(s, SIOCSIFFLAGS, &r) == 0 ? 0 : -4;
      close(s); return rc;
    }
    long tc_listen(long port) {
      tc_lfd = socket(AF_INET, SOCK_STREAM, 0); if (tc_lfd < 0) return -1;
      struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (bind(tc_lfd, (struct sockaddr *)&a, sizeof a) != 0 || listen(tc_lfd, 16) != 0) return -2;
      return 0;
    }
    long tc_conns(long port, long n, long hold_ms) {
      long ok = 0;
      for (long i = 0; i < n; i++) {
        int c = socket(AF_INET, SOCK_STREAM, 0); if (c < 0) continue;
        struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(c, (struct sockaddr *)&a, sizeof a) == 0) {
          int s = accept(tc_lfd, 0, 0);
          if (s >= 0) {
            struct timespec t = {hold_ms / 1000, (hold_ms % 1000) * 1000000L}; nanosleep(&t, 0);
            close(c); close(s); ok++;
            struct timespec w = {0, 50000000L}; nanosleep(&w, 0);
          } else close(c);
        } else close(c);
      }
      return ok;
    }
    long tc_close(void) { if (tc_lfd >= 0) close(tc_lfd); tc_lfd = -1; return 0; }
  C
  ffi_func :tc_netns, [], :long
  ffi_func :tc_listen, [:long], :long
  ffi_func :tc_conns, [:long, :long, :long], :long
  ffi_func :tc_close, [], :long
end

STATES = ["?", "ESTABLISHED", "SYN_SENT", "SYN_RECV", "FIN_WAIT1", "FIN_WAIT2", "TIME_WAIT", "CLOSE", "CLOSE_WAIT", "LAST_ACK", "LISTEN", "CLOSING", "NEW_SYN_RECV", "BOUND_INACTIVE"]

# state_name は状態の番号の名前。
def state_name(s)
  s >= 0 && s < STATES.length ? STATES[s] : s.to_s
end

USAGE = "usage: tcpstates [--duration-ms MS] [--port P] | --selftest"
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

if selftest
  port = 46139
  if TC.tc_netns != 0
    raise "tcpstates: cannot set up the own netns"
  end
end
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, port)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_state")
conns = 0
if selftest
  if TC.tc_listen(port) != 0
    raise "tcpstates: cannot listen"
  end
  conns = TC.tc_conns(port, 1, 10)
  TC.tc_close
else
  puts "tracing TCP state changes for #{duration_ms} ms#{port > 0 ? " (port #{port})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "  SPORT  DPORT  OLD -> NEW"
events = 0
active = 0
passive = 0
v = r.read_record(200)
while v.length > 0
  puts "#{v[2].to_s.rjust(7)} #{v[3].to_s.rjust(6)}  #{state_name(v[0])} -> #{state_name(v[1])}"
  events += 1
  active += 1 if v[0] == 7 && v[1] == 2
  passive += 1 if v[0] == 3 && v[1] == 1
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "events=#{events} drops=#{drops}"
if selftest
  puts "conns=#{conns} close_to_syn_sent=#{active} syn_recv_to_established=#{passive}"
  if conns != 1 || active != 1 || passive != 1
    puts "selftest FAILED: want conns=1 close_to_syn_sent=1 syn_recv_to_established=1"
    exit 1
  end
  puts "selftest ok"
end
