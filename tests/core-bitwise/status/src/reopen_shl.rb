# A reopened Integer#<<: the type still says Integer, but the method is not
# the builtin shift any more.
class Integer
  def <<(o)
    self + o
  end
end

def reopen_shl(a, n)
  a << n
end
