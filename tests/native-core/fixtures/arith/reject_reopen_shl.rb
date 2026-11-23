class Integer
  def <<(o)
    self + o
  end
end

def calculate(a, n)
  a << n
end

puts calculate(3, 4)
