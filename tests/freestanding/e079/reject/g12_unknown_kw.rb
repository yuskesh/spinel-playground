require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a11: the learning rate is not a property of the DERIVATIVE.  Writing it
# on the declaration would put an SGD hyper-parameter into the type of the
# gradient; the keyword does not exist and is not quietly ignored.
freestanding_grad_def :lossk, wrt: :w, lr: 0.1
freestanding_def :lossk, params: [[:f64_buf, :in], :len], returns: :f64
def lossk(w, nw)
  w[0] * w[0]
end
