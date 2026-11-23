# E076 demo B -- calibrate the gatekeeper's bot score, and bake it back.
#
#   ./calib [pairs] [steps]
#
# examples/gatekeeper is NOT touched by this program.  What is reproduced here
# is its SHAPE (E066 s3): ten predicates over request features, integer points
# per predicate, sum clamped to 0..100, verdict = `score >= threshold`.  The
# ten predicates and the ten shipped weights below are transcribed from
# examples/gatekeeper/kern.rb `bot_score`.
#
# ---- THE SYNTHETIC POPULATION (the generating rule, written down) ---------
#
# There is no traffic log in this repository, so the labels come from a
# generator, and a generator that the scorer can trivially win against would
# prove nothing.  The rule is:
#
#   HUMAN (label 0)
#     hdr_count  8..24
#     ua_len     60..180, except 5% of sessions on an embedded browser with a
#                6..11 byte UA  -- these fire the SAME predicate as a bot
#     gap_ms     400..20000, except 35% mid-page bursts at 30..399 -- these
#                fire the "fast" predicates, which is exactly where the shipped
#                weights are heaviest
#     path_len   5..60      query_len 0..40      POST 20%
#
#   BOT (label 1), three sub-populations in equal thirds
#     scraper    hdr 2..5, ua 0 (half) or 5..11, gap 20..150, path 10..40,
#                query 0..20, POST no
#     stuffer    hdr 10..20, ua 90..140, gap 50..300, path 10..30, query 0..5,
#                POST yes            <- looks human on every static feature
#     crawler    hdr 30..50, ua 200..500, gap 500..2000, path 100..200,
#                query 400..900, POST no
#
# The overlap is deliberate and it is where the shipped weights lose: bursty
# humans collect 25 points for `gap < 120` and 10 for `120 <= gap < 400`, and
# embedded-browser humans collect 20 for a short UA.  Nobody mis-tuned
# anything -- the numbers are perfectly sensible priors, and the data says
# something different.  That is what calibration is for.
#
# Train and test are drawn from the same rule with different seeds, and every
# number below is a test-set number.
require_relative "score_learn_grad.gen"

NF = 10

# --- the deterministic source of the population ----------------------------
# One 31-bit LCG, the same shape examples/gatekeeper uses for its mixing, so
# the whole experiment reproduces from two integers.
$seed = 1

def nxt
  $seed = ($seed * 1103515245 + 12345) % 2147483648
  $seed
end

def rnd(lo, hi)
  lo + nxt % (hi - lo + 1)
end

def pct(p)
  nxt % 100 < p
end

# --- the ten predicates, transcribed from examples/gatekeeper `bot_score` ---
def feats(hdr, ua, gap, path, query, post, out, base)
  out[base + 0] = hdr < 4 ? 1.0 : 0.0
  out[base + 1] = hdr > 40 ? 1.0 : 0.0
  out[base + 2] = ua == 0 ? 1.0 : 0.0
  out[base + 3] = (ua > 0 && ua < 12) ? 1.0 : 0.0
  out[base + 4] = ua > 400 ? 1.0 : 0.0
  out[base + 5] = (gap >= 0 && gap < 120) ? 1.0 : 0.0
  out[base + 6] = (gap >= 120 && gap < 400) ? 1.0 : 0.0
  out[base + 7] = path > 120 ? 1.0 : 0.0
  out[base + 8] = query > 512 ? 1.0 : 0.0
  out[base + 9] = post == 1 ? 1.0 : 0.0
  0
end

def gen_human(out, base)
  hdr = rnd(8, 24)
  ua = pct(5) ? rnd(6, 11) : rnd(60, 180)
  gap = pct(35) ? rnd(30, 399) : rnd(400, 20000)
  path = rnd(5, 60)
  query = rnd(0, 40)
  post = pct(20) ? 1 : 0
  feats(hdr, ua, gap, path, query, post, out, base)
end

