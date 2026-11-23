# E469 (P013): the atomic kernel — a 64-bin histogram over device atomics.
#
#   spinel-metal compile examples/histogram.rb -o build/
#
# Why this example exists: it is the first kernel where threads write to the
# SAME cells concurrently. Every thread computes its input's bin and bumps it
# with gpu_atomic_add on an :atomic buffer (32-bit atomic_int lanes — the only
# integer width MSL guarantees device atomics for). The counts are integers,
# so the host oracle demands EXACT equality: a single lost update under
# contention — the bug atomics exist to prevent — breaks the run.
gpu_buffer :x, :int, 0
gpu_buffer :h, :atomic, 1

def kernel__histogram
  v = gpu_load(:x, gpu_global_id)
  gpu_atomic_add(:h, v % 64, 1)
end
