# Exact direction matches, no :inout anywhere: an :in kernel buffer feeds the
# extern's :in parameters and an :out kernel buffer takes the extern's :out
# shadow.  (The E083 kernel itself uses :inout for w and g because the UPDATE
# reads them back; this control shows the narrow spellings work too.)
require_relative "spinel/freestanding"
freestanding_def :go, params: [[:f64_buf, :in], :len, [:f64_buf, :in], [:f64_buf, :out], :len], returns: :f64
def go(d, nd, w, g, nw)
  grad_loss(d, nd, w, g, nw)
end
