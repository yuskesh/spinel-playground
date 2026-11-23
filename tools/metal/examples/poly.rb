# E466 (P013): the loop kernel — an 8-step Horner chain per element.
#
#   spinel-metal compile examples/poly.rb -o build/
#
# Why this example exists: it is the first kernel that needs a LOOP. On the
# GPU there is no verifier, so `8.times { |j| ... }` lowers to a plain MSL
# `for` — no bpf_loop callback, no capture struct, no kernel-version floor
# (E466). The 8-step multiply-add chain is also deliberately deeper than
# saxpy's single fma: the host oracle measures where float32 actually lands
# against a double reference on a longer dependent chain.
gpu_buffer :x, :float, 0
gpu_buffer :y, :float, 1

def kernel__poly
  i = gpu_global_id
  v = gpu_load(:x, i)
  acc = 0.0
  8.times do |j|
    acc = acc * v + 1.0 + j
  end
  gpu_store(:y, i, acc)
end
