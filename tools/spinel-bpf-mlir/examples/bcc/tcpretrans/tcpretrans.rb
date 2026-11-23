require "bpf"

# tcpretrans — TCP の再送を 1 つずつ印字 (bcc の tcpretrans、spinel-ebpf 23fa4b0 tools/tcpretrans.rb の移植 — P029 E154)。
# eBPF の側: fentry tcp_retransmit_skb(struct sock *sk, …) の sk の __sk_common (struct sock_common — 値の埋め込み) の skc_family・skc_daddr・
# skc_dport・skc_num を t.load.__sk_common.m の経路で読み event に写すだけ (bpf-mlir E553 — CO-RE の埋め込みの経路)。絞らない (bcc も全ての再送を出す)、
# 経路の値は record の field に直に写す形だけ — 局所・算術・比較は Spinel の推論で SB010 (E154 追補 6)。byte order (skc_dport は network order) と port の絞りは user の側。attach が違う: bcc は tracepoint tcp/tcp_retransmit_skb (代案 — その形は E153 の配列の
# field で書ける)、spinel-ebpf は kprobe (spinel の kprobe には CO-RE の読みが無い)。v4 の address だけを印字 (v6 は skc_v6_daddr — この E の範囲外)。
SockCommon = Struct.new(:skc_daddr, :skc_dport, :skc_num, :skc_family)
BPF.kernel_type(SockCommon, "sock_common", skc_daddr: :u32, skc_dport: :u16, skc_num: :u16, skc_family: :u16)
Sock = Struct.new(:__sk_common)
BPF.kernel_type(Sock, "sock", __sk_common: [:struct, SockCommon])
SockT = BPF::KernelType.new(Sock.new(SockCommon.new(0, 0, 0, 0)))

Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:family, :sport, :dport, :pad, :daddr)
BPF.record(Ev, family: :u16, sport: :u16, dport: :u16, pad: :u16, daddr: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0), 65536)

def on_retrans(ctx)
  sk = ctx.kptr_or_null(0, SockT)
  if sk
    unless Events.output(Ev.new(sk.load.__sk_common.skc_family, sk.load.__sk_common.skc_num, sk.load.__sk_common.skc_dport, 0, sk.load.__sk_common.skc_daddr))
      Drops.atomic_add(0, 1)
    end
  end
end
BPF.fentry :on_retrans, "tcp_retransmit_skb", args: {0 => [:or_null, SockT]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   tcpretrans [--duration-ms MS] [--port PORT]   MS の間 (既定 5000) の TCP の再送を印字 (PORT が 0 でなければその宛先の port だけ — user の側で絞る)
#   tcpretrans --selftest                          自分の 127.0.0.1 の listen (backlog 0) を accept しない接続 1 つで満たし、2 つ目の非同期の connect の
#                                                  SYN を捨てさせて RTO の再送を起こす (host の設定は変えない — E154 追補 1) — 2.5 秒の間に family 2・宛先 127.0.0.1・
#                                                  dport が自分の listen の port の event が 1 つ以上 (他の再送は数えない)
require "spinelbpf"

# TR は自分の loopback の受け入れの queue を満たす listen と 2 つの connect (例の中の inline C — listen の port を返す、誤りは負) と後始末。
module TR
  ffi_source <<~C
    #include <arpa/inet.h>
    #include <fcntl.h>
    #include <netinet/in.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <unistd.h>
    static int tr_l = -1, tr_c1 = -1, tr_c2 = -1;
    long tr_setup(void) {
      struct sockaddr_in a;
      socklen_t sl = sizeof a;
      memset(&a, 0, sizeof a);
      a.sin_family = AF_INET;
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      tr_l = socket(AF_INET, SOCK_STREAM, 0);
      if (tr_l < 0) return -1;
      if (bind(tr_l, (struct sockaddr *)&a, sizeof a) != 0 || listen(tr_l, 0) != 0 || getsockname(tr_l, (struct sockaddr *)&a, &sl) != 0) return -2;
      tr_c1 = socket(AF_INET, SOCK_STREAM, 0);
      if (tr_c1 < 0 || connect(tr_c1, (struct sockaddr *)&a, sizeof a) != 0) return -3;
      usleep(100000);
      tr_c2 = socket(AF_INET, SOCK_STREAM, 0);
      if (tr_c2 < 0) return -4;
      fcntl(tr_c2, F_SETFL, O_NONBLOCK);
      connect(tr_c2, (struct sockaddr *)&a, sizeof a);
      return (long)ntohs(a.sin_port);
    }
    long tr_close(void) {
      if (tr_c2 >= 0) close(tr_c2);
      if (tr_c1 >= 0) close(tr_c1);
      if (tr_l >= 0) close(tr_l);
      return 0;
    }
  C
  ffi_func :tr_setup, [], :long
  ffi_func :tr_close, [], :long
end

# dport_host は skc_dport (network order の 2 byte を little endian の u16 として読んだ値) の host order。
def dport_host(d)
  ((d & 0xFF) << 8) | ((d >> 8) & 0xFF)
end

# addr4 は skc_daddr (network order の 4 byte を little endian の u32 として読んだ値) の印字。
def addr4(v)
  "#{v & 0xFF}.#{(v >> 8) & 0xFF}.#{(v >> 16) & 0xFF}.#{(v >> 24) & 0xFF}"
end

USAGE = "usage: tcpretrans [--duration-ms MS] [--port PORT] | --selftest"
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
r = obj.ringbuf(Events)
l = obj.attach_fentry("on_retrans")
lp = 0
if selftest
  lp = TR.tr_setup
  sleep(2.5) if lp > 0
  TR.tr_close
else
  puts "tracing TCP retransmits for #{duration_ms} ms#{port > 0 ? " (port #{port})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "  FAM  LPORT  RPORT  RADDR"
events = 0
ok = 0
v = r.read_record(200)
while v.length > 0
  dp = dport_host(v[2])
  if port == 0 || dp == port
    addr = v[0] == 2 ? addr4(v[4]) : "(v6)"
    puts "#{v[0].to_s.rjust(5)} #{v[1].to_s.rjust(6)} #{dp.to_s.rjust(6)}  #{addr}"
    events += 1
  end
  ok += 1 if v[0] == 2 && dp == lp && addr4(v[4]) == "127.0.0.1"
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  puts "port=#{lp} matching=#{ok}"
  if lp <= 0 || ok < 1
    puts "selftest FAILED: want at least one retransmit event of family 2 to 127.0.0.1 on this process's listen port"
    exit 1
  end
  puts "selftest ok"
end
