# Decision 0041 stage 2: one element past room.rb's 31; refused.
def tick(out)
  a = Core::Buffer.i64(32, 1)
  out[0] = a[31]
  0
end
