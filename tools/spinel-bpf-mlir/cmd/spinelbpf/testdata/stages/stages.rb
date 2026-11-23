# E044 の段の試験の driver (E003 の loader/testdata/driver.rb を C の loader に移したもの)。埋め込みの ELF を、引数の sha・maps.json・caps の種類で
# spinelbpf_load_checked に渡す (試験の caps の libbml を link — 種類 1 は全て無いと答える)。Big は u64 の 2^63 以上の読みの ValueRange のため。
require "bpf"

Counts = BPF::ArrayMap.new("Counts", :u64, 2)
Big = BPF::ArrayMap.new("Big", :u64, 1)

def count_pkts(ctx)
  Counts.atomic_add(0, 1)
  Big.atomic_add(0, 9223372036854775807)
  BPF::XDP_PASS
end
BPF.xdp :count_pkts

require "spinelbpf"

# load <sha|-> <maps.json|-> <caps>: "-" は埋め込みのもの
def load_with(sha, maps, caps)
  s = sha == "-" ? SpinelBPFC.spinelbpf_embedded_sha : sha
  m = maps == "-" ? SpinelBPFC.spinelbpf_embedded_maps : File.read(maps)
  h = SpinelBPF.check(SpinelBPFC.spinelbpf_load_checked(SpinelBPFC.spinelbpf_embedded_elf, SpinelBPFC.spinelbpf_embedded_elf_len, s, m, caps))
  SpinelBPF::Loaded.new(h)
end

def show(tag, e)
  puts "#{tag} kind=#{e.class} msg=#{e.message.split("\n").join(" | ")}"
end

mode = ARGV[0]
if mode == "load"
  begin
    obj = load_with(ARGV[1], ARGV[2], ARGV[3].to_i)
    puts "load kind=OK"
    puts "run value=#{obj.test_run_xdp("count_pkts", 3)} counts0=#{obj.map_get(Counts, 0)}"
    obj.close
  rescue SpinelBPF::Error => e
    show("load", e)
  end
elsif mode == "state"
  begin
    SpinelBPF::Loaded.new(12345).map_get(Counts, 0)
    puts "before kind=OK"
  rescue SpinelBPF::Error => e
    show("before", e)
  end
  obj = load_with("-", "-", 0)
  puts "load1 kind=OK"
  begin
    load_with("-", "-", 0)
    puts "load2 kind=OK"
  rescue SpinelBPF::Error => e
    show("load2", e)
  end
  obj.close
  begin
    obj.map_get(Counts, 0)
    puts "closed kind=OK"
  rescue SpinelBPF::Error => e
    show("closed", e)
  end
elsif mode == "range"
  obj = load_with("-", "-", 0)
  w = 0
  while w < 2
    obj.test_run_xdp("count_pkts", 1)
    begin
      puts "get#{w} kind=OK value=#{obj.map_get(Big, 0)}"
    rescue SpinelBPF::Error => e
      show("get#{w}", e)
    end
    w += 1
  end
  obj.close
elsif mode == "fiber"
  f = Fiber.new do
    i = 0
    while i < 20
      begin
        load_with(ARGV[1], ARGV[2], ARGV[3].to_i)
        puts "fiber#{i} kind=OK"
      rescue SpinelBPF::Error => e
        puts "fiber#{i} kind=#{e.class}"
      end
      i += 1
    end
    0
  end
  f.resume
  puts "after"
else
  puts "unknown mode #{mode}"
end
