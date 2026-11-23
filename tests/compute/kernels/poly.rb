gpu_buffer :x, :f32, 0
gpu_buffer :y, :f32, 1

def kernel__poly
  i = gpu_global_id
  v = gpu_load(:x, i)
  acc = 0.0
  k = 1.0
  8.times do |j|
    acc = acc * v + k
    k = k + 1.0
  end
  gpu_store(:y, i, Math.sqrt(acc * acc))
end
