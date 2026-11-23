require "bpf"

Out = BPF::ArrayMap.new("Out", :u32, 2)

# E015: data の bytes が kernel に届くこと (u8(0) と長さ 14 の window の最後の byte を map に)
def first(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(0, w.u8(0))
    Out.update(1, w.u8(13))
  else
    Out.update(0, 999)
  end
  BPF::XDP_PASS
end
BPF.xdp :first

# user 空間の側: test_run_xdp_packet の値の範囲と data の長さの下限を 1 行ずつ出す
require "spinelbpf"

obj = SpinelBPF.load_embedded
def frame(n, b0, last)
  a = Array.new(n, 0)
  if n > 0
    a[0] = b0
  end
  if n > 13
    a[13] = last
  end
  a
end
[0, 1, 13, 14, 15, 64, 1500].each do |n|
  begin
    obj.map_put(Out, 0, 0)
    obj.map_put(Out, 1, 0)
    r = obj.test_run_xdp_packet("first", frame(n, 7, 200))
    puts "len=#{n} ret=#{r} out0=#{obj.map_get(Out, 0)} out1=#{obj.map_get(Out, 1)}"
  rescue => e
    puts "len=#{n} err=#{e.class} hint=#{e.message.include?("at least 14 bytes")}"
  end
end
[[256, 0], [-1, 0]].each do |bad|
  begin
    obj.test_run_xdp_packet("first", frame(14, bad[0], bad[1]))
    puts "byte=#{bad[0]} ok"
  rescue => e
    puts "byte=#{bad[0]} err=#{e.class}"
  end
end
