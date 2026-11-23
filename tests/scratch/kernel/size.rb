# Decision 0041 stage 2, the review: a size the caller chooses is
# known only to lie in [0, 31], so a loop that starts at a.size runs at most
# 32 times, not 32 - 31. The report must bound the work at least as high as
# out[0] = 1 drives it (1 + 31 + 31 * 100 = 3132), or say it is unknown.
def tick(out)
  n = out[0]
  a = Core::Buffer.i64(n, 0)
  i = a.size
  steps = 0
  while i < 32
    j = 0
    while j < 100
      steps += 1
      j += 1
    end
    i += 1
  end
  out[0] = steps
  0
end
