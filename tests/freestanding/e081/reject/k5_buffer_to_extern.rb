require_relative "spinel/freestanding"
freestanding_def :go, params: [[:u8_buf, :in], :len], returns: :i64
def go(b, n)
  checksum32(b)
end
