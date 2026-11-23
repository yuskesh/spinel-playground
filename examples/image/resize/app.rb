# examples/image/resize -- the host world. Ordinary Ruby.
#
#   app <device> <vmfb> <oh> <ow> <outdir|-> <in.pgm> [in2.pgm ...]
#     device: local-sync | local-task | metal
#
# Shrinks 4K with 2 one-line declarations. The GPU's name appears only in the device argument.
require_relative "spinel/tensor"
require_relative "kernels.gen"

# Scaffolding for checking (ref.c). Not part of the surface.
module SPX
  ffi_func :sp_img_taps,      [:int, :int, :float_array, :float_array],       :void
  ffi_func :sp_img_ref,       [:int, :str, :int, :int, :int, :int,
                               :float_array],                                 :void
  ffi_func :sp_img_ties,      [:float_array, :float_array, :size_t],          :void
  ffi_func :sp_img_enumerate, [:str, :float_array, :float_array, :float_array,
                               :float_array, :size_t],                        :void
  ffi_func :sp_img_diff_where, [:str, :float_array, :float_array, :size_t],   :void
  ffi_func :sp_img_wdiff,     [:float_array, :float_array, :size_t],          :int64
  ffi_func :sp_img_partition, [:float_array, :int],                           :double
  ffi_func :sp_img_hash_str,  [:str, :size_t],                                :int64
  ffi_func :sp_img_write_pgm, [:str, :str, :int, :int],                       :void
end

# ---- the PNM subset (P5 / a 3-line header / no comments / maxval 255) ------------
def pnm_dims(path)
  f = File.open(path, "rb")
  magic = f.gets.chomp
  if magic != "P5"
    raise TensorError, "#{path}: magic is #{magic}. This reader accepts only P5"
  end
  dims = f.gets.chomp.split(" ")
  if dims.length != 2
    raise TensorError, "#{path}: line 2 must be `<w> <h>`"
  end
  maxv = f.gets.chomp.to_i
  f.close
  if maxv != 255
    raise TensorError, "#{path}: maxval #{maxv} -- this reader is 8-bit only"
  end
  a = Array.new(2, 0)
  a[0] = dims[0].to_i
  a[1] = dims[1].to_i
  a
end

def pnm_data(path, n)
  f = File.open(path, "rb")
  f.gets
  f.gets
  f.gets
  d = f.read(n)
  f.close
  if d.length != n
    raise TensorError, "#{path}: #{d.length} bytes of pixels, #{n} expected"
  end
  d
end

# The host makes the coefficients. All of the coefficient handling fits in these dozen lines of ordinary Ruby.
#
# `idx` is the K tap **positions** and `wgt` the K **weights**, both (nout, K)
# row-major. Here K = 2 (bilinear).
#
# The arithmetic is f64 because Ruby has only one float type, but **that is the point**,
# not an accident: written inside the kernel, the same expression would be f32, and getting
# the scale needs an `arith.divf` of 2 run-time dimensions, which Metal does not round
# correctly (measured). Built here and uploaded,
# it is **rounded only once**.
def tap_idx(nin, nout)
  a = Array.new(nout * 2, 0.0)
  lim = (nin - 1).to_f
  j = 0
  while j < nout
    s = (j.to_f + 0.5) * nin.to_f / nout.to_f - 0.5
    s = 0.0 if s < 0.0
    s = lim if s > lim
    i0 = s.floor.to_i
    i1 = i0 + 1
    i1 = nin - 1 if i1 > nin - 1
    a[j * 2] = i0.to_f          # a position is an integer f32 holds exactly
    a[j * 2 + 1] = i1.to_f
    j += 1
  end
  a
end

def tap_wgt(nin, nout)
  a = Array.new(nout * 2, 0.0)
  lim = (nin - 1).to_f
  j = 0
  while j < nout
    s = (j.to_f + 0.5) * nin.to_f / nout.to_f - 0.5
    s = 0.0 if s < 0.0
    s = lim if s > lim
    i0 = s.floor.to_i
    d = s - i0.to_f
    a[j * 2] = 1.0 - d
    a[j * 2 + 1] = d
    j += 1
  end
  a
end

device = ARGV[0]
vmfb   = ARGV[1]
oh     = ARGV[2].to_i
ow     = ARGV[3].to_i
outdir = ARGV[4]

# Say on the host side too what covers a defect in IREE found earlier: metal-spirv
# **quietly writes short** when a :u8 destination's element count is not a multiple of 4,
# so the shim refuses it loudly. Resampling is the first operation that makes any output
# size, so being caught here is part of the specification, not an accident.
n = oh * ow
if n % 4 != 0
  raise TensorError, "output #{ow}x#{oh} = #{n} pixels is not a multiple of 4. " \
                     "On metal the shim refuses it (R004 decision record W11, E072 §5)"
end

# The oracle columns compare the device's image with ref.c's three reference
# reductions and the host weights with an independent C construction -- a
# second implementation. In this repository they run only when asked
# (SPINEL_ORACLE=1); without it each row reports what the device run itself
# established.
ORACLE = ENV["SPINEL_ORACLE"] == "1"
if ORACLE
  puts "image\tdevice\tin\tout\thash\tnd_plain\tm_plain\tm_fma1\tm_fma2\t" \
       "unexplained\tties\ttie_pct\tsplit\tmin_margin\tnd_at_tie\tnd_near\t" \
       "nd_far\tw_inexact\tw_n\tpartition\th2d\td2h_pre\tinvoke\talloc"
