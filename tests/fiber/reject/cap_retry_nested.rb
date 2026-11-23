# The retry sits in a plain begin inside the rescue, so it retries the outer
# begin, which assigns `x` before the site on every pass.
def m(tries)
  x = 0
  begin
    x += 1
    e = Enumerator.new { |y| y << x }
    raise "again" if x < tries
    e
  rescue
    begin
      retry
    end
  end
end
p m(2).next
