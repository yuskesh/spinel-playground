# E459 (P013): host side for scale.rb — the :int buffer proof.
#
#   (from tools/metal/examples/)
#   spinel-metal compile scale.rb -o build/
#   spinel-metal host host_scale.rb -o build/
#   ./build/host_scale build 4096
#
# The inputs sit ABOVE 2^53 (base 9_007_199_254_740_993 = 2^53 + 1), where a
# double has no exact representation — if any hop of the bridge (FFI, shim,
# buffer element, readback) quietly went through a double, the low bits would
# corrupt and the in-binary oracle would report it. The generated binding
# routes :int buffers through the :long lane (ogpu_write_i / ogpu_read_i), so
# this passing is the measurement that the integer path is really integer
# end-to-end. GPU_BRIDGE_PERTURB=1 flips the oracle's multiplier (negative
# control, E415).

require_relative "lib/gpu"          # static shim binding (module GPU)
require_relative "build/scale_host" # generated kernel binding (E458/E459)

metal_dir = ARGV.length >= 1 ? ARGV[0] : "build"
n         = ARGV.length >= 2 ? ARGV[1].to_i : 4096

base = 9007199254740993   # 2^53 + 1: not representable as a double

if scale_gpu_init(metal_dir, n) != 0
  puts "BRIDGE FAIL: gpu init (see stderr)"
else
  n.times do |i|
    scale_v_set(i, base + i)
  end

  if scale_dispatch(n) != 0
    puts "BRIDGE FAIL: dispatch (see stderr)"
  else
    mult = ENV["GPU_BRIDGE_PERTURB"] != nil && ENV["GPU_BRIDGE_PERTURB"] == "1" ? 4 : 3
    bad = 0
    n.times do |i|
      expected = (base + i) * mult + 1
      got = scale_w_get(i)
      bad = bad + 1 if got != expected   # int64: exact equality, no tolerance
    end
    if bad == 0
      puts "BRIDGE PASS: #{n} int64 elements above 2^53, exact"
    else
      puts "BRIDGE FAIL: #{bad}/#{n} int64 elements differ"
    end
  end
end