else
  puts "image\tdevice\tin\tout\thash\th2d\td2h_pre\tinvoke\talloc\treadback_bytes"
end

k = 5
while k < ARGV.length
  path = ARGV[k]
  dims = pnm_dims(path)
  w = dims[0]
  h = dims[1]
  bytes = pnm_data(path, w * h)
  stem = path.split("/")[-1].split(".")[0]

  iy = tap_idx(h, oh)
  wy = tap_wgt(h, oh)
  ix = tap_idx(w, ow)
  wx = tap_wgt(w, ow)

  got     = ""
  ninvoke = 0
  nalloc  = 0
  nh2d    = 0
  nd2h    = 0
  Tensor.device(device, vmfb) do
    c0 = SPT.sp_t_counter(2)
    a0 = SPT.sp_t_counter(3)

    src = Tensor.ten3(:u8, h, w, 1)
    src.store_bytes(bytes)
    tiy = Tensor.of_mat(:f32, oh, 2, iy)   # the coefficients travel as tensors
    twy = Tensor.of_mat(:f32, oh, 2, wy)
    tix = Tensor.of_mat(:f32, ow, 2, ix)
    twx = Tensor.of_mat(:f32, ow, 2, wx)
    tmp = Tensor.ten3(:f32, oh, w, 1)      # the intermediate stays resident as f32
    dst = Tensor.ten3(:u8, oh, ow, 1)

    tap_y_f32(src, tiy, twy, tmp)
    tap_x_u8(tmp, tix, twx, dst)

    nh2d = SPT.sp_t_counter(0)
    nd2h = SPT.sp_t_counter(1)
    got = dst.to_bytes                     # the only d2h
    ninvoke = SPT.sp_t_counter(2) - c0
    nalloc  = SPT.sp_t_counter(3) - a0

    src.free!
    tiy.free!
    twy.free!
    tix.free!
    twx.free!
    tmp.free!
    dst.free!
    0
  end

  unless ORACLE
    puts "#{stem}\t#{device}\t#{w}x#{h}\t#{ow}x#{oh}\t#{SPX.sp_img_hash_str(got, n)}\t" \
         "#{nh2d}\t#{nd2h}\t#{ninvoke}\t#{nalloc}\t#{got.length}"
  end
  if ORACLE
  # --- 3 references (the 3 ways of contracting). Turns "it differed" into "it contracted here" ---
  r0 = Array.new(n, 0.0)
  r1 = Array.new(n, 0.0)
  r2 = Array.new(n, 0.0)
  SPX.sp_img_ref(0, bytes, h, w, oh, ow, r0)
  SPX.sp_img_ref(1, bytes, h, w, oh, ow, r1)
  SPX.sp_img_ref(2, bytes, h, w, oh, ow, r2)

  en = Array.new(8, 0.0)
  SPX.sp_img_enumerate(got, r0, r1, r2, en, n)
  tie = Array.new(8, 0.0)
  SPX.sp_img_ties(r0, tie, n)
  dw = Array.new(4, 0.0)
  SPX.sp_img_diff_where(got, r0, dw, n)

  # Check the host's weight construction against an independent C implementation (2 implementations of one formula).
  # The positions are exact integers in both, so this **must be 0**.
  cix = Array.new(ow * 2, 0.0)
  cwx = Array.new(ow * 2, 0.0)
  SPX.sp_img_taps(w, ow, cix, cwx)
  if SPX.sp_img_wdiff(ix, cix, ow * 2) != 0
    raise TensorError, "the tap positions disagree between Ruby and C (#{w} -> #{ow})"
  end
  # The weights can move when rounded to f32. **Whether the number that moved is 0 is
  # exactly whether this shrink is dyadic.**
  winex = SPX.sp_img_wdiff(wx, cwx, ow * 2)
  part = SPX.sp_img_partition(wx, ow)

  pct = tie[0] * 100.0 / n.to_f
  line = "#{stem}\t#{device}\t#{w}x#{h}\t#{ow}x#{oh}\t"
  line += "#{SPX.sp_img_hash_str(got, n)}\t"
  line += "#{en[0].to_i}\t#{en[1].to_i}\t#{en[2].to_i}\t#{en[3].to_i}\t#{en[4].to_i}\t"
  line += "#{tie[0].to_i}\t"
  line += sprintf("%.3f", pct)
  line += "\t#{tie[1].to_i}\t"
  line += sprintf("%g", tie[2])
  line += "\t#{dw[1].to_i}\t#{dw[2].to_i}\t#{dw[3].to_i}\t"
  line += "#{winex}\t#{ow * 2}\t"
  line += sprintf("%g", part)
  line += "\t#{nh2d}\t#{nd2h}\t#{ninvoke}\t#{nalloc}"
  puts line
  end

  unless outdir == "-"
    SPX.sp_img_write_pgm("#{outdir}/#{stem}_#{ow}x#{oh}_#{device}.pgm",
                         got, oh, ow)
  end
  k += 1
end
