# E076 demo A, phase 2 (GPU) -- apply the LEARNED window on the device.
#
#   ./apply <device> <vmfb> <img.pgm> <learned.txt> <outdir|->
#     device: local-sync | local-task | metal
#
# The coefficients this program uploads were not written by anybody.  They came
# out of `train`, which recovered them from an (input, wanted output) pair with
# the gradient Enzyme synthesised from the Ruby method in filter_learn.rb.
#
# WHY THEY CAN BE UPLOADED AT ALL.  P002's window coefficients are DECLARED
# (R004 W2, `windows:` on `tensor_def`), which means changing them is a
# recompile -- a learned window could never arrive that way.  R004 W6 is the
# rule that makes this demo possible: coefficients that depend on run time are
# TENSOR ARGUMENTS, built by the host in f64 and rounded to f32 exactly once on
# upload.  `tap_mul(:d0|:d1, idx, wgt)` (E072) is that entry, and the
# declarations in kernels.rb are copied BYTE FOR BYTE from
# examples/image/resize -- nothing in the tensor lane was touched to receive a
# learned filter.
#
# A separable 3-tap window is a banded matrix with K = 3 and n_out == n_in;
# `idx` carries the clamped tap positions (which is where the replicate border
# lives -- the entry has no `border:` of its own) and `wgt` carries the learned
# taps, the same value in every row.
require_relative "spinel/tensor"
require_relative "kernels.gen"

def pnm_dims(path)
  f = File.open(path, "rb")
  raise TensorError, "#{path}: not P5" if f.gets.chomp != "P5"
  d = f.gets.chomp.split(" ")
  raise TensorError, "#{path}: maxval must be 255" if f.gets.chomp.to_i != 255
  f.close
  a = Array.new(2, 0)
  a[0] = d[0].to_i
  a[1] = d[1].to_i
  a
end

def pnm_data(path, n)
  f = File.open(path, "rb")
  f.gets
  f.gets
  f.gets
  d = f.read(n)
  f.close
  raise TensorError, "#{path}: short read" if d.length != n
  d
end

def read_taps(path)
  f = File.open(path, "r")
  a = f.gets.chomp.split(" ")
  b = f.gets.chomp.split(" ")
  f.close
  t = Array.new(6, 0.0)
  t[0] = a[0].to_f
  t[1] = a[1].to_f
  t[2] = a[2].to_f
  t[3] = b[0].to_f
  t[4] = b[1].to_f
  t[5] = b[2].to_f
  t
end

