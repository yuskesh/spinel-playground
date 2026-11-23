# spinel: int64
require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i64
def go(n)
  uptime_ms() + checksum32(n % 256)
end
