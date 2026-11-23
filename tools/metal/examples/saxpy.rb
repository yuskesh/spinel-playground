# E456/E459 (P013): the gpu-metal kernel — saxpy, out[i] = 2.5 * x[i] + y[i].
#
#   spinel-metal compile examples/saxpy.rb -o build/
#
# The gpu_buffer declarations are the buffer contract (E459): name + element
# type + [[buffer(N)]] slot, in one place. Everything else derives from them —
# the MSL parameter names and types, the host binding's accessors
# (saxpy_x_set / saxpy_out_get, extracted from the emitted .metal), and the
# init's per-slot type spec. The body refers to buffers by NAME; a slot
# literal here is a compile error (two spellings for one buffer is how the
# kernel and the host drift apart).
gpu_buffer :x,   :float, 0
gpu_buffer :y,   :float, 1
gpu_buffer :out, :float, 2

def kernel__saxpy
  i = gpu_global_id
  gpu_store(:out, i, 2.5 * gpu_load(:x, i) + gpu_load(:y, i))
end
