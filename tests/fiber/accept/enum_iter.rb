# Internal iteration over an Enumerator.new, finite and endless, with blocks
# that break out early.
e = Enumerator.new { |y| y << 1; y << 2; y << 3 }
inf = Enumerator.new do |y|
  i = 0
  loop do
    i += 1
    y << i
  end
end
p e.take_while { |v| v < 3 }
p inf.take_while { |v| v < 4 }
p e.find { |v| v > 1 }
p inf.detect { |v| v * v > 20 }
p e.find { |v| v > 9 }
e.with_index(1) { |v, i| p [v, i] }
p e.with_object([]) { |v, a| a << v * 10 }
p inf.first(3)
p inf.map { |v| break v if v > 4; v }
p inf.select { |v| break v if v > 6; v.odd? }
p inf.filter_map { |v| break :stop if v > 3; v * 2 if v.odd? }
p inf.each_with_object([]) { |v, a| break a if v > 2; a << v }
p e.map { |v| v + 1 }
p e.reject(&:odd?)
p e.collect { |v| v.to_s }
