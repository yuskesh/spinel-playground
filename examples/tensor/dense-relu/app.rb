# examples/tensor/dense-relu -- the host world. Ordinary Ruby.
#
#   app <device> <vmfb> [rows] [cols] [n]
#     device: local-sync | local-task | metal
#
# The GPU's name appears only in the device argument; everything else is Tensor and
# calls to `dense_relu` / `sumsq` / `sumsq_ft`, generated from kernels.rb.
require_relative "spinel/tensor"
require_relative "kernels.gen"

# Scaffolding for checking. sp_t_hash64 lives in the shim (tools/tensor/sp_tensor_shim.c).
module SPX
  ffi_func :sp_t_hash64, [:float_array, :size_t], :int64
end

# Deterministic test vectors. The same LCG and the same seed as the predecessor's measurements,
# so the numbers match its recorded rows element for element.
def gen(n, seed)
  a = Array.new(n, 0.0)
  s = seed
  i = 0
  while i < n
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF
    a[i] = ((s >> 7) & 0xFFFFFF).to_f / 8388608.0 - 1.0
    i += 1
  end
  a
end

def ndiff(a, b, n)
  d = 0
  i = 0
  while i < n
    d += 1 if a[i] != b[i]
    i += 1
  end
  d
end

# f32 is compared "bitwise first, normwise if that breaks".
# Element-wise relative error misleads with denominators near zero, so it is not used.
def normwise(got, ref, n)
  maxdiff = 0.0
  maxref = 0.0
  i = 0
  while i < n
    d = got[i] - ref[i]
    d = -d if d < 0.0
    maxdiff = d if d > maxdiff
    r = ref[i]
    r = -r if r < 0.0
    maxref = r if r > maxref
    i += 1
  end
  maxref > 0.0 ? maxdiff / maxref : 0.0
end

device = ARGV[0]
vmfb   = ARGV[1]
rows   = ARGV.length > 2 ? ARGV[2].to_i : 4
cols   = ARGV.length > 3 ? ARGV[3].to_i : 8
n      = ARGV.length > 4 ? ARGV[4].to_i : 1024

wa = gen(rows * cols, 4242)
ba = gen(rows, 99)
xa = gen(cols, 20260816)
va = gen(n, 20260816)

# --- the device scope. A Tensor can live only inside it ------------------------
out = Tensor.device(device, vmfb) do
  w = Tensor.of_mat(:f32, rows, cols, wa)   # the shape is declared; the data is always flat
  b = Tensor.of(:f32, rows, ba)
  x = Tensor.of(:f32, cols, xa)
  y = Tensor.vec(:f32, rows)
  dense_relu(w, b, x, y)                    # matvec + add + relu = 1 dispatch

  v = Tensor.of(:f32, n, va)
  s0 = sumsq(v)                             # the default order of additions
  s1 = sumsq_ft(v)                          # a fixed tree (B=2)

  r = Array.new(rows + 2, 0.0)
  lay = y.to_f32_a                          # the only d2h is here
  i = 0
  while i < rows
    r[i] = lay[i]
    i += 1
  end
  r[rows] = s0
  r[rows + 1] = s1
  r
end

layer = Array.new(rows, 0.0)
i = 0
while i < rows
  layer[i] = out[i]
  i += 1
end
sum_default = out[rows]
sum_fixed   = out[rows + 1]

puts "device\t#{device}"
puts "layer_shape\t#{rows}x#{cols}"
printf("dense_relu_hash\t%d\n", SPX.sp_t_hash64(layer, rows))
puts "reduction_n\t#{n}"
printf("sumsq_default\t%.17g\n", sum_default)
printf("sumsq_fixed_tree\t%.17g\n", sum_fixed)

# --- the f64 oracle: a second implementation of the same kernels, in plain
# Ruby on the host. Comparing with it is an oracle, which in this repository
# runs only when asked (SPINEL_ORACLE=1); the lines it prints are the ones
# spinel-llvm printed unconditionally.
if ENV["SPINEL_ORACLE"] == "1"
  ref = Array.new(rows, 0.0)
  r = 0
  while r < rows
    acc = 0.0
    c = 0
    while c < cols
      acc += wa[r * cols + c] * xa[c]
      c += 1
    end
    s = acc + ba[r]
    ref[r] = s > 0.0 ? s : 0.0
    r += 1
  end

  sq = 0.0
  i = 0
  while i < n
    sq += va[i] * va[i]
    i += 1
  end

  printf("dense_relu_ndiff_vs_f64\t%d\n", ndiff(layer, ref, rows))
  printf("dense_relu_normwise\t%.6e\n", normwise(layer, ref, rows))
  printf("sumsq_oracle_f64\t%.17g\n", sq)
end
