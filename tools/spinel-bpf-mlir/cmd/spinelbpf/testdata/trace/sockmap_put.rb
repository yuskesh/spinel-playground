require "bpf"

# E129 (P026) の H0 — bml の口の確かめ (†): sockmap を持つ sk_lookup の ELF の load、自分の process の UDP の socket (127.0.0.1:7301) の fd の
# put は OK、socket でない fd (pipe) の put は kernel が sockmap の更新を拒む (bml の誤り — 黙って入らない)。
Socks = BPF::SockMap.new("Socks", :u64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def pick(ctx)
  st = Socks.assign(ctx, 0)
  Out.update(0, st)
  BPF::SK_PASS
end
BPF.sk_lookup :pick

require "spinelbpf"

module HSk
  ffi_source <<~C
    #include <string.h>
    #include <unistd.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    /* 127.0.0.1:port の UDP の socket (bind だけ — unconnected) の fd、失敗は -1 */
    long h_udp(long port) {
      int s = socket(AF_INET, SOCK_DGRAM, 0);
      if (s < 0) return -1;
      struct sockaddr_in a;
      memset(&a, 0, sizeof a);
      a.sin_family = AF_INET;
      a.sin_port = htons((unsigned short)port);
      a.sin_addr.s_addr = htonl(0x7f000001);
      if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return -1; }
      return s;
    }
    /* pipe の読みの端の fd (socket でない) */
    long h_pipe(void) { int p[2]; if (pipe(p) != 0) return -1; return p[0]; }
  C
  ffi_func :h_udp, [:long], :long
  ffi_func :h_pipe, [], :long
end

obj = SpinelBPF.load_embedded
puts "load kind=OK"
fd = HSk.h_udp(7301)
if fd < 0
  raise "udp socket failed"
end
obj.map_put(Socks, 0, fd)
puts "put udp kind=OK"
begin
  obj.map_put(Socks, 1, HSk.h_pipe)
  puts "put pipe kind=OK"
rescue SpinelBPF::Error => e
  puts "put pipe kind=#{e.class} msg=#{e.message}"
end
obj.close
