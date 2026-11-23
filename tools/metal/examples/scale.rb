# E459 (P013): the :int buffer kernel — w[i] = v[i] * 3 + 1, on int64 buffers.
#
#   spinel-metal compile examples/scale.rb -o build/
#
# Why this example exists: the host harness feeds it values ABOVE 2^53, which
# do not survive a double. The generated host binding therefore goes through
# the integer FFI lane (ogpu_write_i/ogpu_read_i, :long) — if anything on the
# path quietly routed these through a double, the in-binary oracle would catch
# the corrupted low bits.
gpu_buffer :v, :int, 0
gpu_buffer :w, :int, 1

def kernel__scale
  i = gpu_global_id
  gpu_store(:w, i, gpu_load(:v, i) * 3 + 1)
end
