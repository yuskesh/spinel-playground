# examples/tensor/fusion -- the host world.
#
#   app <device> <vmfb> [n]
#
# This file **cannot be compiled as it is**.
#    The `y.assign!(x * alpha + y)` below is a fused **statement**, not an expression Ruby
#    can evaluate normally (Ruby would evaluate the argument before calling assign!).
#    build.sh runs `spinel-mlirgen --tensor --fuse` and compiles **app.fused.rb**, in which
#    this one statement is rewritten into a call to a generated dispatch.
#    Only the replaced statement is rewritten; no other byte moves:
#    `diff app.rb build/app.fused.rb` is exactly "what was compiled".
#
# The point is one line: **one statement on the caller's side becomes one dispatch**. kernels.rb,
# which splits the same computation into 2 tensor_defs, takes 2 dispatches and gives different bits.
require_relative "spinel/tensor"
require_relative "kernels.gen"

module SPX
  ffi_func :sp_t_hash64, [:float_array, :size_t], :int64
end

# The same LCG and the same seed as the predecessor's measurements.
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

# The largest |got - ref| over the largest |ref|. A NaN anywhere is the answer,
# because a comparison with NaN would otherwise pass over it.
def max_relative(got, ref, n)
  maxdiff = 0.0
  maxref = 0.0
  i = 0
  while i < n
    d = got[i] - ref[i]
    return d if d != d
    d = -d if d < 0.0
    maxdiff = d if d > maxdiff
    r = ref[i]
    r = -r if r < 0.0
    maxref = r if r > maxref
    i += 1
  end
  maxref > 0.0 ? maxdiff / maxref : 0.0
end

def slice(all, base, n)
  r = Array.new(n, 0.0)
  i = 0
  while i < n
    r[i] = all[base + i]
    i += 1
  end
  r
end

device = ARGV[0]
vmfb   = ARGV[1]
n      = ARGV.length > 2 ? ARGV[2].to_i : 16384
alpha  = 2.5

xa = gen(n, 20260816)
ya = gen(n, 777)

all = Tensor.device(device, vmfb) do
  x = Tensor.of(:f32, n, xa)
  y = Tensor.of(:f32, n, ya)
  i0 = SPT.sp_t_counter(2)            # counter 2 = the number of invokes

  # ---- fused: one statement ------------------------------------------------
  y.assign!(x * alpha + y)

  i1 = SPT.sp_t_counter(2)
  fused = y.to_f32_a

  # ---- not fused: the same computation with 2 tensor_defs -------------------
  y2 = Tensor.of(:f32, n, ya)
  t = Tensor.vec(:f32, n)             # an intermediate buffer is needed (the fused side has none)
  i2 = SPT.sp_t_counter(2)
  k_mul(alpha, x, t)
  k_addto(t, y2)
  i3 = SPT.sp_t_counter(2)
  chain = y2.to_f32_a

  r = Array.new(2 * n + 2, 0.0)
  i = 0
  while i < n
    r[i] = fused[i]
    r[n + i] = chain[i]
    i += 1
  end
  r[2 * n] = (i1 - i0).to_f
  r[2 * n + 1] = (i3 - i2).to_f
  r
end

fused = slice(all, 0, n)
chain = slice(all, n, n)
inv_fused = all[2 * n].to_i
inv_chain = all[2 * n + 1].to_i

puts "device\t#{device}"
puts "n\t#{n}"
puts "invocations_fused\t#{inv_fused}"
puts "invocations_chain\t#{inv_chain}"
printf("hash_fused\t%d\n", SPX.sp_t_hash64(fused, n))
printf("hash_chain\t%d\n", SPX.sp_t_hash64(chain, n))
# The fused statement against the same kernels run one by one: both are this
# compiler's output, so this is the fusion pass's own claim, not an oracle.
printf("ndiff_fused_vs_chain\t%d\n", ndiff(fused, chain, n))
printf("maxrel_fused_vs_chain\t%.6e\n", max_relative(fused, chain, n))

# --- the f64 oracle: a second implementation in plain Ruby. Comparing with it
# is an oracle, which runs only when asked (SPINEL_ORACLE=1).
if ENV["SPINEL_ORACLE"] == "1"
  ref = Array.new(n, 0.0)
  i = 0
  while i < n
    ref[i] = alpha * xa[i] + ya[i]
    i += 1
  end
  printf("normwise_fused\t%.6e\n", normwise(fused, ref, n))
  printf("normwise_chain\t%.6e\n", normwise(chain, ref, n))
end
