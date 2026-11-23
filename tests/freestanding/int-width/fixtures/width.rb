require_relative "../../../../tools/freestanding/spinel/freestanding"
freestanding_def :width_probe, params: [:i32], returns: :i32
def width_probe(x)
  twice = x + x
  twice / 2
end
