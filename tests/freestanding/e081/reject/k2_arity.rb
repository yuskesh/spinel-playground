require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  gpio_set(n)
end
