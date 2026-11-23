require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# c1: the control -- a two-buffer gradient with a constant f64 scalar and a
# `bounds: :unchecked` variant, i.e. everything the table above refuses done
# in the way that is allowed.
freestanding_grad_def :ok_loss, wrt: [:w, :b], tol: 1.0e-7
freestanding_def :ok_loss, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len,
                                    [:f64_buf, :in], :len, :f64], returns: :f64
def ok_loss(x, nx, w, nw, b, nb, reg)
  s = 0.0
  i = 0
  while i < nw
    s = s + w[i] * x[i]
    i += 1
  end
  (s + b[0]) * (s + b[0]) + reg * w[0] * w[0]
end

freestanding_def :ok_step, params: [[:f64_buf, :inout], [:f64_buf, :in], :len, :f64],
                 returns: :i32, bounds: :unchecked
def ok_step(w, g, n, lr)
  i = 0
  while i < n
    w[i] = w[i] - lr * g[i]
    i += 1
  end
  n
end
