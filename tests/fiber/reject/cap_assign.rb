t = 0
e = Enumerator.new do |y|
  t += 1
  y << t
end
