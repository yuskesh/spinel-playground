arr = [1, 2]
e = Enumerator.new do |y|
  arr.map { |v| y << v }
end
