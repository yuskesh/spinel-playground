require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# b2: the step rescales the length it is bounds-checking against.
freestanding_def :bad_step2, params: [[:f64_buf, :inout], [:f64_buf, :in], :len, :f64],
                 returns: :i32
def bad_step2(w, g, n, lr)
  n = n - 1
  i = 0
  while i < n
    w[i] = w[i] - lr * g[i]
    i += 1
  end
  n
end
