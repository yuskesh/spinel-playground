$sp_failed = 0
def check(label, got, want)
  if got == want
    puts "PASS #{label}"
  else
    $sp_failed = $sp_failed + 1
    puts "FAIL #{label}: got #{got} want #{want}"
  end
end
def i32s(values)
  b = IO::Buffer.new(values.size * 4)
  values.size.times { |i| b.set_value(:s32, i * 4, values[i]) }
  b
end
def f32s(values)
  b = IO::Buffer.new(values.size * 4)
  values.size.times { |i| b.set_value(:f32, i * 4, values[i]) }
  b
end
def read_i32(b, i) = b.get_value(:s32, i * 4)
def read_f32(b, i) = b.get_value(:f32, i * 4)
