#!/usr/bin/env ruby
# frozen_string_literal: true
#
# examples/image -- makes deterministic test images (standard library only).
#
#     mkimages.rb <outdir>
#
# **A copy of the predecessor's frozen Python script `frozen/mkimages.py`** (not in
# this repository). The claim is that the 4 PGM files match byte for byte, and stdout / rc
# too; the predecessor's differential test checked it. **Why 4 images (the share of ties
# differs per image) is set out in the frozen script's docstring.**
#
# **`int(s + 0.5)` truncates**; it does not round half up (it goes toward 0 when negative).
# Ruby's `.round` rounds halves to even, so it cannot be used: use `.to_i`.

require "fileutils"

def write_pgm(path, w, h, px)
  File.open(path, "wb") do |f|
    f.write("P5\n#{w} #{h}\n255\n")
    f.write(px.pack("C*"))
  end
end

# Band-limited 'photo-like' grey (E042's, unchanged): low-frequency
# sinusoids plus two soft edges and a flat plateau.
def photo(w, h)
  out = Array.new(w * h, 0)
  i = 0
  h.times do |y|
    v = y.to_f / [h - 1, 1].max
    w.times do |x|
      u = x.to_f / [w - 1, 1].max
      s = 60.0 +
          40.0 * Math.sin(2.0 * Math::PI * (1.5 * u + 0.25)) +
          30.0 * Math.sin(2.0 * Math::PI * (1.0 * v)) +
          20.0 * Math.sin(2.0 * Math::PI * (2.0 * u + 3.0 * v))
      if u > 0.30 && u < 0.34
        s += 60.0 * (u - 0.30) / 0.04
      elsif u >= 0.34
        s += 60.0
      end
      s = 200.0 if v > 0.60 && v < 0.75 && u > 0.55 && u < 0.80
      t = (s + 0.5).to_i
      out[i] = t < 0 ? 0 : (t > 255 ? 255 : t)
      i += 1
    end
  end
  out
end

# R005's 4K asset, `(y*7 + x*13) % 251`.
def r005pat(w, h)
  out = Array.new(w * h, 0)
  i = 0
  h.times { |y| w.times { |x| out[i] = (y * 7 + x * 13) % 251; i += 1 } }
  out
end

# A horizontal ramp.
def ramp(w, h)
  out = Array.new(w * h, 0)
  i = 0
  h.times { w.times { |x| out[i] = x % 256; i += 1 } }
  out
end

def flat(w, h, v = 128)
  Array.new(w * h, v)
end

IMAGES = [
  ["uhd.pgm", 3840, 2160, :photo],
  ["uhd_r005.pgm", 3840, 2160, :r005pat],
  ["uhd_ramp.pgm", 3840, 2160, :ramp],
  ["uhd_flat.pgm", 3840, 2160, :flat],
].freeze

def main(outdir)
  FileUtils.mkdir_p(outdir)
  IMAGES.each do |name, w, h, fn|
    path = File.join(outdir, name)
    want = "P5\n#{w} #{h}\n255\n".bytesize + w * h
    if File.exist?(path) && File.size(path) == want
      $stdout.write("#{name} (cached)\n")
      next
    end
    write_pgm(path, w, h, send(fn, w, h))
    $stdout.write(format("%s %d bytes\n", name, File.size(path)))
  end
end

main(ARGV[0] || ".") if $PROGRAM_NAME == __FILE__
