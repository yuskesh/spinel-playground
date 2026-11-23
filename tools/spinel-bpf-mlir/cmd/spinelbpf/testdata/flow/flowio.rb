require "bpf"

# E130 H4: user 空間の flow_dissector の API — load の unmet、test run と attach_netns の誤りの class、自分の netns (unshare — inode の確かめの後) への
# attach_netns と detach (traffic は流さない)。root (load)。host の netns には付けない
def flow4(ctx)
  w = ctx.check(14, 20)
  if w
    ctx.set_key(:addr_proto, 0x0800)
    ctx.set_key(:ip_proto, w.u8(9))
    ctx.set_key(:ipv4_src, w.le32(12))
    ctx.set_key(:ipv4_dst, w.le32(16))
    ctx.set_key(:thoff, (ctx.key(:nhoff) + 20) & 0xFFFF)
  end
  return BPF::FLOW_DROP if ctx.key(:n_proto) != 8
  BPF::FLOW_OK
end


BPF.flow_dissector :flow4

def xp(ctx)
  BPF::XDP_PASS
end
BPF.xdp :xp

require "spinelbpf"

module HNs
  ffi_source <<~C
    #include <string.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/stat.h>
    int unshare(int flags);
    #ifndef CLONE_NEWNET
    #define CLONE_NEWNET 0x40000000
    #endif
    long h_netns(void) { struct stat st; return stat("/proc/thread-self/ns/net", &st) == 0 ? (long)st.st_ino : -1; }
    long h_unshare(void) { return unshare(CLONE_NEWNET) == 0 ? 0 : -errno; }
    /* この thread の netns の nsfs の fd (attach_netns に渡す) */
    long h_nsfd(void) { return (long)open("/proc/thread-self/ns/net", O_RDONLY); }
  C
  ffi_func :h_netns, [], :long
  ffi_func :h_unshare, [], :long
  ffi_func :h_nsfd, [], :long
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
before = HNs.h_netns
u = HNs.h_unshare
after = HNs.h_netns
moved = 0
if u == 0 && before > 0 && after > 0 && after != before
  moved = 1
end
puts "netns before=#{before} after=#{after} moved=#{moved}"
if moved != 1
  raise "not in a new netns (unshare #{u}) — nothing is attached (E130)"
end
puts "load ok unmet=#{obj.unmet.length}"
try("run13") { obj.test_run_flow_dissector("flow4", Array.new(13, 0)) }
try("flow run xp") { obj.test_run_flow_dissector("xp", Array.new(64, 0)) }
try("attach_netns xp") { obj.attach_netns("xp", HNs.h_nsfd) }
try("attach_netns stdin") { obj.attach_netns("flow4", 0) }
r = obj.test_run_flow_dissector("flow4", Array.new(64, 0))
puts "run64 ret=#{r[0]} n=#{r.length} nhoff=#{r[1]} thoff=#{r[2]}"
fd = HNs.h_nsfd
l = obj.attach_netns("flow4", fd)
puts "attached"
l.detach
puts "detached"
