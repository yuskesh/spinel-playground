# E467 (P013): the threadgroup-cooperation kernel — a 256-lane tree reduction.
#
#   spinel-metal compile examples/reduce.rb -o build/
#
# Why this example exists: it is the first kernel where threads COOPERATE.
# Each threadgroup stages its 256 inputs in a `gpu_shared` array, then halves
# the active lanes 8 times with a `gpu_barrier` between steps, and lane 0
# writes the group's partial sum to `partial[gpu_group_id]`. The host sums the
# partials. Assumes the dispatch threadgroup width is 256 (the shim pins
# min(maxTotalThreadsPerThreadgroup, 256)) and n is a multiple of 256 —
# documented v0 boundary, the host side checks it.
gpu_buffer :x, :float, 0
gpu_buffer :partial, :float, 1
gpu_shared :acc, :float, 256

def kernel__reduce
  i = gpu_global_id
  l = gpu_local_id
  gpu_shared_store(:acc, l, gpu_load(:x, i))
  gpu_barrier
  8.times do |s|
    stride = 256 >> (s + 1)
    if l < stride
      gpu_shared_store(:acc, l, gpu_shared_load(:acc, l) + gpu_shared_load(:acc, l + stride))
    end
    gpu_barrier
  end
  if l == 0
    gpu_store(:partial, gpu_group_id, gpu_shared_load(:acc, 0))
  end
end
