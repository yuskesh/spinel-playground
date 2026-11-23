# E076 demo A, phase 1 (CPU) -- learn the window from (input, wanted output).
#
# An ordinary Spinel program.  The only thing it knows about automatic
# differentiation is the `require_relative` below: `grad_blur_loss` is a plain
# method that returns the loss and fills two Arrays with the derivative.  The
# derivative was synthesised by Enzyme from the LLVM IR of `blur_loss` in
# filter_learn.rb -- the same emission this program's own copy came from.
#
#   ./train <img.pgm> <out.txt> [steps]
#
# WHAT IS BEING RECOVERED.  `tgt` is built here by applying the KNOWN answer
# (the 1/16 gaussian, separably: [1,2,1]/4 vertical then [1,2,1]/4 horizontal,
# replicate border) to the image.  The descent starts from a box filter, which
# is a different window with the same sum, and has to find its way back.  The
# recovered numbers are then compared against the truth, which is what makes
# "it learned" a measurement instead of a claim.
#
# THE SCALE DEGREE OF FREEDOM IS REAL AND IS REPORTED.  (ky*c, kx/c) is the
# same filter for any c, so the identifiable object is the 3x3 OUTER PRODUCT.
# The taps are recovered uniquely only after fixing the gauge; this program
# fixes it by normalising ky to sum 1 and folding the scale into kx, then
# reports both the taps and the nine window entries.
require_relative "filter_learn_grad.gen"

def clamp_i(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

# The reference filter, in ordinary f64 Ruby.  This is the "wanted output"
# generator AND (in phase 2) the oracle the GPU is checked against, so it is
# written once and used twice.
def sep_filter(src, ky, kx, h, w, dst)
  y = 0
  while y < h
    x = 0
    while x < w
      acc = 0.0
      j = 0
      while j < 3
        yy = clamp_i(y + j - 1, 0, h - 1)
        row = 0.0
        i = 0
        while i < 3
          xx = clamp_i(x + i - 1, 0, w - 1)
          row += kx[i] * src[yy * w + xx]
          i += 1
        end
        acc += ky[j] * row
        j += 1
      end
      dst[y * w + x] = acc
      x += 1
    end
    y += 1
  end
  dst
end

# The P5 subset E039 fixed: magic / dims / maxval, no comments, 8 bit.
def pnm_dims(path)
  f = File.open(path, "rb")
  raise "#{path}: not P5" if f.gets.chomp != "P5"
  d = f.gets.chomp.split(" ")
  raise "#{path}: maxval must be 255" if f.gets.chomp.to_i != 255
  f.close
  a = Array.new(2, 0)
  a[0] = d[0].to_i
  a[1] = d[1].to_i
  a
end

# Pixels as f64 in [0,1].  Normalising here (rather than carrying 0..255) is a
# numerical choice with one consequence worth stating: the loss and therefore
# the gradient are scaled by 1/255^2, which only moves the step size.
def pnm_floats(path, n)
  f = File.open(path, "rb")
  f.gets
  f.gets
  f.gets
  d = f.read(n)
  f.close
  raise "#{path}: short read" if d.length != n
  a = Array.new(n, 0.0)
  i = 0
  while i < n
    a[i] = d.getbyte(i).to_f / 255.0
    i += 1
  end
  a
end

img   = ARGV[0]
outp  = ARGV[1]
steps = ARGV[2] ? ARGV[2].to_i : 400

grad_check_signatures!

dims = pnm_dims(img)
w = dims[0]
h = dims[1]
n = h * w
src = pnm_floats(img, n)

# ---- the ground truth: the 1/16 gaussian, separably -----------------------
tky = [0.25, 0.5, 0.25]
tkx = [0.25, 0.5, 0.25]
tgt = Array.new(n, 0.0)
sep_filter(src, tky, tkx, h, w, tgt)

# ---- the starting point: a box filter -------------------------------------
third = 1.0 / 3.0
ky = [third, third, third]
kx = [third, third, third]
dky = Array.new(3, 0.0)
dkx = Array.new(3, 0.0)

l0 = grad_blur_loss(ky, kx, src, tgt, h, w, dky, dkx)
puts "pixels\t#{n}"
puts "steps\t#{steps}"
puts "loss0\t#{l0 / n.to_f}"

# A backtracking step, not an optimiser library: halve until the loss actually
# goes down.  P007's "things we do not do" list starts with re-inventing the
# training framework -- what is being demonstrated is that the GRADIENT is
# right and useful, and eleven lines of descent is enough to show that.
lr = 1.0
step = 0
loss = l0
while step < steps
  loss = grad_blur_loss(ky, kx, src, tgt, h, w, dky, dkx)
  t = lr
  moved = false
  tries = 0
  while tries < 40
    nky = Array.new(3, 0.0)
    nkx = Array.new(3, 0.0)
    i = 0
    while i < 3
      nky[i] = ky[i] - t * dky[i]
      nkx[i] = kx[i] - t * dkx[i]
      i += 1
    end
    nl = gdval_blur_loss(nky, nkx, src, tgt, h, w)
    if nl < loss
      i = 0
      while i < 3
        ky[i] = nky[i]
        kx[i] = nkx[i]
        i += 1
      end
      loss = nl
      lr = t * 2.0
      moved = true
      tries = 40
    else
      t = t * 0.5
      tries += 1
    end
  end
  break if !moved
  step += 1
end

# ---- fix the gauge: normalise ky to sum 1, fold the scale into kx ----------
sy = ky[0] + ky[1] + ky[2]
i = 0
while i < 3
  ky[i] = ky[i] / sy
  kx[i] = kx[i] * sy
  i += 1
end

lf = gdval_blur_loss(ky, kx, src, tgt, h, w)
puts "steps_taken\t#{step}"
puts "loss_final\t#{lf / n.to_f}"

worst_tap = 0.0
i = 0
while i < 3
  a = (ky[i] - tky[i]).abs
  worst_tap = a if a > worst_tap
  a = (kx[i] - tkx[i]).abs
  worst_tap = a if a > worst_tap
  i += 1
end
worst_win = 0.0
j = 0
while j < 3
  i = 0
  while i < 3
    a = (ky[j] * kx[i] - tky[j] * tkx[i]).abs
    worst_win = a if a > worst_win
    i += 1
  end
  j += 1
end

puts "ky\t#{ky[0]}\t#{ky[1]}\t#{ky[2]}"
puts "kx\t#{kx[0]}\t#{kx[1]}\t#{kx[2]}"
puts "ky_true\t#{tky[0]}\t#{tky[1]}\t#{tky[2]}"
puts "kx_true\t#{tkx[0]}\t#{tkx[1]}\t#{tkx[2]}"
puts "worst_tap_abs_err\t#{worst_tap}"
puts "worst_window_abs_err\t#{worst_win}"

f = File.open(outp, "w")
f.puts "#{ky[0]} #{ky[1]} #{ky[2]}"
f.puts "#{kx[0]} #{kx[1]} #{kx[2]}"
f.close
puts "wrote\t#{outp}"
