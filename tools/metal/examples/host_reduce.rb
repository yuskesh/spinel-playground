# E467 (P013): host side for reduce.rb — the threadgroup-cooperation proof.
#
#   (from tools/metal/examples/)
#   spinel-metal compile reduce.rb -o build/
#   spinel-metal host host_reduce.rb -o build/
#   ./build/host_reduce build 4096
#
# The kernel writes one partial sum per 256-lane threadgroup; this binary sums
# the partials (double precision) and compares against a CPU total over the
# same inputs. n must be a multiple of 256 (the kernel's tree assumes full
# groups — v0 boundary, checked here loudly). GPU_BRIDGE_PERTURB=1 shifts the
# oracle's input formula (negative control): if the reduction dropped or
# double-counted a single lane, the totals cannot agree at rel 1e-5.

require_relative "lib/gpu"            # static shim binding (module GPU)
require_relative "build/reduce_host"  # generated kernel binding (E458/E459)

metal_dir = ARGV.length >= 1 ? ARGV[0] : "build"
n         = ARGV.length >= 2 ? ARGV[1].to_i : 4096

if n % 256 != 0
  puts "BRIDGE FAIL: n must be a multiple of 256 (the kernel's tree assumes full threadgroups)"
elsif reduce_gpu_init(metal_dir, n) != 0
  puts "BRIDGE FAIL: gpu init (see stderr)"
else
  n.times do |i|
    reduce_x_set(i, i % 89 * 0.125)
  end

  if reduce_dispatch(n) != 0
    puts "BRIDGE FAIL: dispatch (see stderr)"
  else
    mult = ENV["GPU_BRIDGE_PERTURB"] != nil && ENV["GPU_BRIDGE_PERTURB"] == "1" ? 0.126 : 0.125
    groups = n / 256
    total = 0.0
    groups.times do |g|
      total = total + reduce_partial_get(g)
    end
    cpu = 0.0
    n.times do |i|
      cpu = cpu + i % 89 * mult
    end
    diff = total - cpu
    diff = 0.0 - diff if diff < 0.0
    mag = cpu
    mag = 0.0 - mag if mag < 0.0
    mag = 1.0 if mag < 1.0
    if diff / mag < 0.00001
      puts "BRIDGE PASS: #{n} elements reduced across #{groups} threadgroups (barrier + shared)"
    else
      puts "BRIDGE FAIL: gpu total and cpu total differ beyond rel 1e-5"
    end
  end
end
