# Exceptions, non-local exits and enumerators: the paths that unwind.
i = 0
catch(:done) do
  loop do
    i += 1
    throw :done if i > 4
  end
end
puts i

acc = []
begin
  begin
    raise ArgumentError, "inner"
  rescue ArgumentError => e
    acc << "rescued #{e.message}"
    raise RuntimeError, "outer"
  ensure
    acc << "inner ensure"
  end
rescue RuntimeError => e
  acc << "outer #{e.message}"
ensure
  acc << "outer ensure"
end
puts acc.inspect

# Enumerator#next is not implemented by the pinned compiler, so the enumeration
# exercised here is the block and chained forms that are.
puts [10, 20, 30].each_with_object([]) { |v, acc| acc << v * 2 }.inspect
puts [1, 2, 3].each_with_index.map { |v, ix| v * ix }.inspect
puts (1..5).each_slice(2).to_a.inspect
