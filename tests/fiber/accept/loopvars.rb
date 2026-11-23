f = Fiber.new do
  3.times do |i|
    seen ||= i
    Fiber.yield seen
  end
  :ok
end

4.times { p f.resume }
