# A reopened Integer#**: the type still says Integer, but the method is not
# the builtin power any more.
class Integer
  def **(o)
    self * o
  end
end

def reopen_pow(a, n)
  a ** n
end
