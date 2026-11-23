def fill(y)
  y << 1
end
e = Enumerator.new { |y| fill(y) }