def clamp_i(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

# The band: row j of a 3-tap pass reads j-1, j, j+1 with the ends replicated.
# Positions are exact integers in f32 (W8), so this half of the coefficient
# tensor cannot round.
def band_idx(n)
  a = Array.new(n * 3, 0.0)
  j = 0
  while j < n
    k = 0
    while k < 3
      a[j * 3 + k] = clamp_i(j + k - 1, 0, n - 1).to_f
      k += 1
    end
    j += 1
  end
  a
end

def band_wgt(n, t0, t1, t2)
  a = Array.new(n * 3, 0.0)
  j = 0
  while j < n
    a[j * 3] = t0
    a[j * 3 + 1] = t1
    a[j * 3 + 2] = t2
    j += 1
  end
  a
end

# E039 D5's default quantiser, in Ruby: round half to even, then clamp.  E069
# s8 measured that this rounding CONTRACT, not the precision, is the whole
# difference between a plain f64 Ruby loop and the f32 device kernel.
def round_even_clamp(v)
  return 0 if v <= 0.0
  return 255 if v >= 255.0
  f = v.floor
  d = v - f.to_f
  return f + 1 if d > 0.5
  return f if d < 0.5
  return f if f % 2 == 0
  f + 1
end

device  = ARGV[0]
vmfb    = ARGV[1]
imgpath = ARGV[2]
tappath = ARGV[3]
outdir  = ARGV[4]

dims = pnm_dims(imgpath)
w = dims[0]
h = dims[1]
n = h * w
if n % 4 != 0
  raise TensorError, "#{w}x#{h} = #{n} pixels is not a multiple of 4; metal's " \
                     "u8 destination writes short and silently (R004 W11, E072 s5)"
end
bytes = pnm_data(imgpath, n)
t = read_taps(tappath)

iy = band_idx(h)
wy = band_wgt(h, t[0], t[1], t[2])
ix = band_idx(w)
wx = band_wgt(w, t[3], t[4], t[5])

got = ""
ninvoke = 0
nalloc = 0
nh2d = 0
nd2h_pre = 0
Tensor.device(device, vmfb) do
  c0 = SPT.sp_t_counter(2)
  a0 = SPT.sp_t_counter(3)

  src = Tensor.ten3(:u8, h, w, 1)
  src.store_bytes(bytes)
  tiy = Tensor.of_mat(:f32, h, 3, iy)     # <- the learned coefficients (W6)
  twy = Tensor.of_mat(:f32, h, 3, wy)
  tix = Tensor.of_mat(:f32, w, 3, ix)
  twx = Tensor.of_mat(:f32, w, 3, wx)
  mid = Tensor.ten3(:f32, h, w, 1)
  dst = Tensor.ten3(:u8, h, w, 1)

  tap_y_f32(src, tiy, twy, mid)
  tap_x_u8(mid, tix, twx, dst)

  nh2d = SPT.sp_t_counter(0)
  nd2h_pre = SPT.sp_t_counter(1)
  got = dst.to_bytes
  ninvoke = SPT.sp_t_counter(2) - c0
  nalloc = SPT.sp_t_counter(3) - a0

  src.free!
  tiy.free!
  twy.free!
  tix.free!
  twx.free!
  mid.free!
  dst.free!
  0
end

nd = 0
ties = 0
near = 0
far = 0
maxabs = 0.0
minmargin = 1.0
# Spinel Extended: this block compares the device with another implementation
# (plain Ruby in f64), so it runs only when asked (SPINEL_ORACLE=1); spinel-llvm
# ran it every time. Without it the ndiff rows are not printed.
oracle = ENV["SPINEL_ORACLE"] == "1"
# ---- the f64 oracle: the same two passes, in ordinary Ruby -----------------
if oracle
mid = Array.new(n, 0.0)
y = 0
while y < h
  x = 0
  while x < w
    acc = 0.0
    k = 0
    while k < 3
      yy = clamp_i(y + k - 1, 0, h - 1)
      acc += t[k] * bytes.getbyte(yy * w + x).to_f
      k += 1
    end
    mid[y * w + x] = acc
    x += 1
  end
  y += 1
end

y = 0
while y < h
  x = 0
  while x < w
    acc = 0.0
    k = 0
    while k < 3
      xx = clamp_i(x + k - 1, 0, w - 1)
      acc += t[3 + k] * mid[y * w + xx]
      k += 1
    end
    q = round_even_clamp(acc)
    g = got.getbyte(y * w + x)
    # How far this pixel sits from a rounding boundary.  A difference inside
    # half an f32 ulp of the tie is explained; one outside it is not (E042 s4).
    fr = acc - acc.floor.to_f
    m = (fr - 0.5).abs
    ties += 1 if m < 1.0e-12
    minmargin = m if m < minmargin && acc > 0.0 && acc < 255.0
    if g != q
      nd += 1
      d = (g - q).abs.to_f
      maxabs = d if d > maxabs
      if m < 1.0e-6
        near += 1
      else
        far += 1
      end
    end
    x += 1
  end
  y += 1
end

end

# FNV-1a over the returned bytes: the cross-device identity check.
hsh = 14695981039346656037
i = 0
while i < n
  hsh = ((hsh ^ got.getbyte(i)) * 1099511628211) % 18446744073709551616
  i += 1
end

puts "device\t#{device}"
puts "image\t#{w}x#{h}"
puts "pixels\t#{n}"
puts "ky\t#{t[0]}\t#{t[1]}\t#{t[2]}"
puts "kx\t#{t[3]}\t#{t[4]}\t#{t[5]}"
puts "hash\t#{hsh}"
puts "h2d\t#{nh2d}"
puts "d2h_before_readback\t#{nd2h_pre}"
puts "invoke\t#{ninvoke}"
puts "alloc\t#{nalloc}"
puts "readback_bytes\t#{got.length}"
if oracle
puts "ndiff_vs_f64ref\t#{nd}"
puts "nd_near\t#{near}"
puts "nd_far\t#{far}"
puts "max_abs_diff\t#{maxabs.to_i}"
puts "ties\t#{ties}"
puts "min_margin\t#{minmargin}"
end

if outdir != "-"
  f = File.open("#{outdir}/out_#{device}.pgm", "wb")
  f.write("P5\n#{w} #{h}\n255\n")
  f.write(got)
  f.close
  puts "out\t#{outdir}/out_#{device}.pgm"
end
