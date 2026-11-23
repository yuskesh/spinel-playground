f = Fiber.new do
  begin
    Fiber.yield 3
  rescue ArgumentError
    puts "r"
  end
end
f.resume
