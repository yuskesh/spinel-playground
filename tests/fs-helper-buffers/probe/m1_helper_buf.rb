# Decision 0044's probe (its Context section), refused before the decision.
# m1: a freestanding entry lends its f32 buffer to a plain helper.
require_relative "spinel/freestanding"

def fill(buf, i)
  buf[i] = 0.5
  0
end

freestanding_def :process, params: [[:f32_buf, :inout], :len], returns: :i32
def process(out, frames)
  i = 0
  while i < frames
    fill(out, i)
    i += 1
  end
  frames
end
