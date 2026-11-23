require_relative "spinel/freestanding"
# a top-level method with the SAME NAME as a profile extern
def gpio_set(pin, val)
  pin + val
end
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  gpio_set(n, 1)
end
