# examples/tensor/mnist -- a single binary that classifies MNIST. The host world is ordinary Ruby.
#
#   app <device> <mlp.vmfb> <scale.vmfb> <images-idx3> <labels-idx1> [n] [batch]
#     device: local-sync | local-task | metal
#
# 2 modules are loaded in **the same session**:
#
#   File#read → :i8 Tensor ─ mnist_scale ─→ f32[b,784] ─ mnist_mlp ─→ f32[b,10]
#                                                                       └ argmax
#
# The pixels go from File#read into an :i8 Tensor **as they are**. No unpack, and no
# per-pixel Ruby multiplication: the scaling is on the model's side.
#
# Origin: the predecessor's experiment program (e037_mnist.rb), keeping only the "two" route.
# Ruby reads the files itself, including how IDX is read.
require_relative "spinel/tensor"
require_relative "model.gen"

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

T_START = now

def read_be32(f)
  b = f.read(4).unpack("C*")
  b[0].to_i * 16777216 + b[1].to_i * 65536 + b[2].to_i * 256 + b[3].to_i
end

def die(msg)
  $stderr.puts "mnist: #{msg}"
  exit 1
end

if ARGV.length < 5
  die "usage: app <device> <mlp.vmfb> <scale.vmfb> <images> <labels> [n] [batch]"
end
device = ARGV[0]
vmfb   = ARGV[1]
vmfb2  = ARGV[2]
imgp   = ARGV[3]
lblp   = ARGV[4]
ntest  = ARGV.length > 5 ? ARGV[5].to_i : 10000
batch  = ARGV.length > 6 ? ARGV[6].to_i : 100

die "batch must be >= 1" if batch < 1

# --- the IDX header (big-endian) ---------------------------------------------------
lf = File.open(lblp, "rb")
lmagic = read_be32(lf)
die "#{lblp}: IDX magic #{lmagic}, expected 2049" if lmagic != 2049
nlabel = read_be32(lf)
die "#{lblp}: only #{nlabel} labels, asked for #{ntest}" if ntest > nlabel
labels = lf.read(ntest).unpack("C*")
lf.close

imf = File.open(imgp, "rb")
imagic = read_be32(imf)
die "#{imgp}: IDX magic #{imagic}, expected 2051" if imagic != 2051
nimage = read_be32(imf)
rows   = read_be32(imf)
cols   = read_be32(imf)
die "#{imgp}: only #{nimage} images, asked for #{ntest}" if ntest > nimage
pix = rows * cols
die "#{imgp}: #{rows}x#{cols} pixels, the model wants 28x28" if pix != 784

correct = 0
t_read = 0.0
t_h2d = 0.0
t_invoke = 0.0
t_d2h = 0.0
nbatch = 0

t_pre = now
Tensor.device(device, vmfb) do
  # Add the second module to the same session. The table already knows both
  # entries, and each dispatch finds its own by its fully qualified name in the .vmfb.
  Tensor.append(vmfb2)
  t_open = now - t_pre

  x   = Tensor.mat(:i8, batch, pix)     # raw bytes
  mid = Tensor.mat(:f32, batch, pix)    # scale's output = mlp's input
  y   = Tensor.mat(:f32, batch, 10)     # logits
  done = 0
  while done < ntest
    m = ntest - done < batch ? ntest - done : batch
    if m != batch
      # A partial batch. The shape changes, so remake them (the same .vmfb takes it: dynamic shapes)
      x.free!
      mid.free!
      y.free!
      x   = Tensor.mat(:i8, m, pix)
      mid = Tensor.mat(:f32, m, pix)
      y   = Tensor.mat(:f32, m, 10)
    end

    t0 = now
    raw = imf.read(m * pix)
    t1 = now
    x.store_bytes(raw)
    t2 = now
    mnist_scale(x, mid)                 # module 1
    mnist_mlp(mid, y)                   # module 2
    t3 = now
    lg = y.to_f32_a                     # the only d2h
    t4 = now

    i = 0
    while i < m
      base = i * 10
      best = 0
      bv = lg[base]
      k = 1
      while k < 10
        v = lg[base + k]
        if v > bv
          bv = v
          best = k
        end
        k += 1
      end
      correct += 1 if best == labels[done + i]
      i += 1
    end

    t_read += t1 - t0
    t_h2d += t2 - t1
    t_invoke += t3 - t2
    t_d2h += t4 - t3
    nbatch += 1
    done += m
  end
  x.free!
  mid.free!
  y.free!
  printf("ms_open\t%.3f\n", t_open * 1000.0)
  0
end
t_total = now - T_START
imf.close

puts "device\t#{device}"
puts "n\t#{ntest}"
puts "batch\t#{batch}"
puts "batches\t#{nbatch}"
puts "correct\t#{correct}"
puts "accuracy\t#{correct.to_f / ntest.to_f}"
printf("ms_total_process\t%.3f\n", t_total * 1000.0)
printf("ms_read\t%.3f\n", t_read * 1000.0)
printf("ms_store\t%.3f\n", t_h2d * 1000.0)
printf("ms_invoke\t%.3f\n", t_invoke * 1000.0)
printf("ms_readback\t%.3f\n", t_d2h * 1000.0)
