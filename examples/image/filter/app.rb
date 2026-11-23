# examples/image/filter -- the host world. Ordinary Ruby.
#
#   app <device> <vmfb> <in.pgm> <tail> [param] [out.pgm]
#     device: local-sync | local-task | metal
#     tail  : thr (the default, a threshold) | gain (a gain = the side that tests the quantizer)
#
# The one sentence that set this work's goal is written here:
#
#   "A single-file Ruby binary filters a 4K image on the M1's GPU, and its
#     output rounded to u8 matches the reference implementation pixel for pixel."
#
# The GPU's name appears only in the device argument; everything else is Tensor
# and calls to `blur_f32` / `sobel_f32` / `thresh_u8` / `gain_u8`, generated from
# kernels.rb.
require_relative "spinel/tensor"
require_relative "kernels.gen"

# Scaffolding for checking (ref.c). Not part of the surface: this program declares it itself.
module SPX
  ffi_func :sp_img_ref,       [:int, :double, :str, :int, :int, :float_array], :void
  ffi_func :sp_img_quant,     [:int, :float_array, :float_array, :size_t],     :void
  ffi_func :sp_img_ties,      [:float_array, :float_array, :size_t],           :void
  ffi_func :sp_img_thr_ties,  [:float_array, :double, :float_array, :size_t],  :void
  ffi_func :sp_img_diff_where, [:str, :float_array, :float_array, :size_t],    :void
  ffi_func :sp_img_diff_where_thr,
           [:str, :float_array, :float_array, :double, :float_array, :size_t], :void
  ffi_func :sp_img_hash_str,  [:str, :size_t],                                 :int64
  ffi_func :sp_img_hash_q,    [:float_array, :size_t],                         :int64
  ffi_func :sp_img_write_pgm, [:str, :str, :int, :int],                        :void
end

device = ARGV[0]
vmfb   = ARGV[1]
path   = ARGV[2]
tail   = ARGV[3].nil? ? "thr" : ARGV[3]
param  = ARGV[4].nil? ? (tail == "thr" ? 50.0 : 0.25) : ARGV[4].to_f
outp   = ARGV[5]

# ---- the PNM subset, written out loud as it is ----------------------------------
# P5 (grey), a 3-line header, no comments, maxval 255. A form it cannot read raises.
# stb_image was deliberately not brought in.
f = File.open(path, "rb")
magic = f.gets.chomp
if magic != "P5"
  raise TensorError, "#{path}: magic is #{magic}. This reader accepts only P5 (3-line header, " \
                     "no comments, maxval 255)"
end
dims = f.gets.chomp.split(" ")
if dims.length != 2
  raise TensorError, "#{path}: line 2 must be `<w> <h>`"
end
w = dims[0].to_i
h = dims[1].to_i
maxv = f.gets.chomp.to_i
if maxv != 255
  raise TensorError, "#{path}: maxval #{maxv} -- this reader is 8-bit only"
end
bytes = f.read(w * h)
f.close
if bytes.length != w * h
  raise TensorError, "#{path}: #{bytes.length} bytes of pixels, #{w * h} expected"
end

n = h * w

# --- the device scope. A Tensor can live only inside it -------------------------
got     = ""
ninvoke = 0
nalloc  = 0
nh2d    = 0
nd2h    = 0
Tensor.device(device, vmfb) do
  c0 = SPT.sp_t_counter(2)
  a0 = SPT.sp_t_counter(3)

  src = Tensor.ten3(:u8, h, w, 1)
  src.store_bytes(bytes)          # bytes go up as bytes
  mid = Tensor.ten3(:f32, h, w, 1)
  grd = Tensor.ten3(:f32, h, w, 1)
  dst = Tensor.ten3(:u8, h, w, 1)

  # 3 stages. The intermediates (mid / grd) stay resident on the device as f32
  #    and never cross the host boundary, not one byte.
  blur_f32(src, mid)
  sobel_f32(mid, grd)
  if tail == "thr"
    thresh_u8(param, grd, dst)
  else
    gain_u8(param, grd, dst)
  end

  # Count the transfers before the readback. d2h being 0 here is what
  # "the intermediates stayed resident" means.
  nh2d = SPT.sp_t_counter(0)
  nd2h = SPT.sp_t_counter(1)

  # The only d2h. `to_bytes` returns a u8 tensor as a String as it is
  #   (measured at 4K: 24.94 ms -> 0.74 ms).
  got = dst.to_bytes

  ninvoke = SPT.sp_t_counter(2) - c0
  nalloc  = SPT.sp_t_counter(3) - a0
  src.free!
  mid.free!
  grd.free!
  dst.free!
  0
end

puts "device\t#{device}"
puts "image\t#{path.split("/")[-1]}"
puts "shape\t#{w}x#{h}"
puts "pixels\t#{n}"
puts "tail\t#{tail}"
printf("param\t%g\n", param)
puts "h2d\t#{nh2d}"
puts "d2h_before_readback\t#{nd2h}"
puts "invoke\t#{ninvoke}"
puts "alloc\t#{nalloc}"
puts "readback_bytes\t#{got.length}"
printf("hash\t%d\n", SPX.sp_img_hash_str(got, n))

# --- the oracle: ref.c is a second, f32 implementation of the same filter, and
# everything from here to the last printf compares with it. In this repository
# it runs only when asked (SPINEL_ORACLE=1); spinel-llvm ran it every time.
if ENV["SPINEL_ORACLE"] == "1"
# --- the reference implementation (f32, -ffp-contract=off): the answer with no device ---
kind = tail == "thr" ? 1 : 0
ref  = Array.new(n, 0.0)
SPX.sp_img_ref(kind, param, bytes, h, w, ref)

# The distribution of f32 values before quantization (the lower layer of the two-layer oracle)
tie = Array.new(8, 0.0)
SPX.sp_img_ties(ref, tie, n)

# The columns that show "the differences can be explained". With the threshold tail, what
# decides the byte is **the value before the threshold**, so the tie question and the attribution of differences move there.
thr = Array.new(4, 0.0)
dw  = Array.new(4, 0.0)
if tail == "thr"
  pre = Array.new(n, 0.0)
  SPX.sp_img_ref(2, 0.0, bytes, h, w, pre)
  SPX.sp_img_thr_ties(pre, param, thr, n)
  SPX.sp_img_diff_where_thr(got, ref, pre, param, dw, n)
else
  SPX.sp_img_thr_ties(ref, param, thr, n)
  SPX.sp_img_diff_where(got, ref, dw, n)
end

printf("ref_hash\t%d\n", SPX.sp_img_hash_q(ref, n))
printf("ndiff_vs_f32ref\t%d\n", dw[0].to_i)
printf("nd_at_tie\t%d\n", dw[1].to_i)
printf("nd_near\t%d\n", dw[2].to_i)
printf("nd_far\t%d\n", dw[3].to_i)
printf("ties\t%d\n", tie[0].to_i)
printf("quant_split_half_up\t%d\n", tie[1].to_i)
printf("min_margin\t%.17g\n", tie[2])
printf("sat_hi\t%d\n", tie[3].to_i)
printf("sat_lo\t%d\n", tie[4].to_i)
printf("thr_ties\t%d\n", thr[0].to_i)
printf("thr_near_1ulp\t%d\n", thr[1].to_i)
printf("thr_above\t%d\n", thr[2].to_i)
end

unless outp.nil?
  SPX.sp_img_write_pgm(outp, got, h, w)
  puts "out\t#{outp}"
end
