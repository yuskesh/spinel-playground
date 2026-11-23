# Decision 0044's probe (its Context section), refused before the decision.
# m1b: the same helper, itself declared with freestanding_def (a buffer and its length).
require_relative "spinel/freestanding"

freestanding_def :fill, params: [[:f32_buf, :inout], :len, :i32], returns: :i32
def fill(buf, n, i)
  buf[i] = 0.5
  0
end

freestanding_def :process, params: [[:f32_buf, :inout], :len], returns: :i32
def process(out, frames)
  i = 0
  while i < frames
    fill(out, frames, i)
    i += 1
  end
  frames
end
