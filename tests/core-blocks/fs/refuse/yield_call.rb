require_relative "spinel/freestanding"
freestanding_def :f, params: [:i32, [:i32_buf, :in], :len], returns: :i32
def f(n, buf, len)
  s = 0
  yield
  s
end
