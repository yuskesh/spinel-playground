require_relative "spinel/freestanding"

class Integer
  def <<(o)
    self + o
  end
end

freestanding_def :reopen_shl, params: [:i64], returns: :i64
def reopen_shl(a)
  a << 1
end
