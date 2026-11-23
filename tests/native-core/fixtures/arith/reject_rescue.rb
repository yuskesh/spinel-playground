def calculate(a, b)
  a + b
end

begin
  puts calculate(1, 2)
rescue RangeError
  puts calculate(2, 1)
end
