# E466 (P013): host side for poly.rb — the loop-kernel proof.
#
#   (from tools/metal/examples/)
#   spinel-metal compile poly.rb -o build/
#   spinel-metal host host_poly.rb -o build/
#   ./build/host_poly build 4096
#
# The in-binary oracle runs the SAME 8-step Horner loop in Ruby (double
# precision) that the kernel runs in float32 — both sides spell the loop as
# `8.times`, so this is also the measurement that the two lowerings of one
# syntax agree. Inputs stay in [0, 0.97) so the chain is well-conditioned.
# Beyond the pass threshold (rel 1e-5, saxpy's), the oracle counts how many
# elements exceed 1e-6 and 1e-7 too: an empirical bracket for where float32
# lands on a chain this deep. GPU_BRIDGE_PERTURB=1 shifts the oracle's
# constant term (negative control).

require_relative "lib/gpu"          # static shim binding (module GPU)
require_relative "build/poly_host"  # generated kernel binding (E458/E459)

metal_dir = ARGV.length >= 1 ? ARGV[0] : "build"
n         = ARGV.length >= 2 ? ARGV[1].to_i : 4096

if poly_gpu_init(metal_dir, n) != 0
  puts "BRIDGE FAIL: gpu init (see stderr)"
else
  n.times do |i|
    poly_x_set(i, i % 97 * 0.01)
  end

  if poly_dispatch(n) != 0
    puts "BRIDGE FAIL: dispatch (see stderr)"
  else
    addc = ENV["GPU_BRIDGE_PERTURB"] != nil && ENV["GPU_BRIDGE_PERTURB"] == "1" ? 1.5 : 1.0
    bad = 0
    over6 = 0
    over7 = 0
    n.times do |i|
      v = i % 97 * 0.01
      acc = 0.0
      8.times do |j|
        acc = acc * v + addc + j
      end
      got = poly_y_get(i)
      diff = got - acc
      diff = 0.0 - diff if diff < 0.0
      mag = acc
      mag = 0.0 - mag if mag < 0.0
      mag = 1.0 if mag < 1.0
      rel = diff / mag
      bad = bad + 1 if rel > 0.00001
      over6 = over6 + 1 if rel > 0.000001
      over7 = over7 + 1 if rel > 0.0000001
    end
    if bad == 0
      puts "BRIDGE PASS: #{n} elements, 8-step loop chain (over 1e-6: #{over6}, over 1e-7: #{over7})"
    else
      puts "BRIDGE FAIL: #{bad}/#{n} elements differ beyond rel 1e-5"
    end
  end
end
