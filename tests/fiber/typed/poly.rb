# The receiver is an Array on one path and a Range on the other, so the
# analysis types it poly and the rewrite cannot pick a form: refused.
xs = ARGV.empty? ? [1, 2] : (1..2)
f = Fiber.new do
  xs.each { |x| Fiber.yield x }
  nil
end
p f.resume
