# Is the left or the right of a picture bright? Every value below is by hand.
#
# A pixel p means (p + 128) / 256, so 127 is 255/256 and -128 is exactly 0.
# The convolution adds nine pixels with weight 1.0: nine bright pixels give
# 8.9648, which is 112 steps of 0.08, so -16. The pooled picture is 3 by 3 with
# eight equal channels. Unit 0 reads the first channel of its left column and
# unit 1 of its right column, three cells at 0.1:
# 3 * 8.96 * 0.1 = 2.688, which is 27 steps of 0.1. A column with no bright
# pixel gives exactly 0.
require_relative "spinel/tensor"

W1 = Array.new(8) { Array.new(9, 100) }
W2 = [([10] + [0] * 23) * 3, ([0] * 16 + [10] + [0] * 7) * 3]

npu_def :sides, input: [:i8, 1, 8, 8, 1], quant: [1.0 / 256, -128] do
  conv2d 8, kernel: 3, weights: W1, weight_scale: 0.01, bias: [0] * 8, quant: [0.08, -128], activation: :relu
  max_pool 2
  flatten
  fully_connected 2, weights: W2, weight_scale: 0.01, bias: [0, 0], quant: [0.1, 0]
end
require_relative "npu.gen"

ROW_LEFT = "\x7F\x7F\x7F\x7F\x80\x80\x80\x80"
ROW_RIGHT = "\x80\x80\x80\x80\x7F\x7F\x7F\x7F"
ROW_DARK = "\x80\x80\x80\x80\x80\x80\x80\x80"

def signed(b)
  b >= 128 ? b - 256 : b
end

Tensor.device("local-sync", "@npu") do
  x = Tensor.ten4(:i8, 1, 8, 8, 1)
  y = Tensor.mat(:i8, 1, 2)
  [["left", ROW_LEFT], ["right", ROW_RIGHT], ["dark", ROW_DARK]].each do |name, row|
    x.store_bytes(row * 8)
    sides(x, y)
    s = y.to_bytes
    puts "#{name} #{signed(s.getbyte(0))} #{signed(s.getbyte(1))}"
  end
end
puts "done"
