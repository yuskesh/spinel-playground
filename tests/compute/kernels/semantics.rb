# One kernel for the lane-wide integer contract (decision 0031, section 5).
gpu_workgroup 4
gpu_buffer :a, :i32, 0
gpu_buffer :b, :i32, 1
gpu_buffer :o, :i32, 2
gpu_buffer :cnt, :atomic, 3
gpu_shared :s, :i32, 4

def kernel__semantics
  g = gpu_global_id
  t = gpu_local_id
  ai = gpu_load(:a, g)
  bi = gpu_load(:b, g)
  lt = 0
  m = bi
  if ai < bi
    lt = 1
    m = ai
  end
  gpu_shared_store(:s, t, ai)
  gpu_barrier
  neighbour = gpu_shared_load(:s, (t + 1) & 3)
  if g < 16
    base = g * 8
    gpu_store(:o, base, ai / bi)
    gpu_store(:o, base + 1, ai % bi)
    gpu_store(:o, base + 2, ai >> bi)
    gpu_store(:o, base + 3, ai << bi)
    gpu_store(:o, base + 4, lt)
    gpu_store(:o, base + 5, ai + bi)
    gpu_store(:o, base + 6, m)
    gpu_store(:o, base + 7, neighbour)
  end
  gpu_atomic_add(:cnt, 0, 1)
end
