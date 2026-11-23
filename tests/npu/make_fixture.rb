#!/usr/bin/env ruby
# tests/npu/make_fixture.rb SAMPLE_DIR OUT -- builds the test program from
# Zephyr's tflm_neutron sample: its converted CIFAR-10 model and its picture of
# a ship. Neither is copied into this repository.
sample, out = ARGV
hex = File.read(File.join(sample, "src/models/mcxn/model.hpp")).scan(/0x([0-9a-fA-F]{2})/).map { |x| x[0].to_i(16) }
File.binwrite(File.join(out, "cifar.tflite"), hex.pack("C*"))
image = File.read(File.join(sample, "src/image_data.h"))[/image_data\[\]\s*=\s*\{(.*?)\}/m, 1].scan(/\d+/).map(&:to_i)
abort "the picture is #{image.size} bytes, not 3072" unless image.size == 3072
abort "the sample's picture is no longer the ship" unless File.read(File.join(sample, "src/image_data.h")).include?('STATIC_IMAGE_NAME "ship"')
lit = ->(a) { '"' + a.map { |b| format("\\x%02X", b & 0xff) }.join + '"' }
File.write(File.join(out, "ship.rb"), <<~R)
  require_relative "spinel/tensor"
  npu_extern :classify, tflite: "cifar.tflite",
             input: [:i8, 1, 32, 32, 3], output: [:i8, 1, 12], partial: true
  require_relative "npu.gen"

  IMAGE = #{lit[image.map { |b| b - 128 }]}
  INVERTED = #{lit[image.map { |b| ~(b - 128) }]}

  def signed(b)
    b >= 128 ? b - 256 : b
  end

  # The model's first ten outputs are the classes; the last two are padding.
  def top1(s)
    best = 0
    i = 1
    while i < 10
      best = i if signed(s.getbyte(i)) > signed(s.getbyte(best))
      i += 1
    end
    best
  end

  Tensor.device("local-sync", "@npu") do
    x = Tensor.ten4(:i8, 1, 32, 32, 3)
    y = Tensor.mat(:i8, 1, 12)
    x.store_bytes(IMAGE)
    classify(x, y)
    first = y.to_bytes
    puts "top1 \#{top1(first)}"
    x.store_bytes(INVERTED)
    classify(x, y)
    second = y.to_bytes
    puts "changed \#{first == second ? 0 : 1}"
    # Each pass allocates a string; the host prints how many collections ran.
    n = 0
    i = 0
    while i < 2000
      x.store_bytes(IMAGE)
      classify(x, y)
      n += 1 if top1(y.to_bytes) == 8
      i += 1
    end
    puts "repeat \#{n}"
  end
  puts "done"
R
