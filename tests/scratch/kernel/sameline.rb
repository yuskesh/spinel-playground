# Decision 0045, the review: two buffers with the default fill on one
# line. The rewrite appends each fill, which moves what follows it in the
# reader's copy; the second call is still recognised as written.
def tick(out)
  a = Core::Buffer.i64(1); b = Core::Buffer.i64(2)
  out[0] = a.size + b.size
  0
end
