require_relative "spinel/freestanding"
freestanding_def :go, params: [:f64], returns: :i32
def go(x)
  gpio_set(x, 1)
end
