# An entry declared :out calls an entry declared :in, which reads the buffer.
require_relative "spinel/freestanding"
freestanding_def :read_entry, params: [[:i32_buf, :in], :len], returns: :i32
def read_entry(b, n)
  b[0]
end
freestanding_def :call_out, params: [[:i32_buf, :out], :len], returns: :i32
def call_out(b, n)
  read_entry(b, n)
end
