# each over an Array and a Range held in variables, inside a fiber and an
# enumerator; the array grows while it is walked.
xs = [1, 2, 3]
f = Fiber.new do
  xs.each do |x|
    Fiber.yield x * 10
  end
  :end
end
p f.resume
xs << 4
p f.resume
p f.resume
p f.resume
p f.resume

def evens(r)
  Enumerator.new do |y|
    r.each { |v| y << v if v.even? }
  end
end
p evens(1..9).to_a
rng = (3...7)
g = Fiber.new do
  rng.each { |v| Fiber.yield v }
  nil
end
p g.resume
p g.resume

# An endless Range in a variable is walked from its bounds, not
# materialized, so the fiber stops where the block leaves.
def from(start)
  open = (start..)
  h = Fiber.new do
    open.each do |v|
      Fiber.yield v
      break if v >= start + 1
    end
    :stop
  end
  [h.resume, h.resume, h.resume]
end
p from(10)