def gen_bot(out, base)
  k = nxt % 3
  if k == 0
    hdr = rnd(2, 5)
    ua = pct(50) ? 0 : rnd(5, 11)
    gap = rnd(20, 150)
    path = rnd(10, 40)
    query = rnd(0, 20)
    post = 0
  elsif k == 1
    hdr = rnd(10, 20)
    ua = rnd(90, 140)
    gap = rnd(50, 300)
    path = rnd(10, 30)
    query = rnd(0, 5)
    post = 1
  else
    hdr = rnd(30, 50)
    ua = rnd(200, 500)
    gap = rnd(500, 2000)
    path = rnd(100, 200)
    query = rnd(400, 900)
    post = 0
  end
  feats(hdr, ua, gap, path, query, post, out, base)
end

# --- the INTEGER kernel, in the gatekeeper's own shape ----------------------
# Integer weights, integer sum, clamp, and the verdict is a comparison.  This
# is the thing that ships; nothing about it is differentiable and nothing about
# it needs to be.
def int_score(f, base, iw)
  s = 0
  j = 0
  while j < NF
    s += iw[j] if f[base + j] > 0.5
    j += 1
  end
  s = 100 if s > 100
  s = 0 if s < 0
  s
end

# --- metrics ---------------------------------------------------------------
def evaluate(fb, fh, npair, iw, thr, out)
  tp = 0
  fn = 0
  fp = 0
  tn = 0
  p = 0
  while p < npair
    tp += 1 if int_score(fb, p * NF, iw) >= thr
    fn += 1 if int_score(fb, p * NF, iw) < thr
    fp += 1 if int_score(fh, p * NF, iw) >= thr
    tn += 1 if int_score(fh, p * NF, iw) < thr
    p += 1
  end
  out[0] = tp.to_f
  out[1] = fn.to_f
  out[2] = fp.to_f
  out[3] = tn.to_f
  acc = (tp + tn).to_f / (2 * npair).to_f
  prec = tp + fp > 0 ? tp.to_f / (tp + fp).to_f : 0.0
  rec = tp.to_f / npair.to_f
  f1 = prec + rec > 0.0 ? 2.0 * prec * rec / (prec + rec) : 0.0
  out[4] = acc
  out[5] = prec
  out[6] = rec
  out[7] = f1
  0
end

# The threshold is chosen the way a deployment chooses it: sweep it on the
# TRAINING set and take the best F1.  Doing this for BOTH weight vectors is
# what makes the comparison fair -- otherwise "calibrated" would just mean
# "someone finally tuned the threshold".
def best_threshold(fb, fh, npair, iw, m)
  best = 1
  bestf = -1.0
  t = 1
  while t <= 100
    evaluate(fb, fh, npair, iw, t, m)
    if m[7] > bestf
      bestf = m[7]
      best = t
    end
    t += 1
  end
  best
end

npair = ARGV[0] ? ARGV[0].to_i : 2000
steps = ARGV[1] ? ARGV[1].to_i : 3000
lam   = 0.02

grad_check_signatures!

# --- data ------------------------------------------------------------------
$seed = 12345
trb = Array.new(npair * NF, 0.0)
trh = Array.new(npair * NF, 0.0)
p = 0
while p < npair
  gen_bot(trb, p * NF)
  gen_human(trh, p * NF)
  p += 1
end
$seed = 99991
teb = Array.new(npair * NF, 0.0)
teh = Array.new(npair * NF, 0.0)
p = 0
while p < npair
  gen_bot(teb, p * NF)
  gen_human(teh, p * NF)
  p += 1
end

# --- the shipped weights (examples/gatekeeper/kern.rb `bot_score`) ----------
shipped = [25, 15, 30, 20, 10, 25, 10, 10, 15, 5]

# --- learn -----------------------------------------------------------------
# Start FROM the shipped weights, scaled into the f64 twin's units.  Starting
# from zero would learn the same thing; starting from the shipped vector makes
# the descent's job "improve what is deployed", which is the actual task.
w = Array.new(NF, 0.0)
dw = Array.new(NF, 0.0)
j = 0
while j < NF
  w[j] = shipped[j].to_f / 10.0
  j += 1
end

l0 = grad_rank_loss(w, trb, trh, npair, NF, lam, dw)
puts "pairs\t#{npair}"
puts "lambda\t#{lam}"
puts "loss0\t#{l0 / npair.to_f}"

