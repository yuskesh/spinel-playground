# Decision 0045, the review: text that only looks like a buffer call,
# in a heredoc (with an `=begin` line in its body), a %q literal and a
# string, is not one; tick's own call is still rewritten.
def unused
  x = <<~TEXT
    =begin
    Core::Buffer.i64(5)
  TEXT
  y = %q(Core::Buffer.i64(6))
  z = "Core::Buffer.i64("
  0
end

def tick(out)
  a = Core::Buffer.i64(2, 7)
  out[0] = a[1]
  0
end
