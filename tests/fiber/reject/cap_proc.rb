# A write in a block before the site may run after it (the bpf-mlir coordinator's probe).
def m
  x = 1
  bump = proc { x += 10 }
  e = Enumerator.new { |y| y << x }
  bump.call
  e.next
end
p m
