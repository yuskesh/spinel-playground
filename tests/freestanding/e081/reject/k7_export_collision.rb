require_relative "spinel/freestanding"
# an entry whose EXPORT symbol is one the profile declares as an extern
freestanding_def :go, params: [:i32, :i32], returns: :i32, export: :spinel_zephyr_gpio_set
def go(pin, val)
  pin + val
end
