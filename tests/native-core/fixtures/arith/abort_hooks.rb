def calculate(a, b)
  a + b
end

at_exit { puts "at_exit" }
begin
  puts calculate(9223372036854775807, 1)
rescue RangeError
  puts "rescued"
ensure
  puts "ensure"
end
puts "continued"
