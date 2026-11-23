require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a7: the differentiated kernel WRITES memory.  Every other buffer is
# being declared enzyme_const, so the adjoint would have to reverse a store
# into memory nobody is shadowing.
freestanding_grad_def :lossw, wrt: :w
freestanding_def :lossw, params: [[:f64_buf, :in], [:f64_buf, :out], :len], returns: :f64
def lossw(w, scratch, n)
  scratch[0] = w[0]
  w[0] * w[0]
end
