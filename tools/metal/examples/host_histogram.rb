# E469 (P013): host side for histogram.rb — the atomic-contention proof.
#
#   (from tools/metal/examples/)
#   spinel-metal compile histogram.rb -o build/
#   spinel-metal host host_histogram.rb -o build/
#   ./build/host_histogram build 4096
#
# The host zeroes the 64 bins, dispatches n threads that all hammer the same
# 64 cells, then recomputes every bin's count on the CPU (a scalar recount per
# bin — no arrays, so the oracle stays inside the native subset) and demands
# EXACT equality: counts are integers, and one lost update under contention —
# the bug atomics exist to prevent — is one missing count.
# GPU_BRIDGE_PERTURB=1 shifts the oracle's binning formula (negative control).
# The inputs are deliberately NON-uniform across bins (i % 89 * 7): a uniform
# histogram is invariant under a formula shift, which made the first version of
# this control pass vacuously -- measured, then fixed.

require_relative "lib/gpu"               # static shim binding (module GPU)
require_relative "build/histogram_host"  # generated kernel binding (E458/E459)

metal_dir = ARGV.length >= 1 ? ARGV[0] : "build"
n         = ARGV.length >= 2 ? ARGV[1].to_i : 4096

if histogram_gpu_init(metal_dir, n) != 0
  puts "BRIDGE FAIL: gpu init (see stderr)"
else
  n.times do |i|
    histogram_x_set(i, i % 89 * 7)
  end
  64.times do |b|
    histogram_h_set(b, 0)
  end

  if histogram_dispatch(n) != 0
    puts "BRIDGE FAIL: dispatch (see stderr)"
  else
    shift = ENV["GPU_BRIDGE_PERTURB"] != nil && ENV["GPU_BRIDGE_PERTURB"] == "1" ? 1 : 0
    bad = 0
    64.times do |b|
      count = 0
      n.times do |i|
        v = i % 89 * 7 + shift
        count = count + 1 if v % 64 == b
      end
      bad = bad + 1 if histogram_h_get(b) != count
    end
    if bad == 0
      puts "BRIDGE PASS: #{n} atomic adds across 64 contended bins, exact"
    else
      puts "BRIDGE FAIL: #{bad}/64 bins differ (a lost update is a missing count)"
    end
  end
end