lr = 0.1
step = 0
while step < steps
  loss = grad_rank_loss(w, trb, trh, npair, NF, lam, dw)
  t = lr
  moved = false
  tries = 0
  while tries < 40
    nw = Array.new(NF, 0.0)
    j = 0
    while j < NF
      nw[j] = w[j] - t * dw[j]
      j += 1
    end
    nl = gdval_rank_loss(nw, trb, trh, npair, NF, lam)
    if nl < loss
      j = 0
      while j < NF
        w[j] = nw[j]
        j += 1
      end
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
lf = gdval_rank_loss(w, trb, trh, npair, NF, lam)
puts "steps_taken\t#{step}"
puts "loss_final\t#{lf / npair.to_f}"

# --- integerise ------------------------------------------------------------
# The kernel's points are integers, so the settled f64 weights have to be
# quantised.  The scale is chosen so the largest magnitude lands on 30, which
# is the largest point value the shipped table uses -- i.e. the calibrated
# kernel stays in the same numeric range as the one it replaces, and the
# clamp at 100 keeps meaning the same thing.
mx = 0.0
j = 0
while j < NF
  a = w[j].abs
  mx = a if a > mx
  j += 1
end
scale = mx > 0.0 ? 30.0 / mx : 1.0
calib = Array.new(NF, 0)
j = 0
while j < NF
  v = w[j] * scale
  calib[j] = (v + (v >= 0.0 ? 0.5 : -0.5)).to_i
  j += 1
end

# --- evaluate --------------------------------------------------------------
m = Array.new(8, 0.0)
ts = best_threshold(trb, trh, npair, shipped, m)
tc = best_threshold(trb, trh, npair, calib, m)

names = ["hdr<4", "hdr>40", "ua==0", "0<ua<12", "ua>400",
         "gap<120", "120<=gap<400", "path>120", "query>512", "POST"]
puts "feature\tshipped\tcalibrated\tlearned_f64"
j = 0
while j < NF
  puts "#{names[j]}\t#{shipped[j]}\t#{calib[j]}\t#{w[j]}"
  j += 1
end

puts "scale\t#{scale}"
puts "threshold_shipped\t#{ts}"
puts "threshold_calibrated\t#{tc}"
puts "set\tweights\tthr\ttp\tfn\tfp\ttn\taccuracy\tprecision\trecall\tf1"
evaluate(trb, trh, npair, shipped, ts, m)
puts "train\tshipped\t#{ts}\t#{m[0].to_i}\t#{m[1].to_i}\t#{m[2].to_i}\t#{m[3].to_i}\t#{m[4]}\t#{m[5]}\t#{m[6]}\t#{m[7]}"
evaluate(trb, trh, npair, calib, tc, m)
puts "train\tcalibrated\t#{tc}\t#{m[0].to_i}\t#{m[1].to_i}\t#{m[2].to_i}\t#{m[3].to_i}\t#{m[4]}\t#{m[5]}\t#{m[6]}\t#{m[7]}"
evaluate(teb, teh, npair, shipped, ts, m)
sacc = m[4]
sf1 = m[7]
puts "test\tshipped\t#{ts}\t#{m[0].to_i}\t#{m[1].to_i}\t#{m[2].to_i}\t#{m[3].to_i}\t#{m[4]}\t#{m[5]}\t#{m[6]}\t#{m[7]}"
evaluate(teb, teh, npair, calib, tc, m)
puts "test\tcalibrated\t#{tc}\t#{m[0].to_i}\t#{m[1].to_i}\t#{m[2].to_i}\t#{m[3].to_i}\t#{m[4]}\t#{m[5]}\t#{m[6]}\t#{m[7]}"
puts "test_accuracy_delta\t#{m[4] - sacc}"
puts "test_f1_delta\t#{m[7] - sf1}"

# --- the pairwise question the loss actually optimised ----------------------
ps = 0
pc = 0
p = 0
while p < npair
  ps += 1 if int_score(teb, p * NF, shipped) > int_score(teh, p * NF, shipped)
  pc += 1 if int_score(teb, p * NF, calib) > int_score(teh, p * NF, calib)
  p += 1
end
puts "test_pairwise_shipped\t#{ps.to_f / npair.to_f}"
puts "test_pairwise_calibrated\t#{pc.to_f / npair.to_f}"
