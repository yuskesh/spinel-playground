require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# b1: the SGD step updates a weight buffer declared :in (E077 D-5, the
# direction half of the contract -- compile time).
freestanding_def :bad_step, params: [[:f64_buf, :in], [:f64_buf, :in], :len, :f64],
                 returns: :i32
def bad_step(w, g, n, lr)
  i = 0
  while i < n
    w[i] = w[i] - lr * g[i]
    i += 1
  end
  n
end
