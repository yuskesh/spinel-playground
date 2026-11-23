# E016 -- stress-mode canary for R2 (batching) and the case E015 argued about
# but never tested: a longjmp landing in / unwinding through a frame whose
# roots were rewritten into a batch.
#
# safety_analysis.md §3 argues the hazard cannot happen, because the unwinder
# OVERWRITES sp_gc_nroots with the watermark taken at the protected region's
# entry (sp_exc_rootmark[sp_exc_top]) rather than decrementing it, so a partial
# batch is never observed.  Note that batchFunction has NO setjmp guard -- the
# elision path bails out of a returns_twice function, batching does not -- so a
# batched region inside a rescue frame is a shape that really is produced.
#
# Verified on the pass build: `sp_outer` contains both `call @setjmp` and
# `sp.batch.fast` / `sp.batch.slow` blocks, i.e. the raise really does land in a
# frame with a batched root region, and `sp_worker` raises out of another one.
#
#   pass, opt -passes=spinel-gc-roots:  batched 7 roots in 2 batches
#   sp_outer: 1 setjmp, 3 sp.batch.fast   <- longjmp lands in a batched frame
#
# 20000 iterations, one raise in three, is ~6700 longjmps across a batch and
# ~160000 batched root pushes -- well above SP_GC_STACK_MAX (65536).  If the
# batch fast path leaked even one slot per unwind, the shadow stack would
# overflow, _sp_gc_root_push would start silently returning 0 (sp_gc.h:85-87),
# and the run would diverge or crash.  Under SPINEL_GC_STRESS=1 every
# allocation is also a collection, so every unrooted window is exercised.
#
# The .expected value is CRuby's own output for this program, not a snapshot of
# what Spinel prints, so it is an oracle rather than a tautology.

class Holder
  def initialize(t)
    @t = t
  end

  def t
    @t
  end
end

# Four locals rooted back to back at function entry = one batch, and a raise
# out of the middle of the frame.
def worker(i)
  a = "w#{i}"
  b = "x#{i}"
  c = Holder.new(i)
  d = [i, i + 1]
  if i % 3 == 0
    raise "boom"
  end
  a.length + b.length + c.t + d.length
end

# Same batch shape, plus the setjmp: the longjmp from `worker` lands HERE,
# after this frame's batch has already run.
def outer(i)
  p = "p#{i}"
  q = "q#{i}"
  r = Holder.new(i)
  s = [i]
  n = 0
  begin
    n = worker(i)
  rescue => e
    n = e.message.length
  end
  n + p.length + q.length + r.t + s.length
end

def run
  t = 0
  i = 0
  while i < 20000
    t += outer(i)
    i += 1
  end
  t
end

puts run
