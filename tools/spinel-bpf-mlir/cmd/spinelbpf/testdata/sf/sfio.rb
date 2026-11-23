require "bpf"

# E126 H4: user 空間の socket_filter の API — load の unmet、attach_socket と test_run_skb_packet の誤りの class (kind の取り違え・fd・長さ・byte)。root (load)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def sf(skb)
  n = skb.len
  Out.update(0, n)
  return BPF::SF_DROP if n > 64
  BPF::SF_KEEP
end
BPF.socket_filter :sf

def xp(ctx)
  Out.update(0, 7)
  BPF::XDP_PASS
end
BPF.xdp :xp

require "spinelbpf"

module HSock
  ffi_source <<~C
    #include <string.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/socket.h>
    static int h_sv[2] = {-1, -1};
    static char h_buf[4096];
    /* AF_UNIX の SOCK_DGRAM の対 — [0] は filter を付ける受け手 (non-blocking)、[1] は送り手。網の設定に触れない */
    long h_pair(void) {
      if (socketpair(AF_UNIX, SOCK_DGRAM, 0, h_sv) != 0) return -1;
      if (fcntl(h_sv[0], F_SETFL, O_NONBLOCK) != 0) return -1;
      return h_sv[0];
    }
    long h_send(long n) {
      if (n < 0 || n > (long)sizeof h_buf) return -1;
      memset(h_buf, 120, (size_t)n);
      return (long)send(h_sv[1], h_buf, (size_t)n, 0);
    }
    /* 受けた datagram の長さ、無ければ -1 (EAGAIN) */
    long h_recv(void) { return (long)recv(h_sv[0], h_buf, sizeof h_buf, 0); }
  C
  ffi_func :h_pair, [], :long
  ffi_func :h_send, [:long], :long
  ffi_func :h_recv, [], :long
end

def try(label)
  begin
    yield
    puts "#{label} ok"
  rescue SpinelBPF::Error => e
    puts "#{label} err=#{e.class}"
  end
end

obj = SpinelBPF.load_embedded
puts "load ok unmet=#{obj.unmet.length}"
fd = HSock.h_pair
try("attach_socket sf") { obj.attach_socket("sf", fd) }
try("attach_socket xp") { obj.attach_socket("xp", fd) }
try("attach_socket nope") { obj.attach_socket("nope", fd) }
try("attach_socket stdin") { obj.attach_socket("sf", 0) }
try("attach_xdp sf") { obj.attach_xdp("sf", "lo") }
try("attach_tcx sf") { obj.attach_tcx("sf", "lo") }
puts "run78 ret=#{obj.test_run_skb_packet("sf", Array.new(78, 0))} out=#{obj.map_get(Out, 0)}"
puts "run79 ret=#{obj.test_run_skb_packet("sf", Array.new(79, 0))} out=#{obj.map_get(Out, 0)}"
try("run13") { obj.test_run_skb_packet("sf", Array.new(13, 0)) }
try("run xp") { obj.test_run_skb_packet("xp", Array.new(64, 0)) }
try("xdp run sf") { obj.test_run_xdp_packet("sf", Array.new(64, 0)) }
try("run byte 256") { obj.test_run_skb_packet("sf", Array.new(64, 256)) }
