# spinel: int64
require_relative "spinel/freestanding"
# a wrap entry narrowing an extern argument: the declaration said truncate
freestanding_def :go, params: [:i64], returns: :i32, overflow: :wrap
def go(pin)
  gpio_set(pin, 1)
end
