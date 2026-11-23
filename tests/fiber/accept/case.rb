f = Fiber.new do
  [3, :sym, "str", 9].each do |v|
    case v
    when Integer
      if v > 5
        Fiber.yield "big #{v}"
      else
        Fiber.yield "int #{v}"
      end
    when Symbol, String
      Fiber.yield "word #{v}"
    end
  end
  pt = Fiber.yield(:point)
  case pt
  in [x, 0]
    Fiber.yield "on the x axis at #{x}"
  in [x, y]
    Fiber.yield "at #{x},#{y}"
  end
  :end
end

5.times { puts f.resume }
puts f.resume([4, 0])
p f.resume
