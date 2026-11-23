# E457/E458 (P013): the host side of the GPU bridge — a spinel-compiled NATIVE
# binary that drives the Metal GPU itself.
#
#   (from tools/metal/examples/)
#   spinel-metal compile saxpy.rb -o build/         # kernel + host binding
#   spinel-metal host host_saxpy.rb -o build/ # this unit
#   ./build/host_saxpy build 4096
#
# E458: everything kernel-derived — the kernel name, how many buffers, which
# slot is an input and which an output, the .metal filename — comes from the
# GENERATED build/saxpy_host.rb, extracted from the .metal itself (the same
# walk that emitted the kernels). This file only says what the machine cannot
# know: the input values, N, and what "correct" means. Using a buffer against
# its direction (saxpy_out_set / saxpy_x_get) is an undefined method at
# compile time — the binding simply doesn't contain it.
#
# The oracle is IN the binary: after the dispatch it recomputes every element
# in Ruby doubles and compares (rel tol 1e-5 for float32-vs-double rounding).
# GPU_BRIDGE_PERTURB=1 flips the verification coefficient — the run MUST then
# report FAIL, or the in-binary check is vacuous (E415 negative control).

require_relative "lib/gpu"          # static shim binding (module GPU)
require_relative "build/saxpy_host" # generated kernel binding (E458)

metal_dir = ARGV.length >= 1 ? ARGV[0] : "build"
n         = ARGV.length >= 2 ? ARGV[1].to_i : 4096

if saxpy_gpu_init(metal_dir, n) != 0
  puts "BRIDGE FAIL: gpu init (see stderr)"
else
  # deterministic inputs, exact in float32 (same values as the E456 harness)
  n.times do |i|
    saxpy_x_set(i, (i % 1000) * 0.25 + 0.5)
    saxpy_y_set(i, ((i * 7) % 997) * 0.125)
  end

  if saxpy_dispatch(n) != 0
    puts "BRIDGE FAIL: dispatch (see stderr)"
  else
    # in-binary oracle: recompute in Ruby doubles. The perturbed coefficient is
    # the negative control -- with it the comparison must fail.
    coeff = ENV["GPU_BRIDGE_PERTURB"] != nil && ENV["GPU_BRIDGE_PERTURB"] == "1" ? 2.6 : 2.5
    bad = 0
    max_rel = 0.0
    n.times do |i|
      x = (i % 1000) * 0.25 + 0.5
      y = ((i * 7) % 997) * 0.125
      expected = coeff * x + y
      got = saxpy_out_get(i)
      diff = got - expected
      diff = 0.0 - diff if diff < 0.0
      scale = expected
      scale = 0.0 - scale if scale < 0.0
      scale = 1.0 if scale < 1.0
      rel = diff / scale
      max_rel = rel if rel > max_rel
      bad = bad + 1 if rel > 0.00001
    end
    if bad == 0
      puts "BRIDGE PASS: #{n} elements, gpu == in-binary oracle"
    else
      puts "BRIDGE FAIL: #{bad}/#{n} elements differ (max_rel=#{max_rel})"
    end
  end
end
