#!/usr/bin/env ruby
# Observable screenshot controls; no GPU or rendering oracle.
require "tmpdir"
require "open3"
require "rbconfig"
CHECK = File.join(__dir__, "visibility.rb")

def bmp(path, bits, top_down, &pixel)
  width = height = 10
  stride = ((width * bits + 31) / 32) * 4
  body = String.new(encoding: Encoding::BINARY)
  rows = top_down ? (0...height).to_a : (0...height).to_a.reverse
  rows.each do |y|
    row = String.new(encoding: Encoding::BINARY)
    width.times do |x|
      r, g, b = pixel.call(x, y)
      row << [b, g, r].pack("C3")
      row << [255].pack("C") if bits == 32
    end
    row << "\0" * (stride - row.bytesize)
    body << row
  end
  header = "BM" + [54 + body.bytesize, 0, 0, 54].pack("VvvV")
  dib = [40, width, top_down ? -height : height, 1, bits, 0, body.bytesize, 0, 0, 0, 0].pack("Vl<l<vvVVl<l<VV")
  File.binwrite(path, header + dib + body)
end

failures = 0
Dir.mktmpdir("raster-visibility-") do |root|
  cases = []
  [
    ["black", 24, false, ->(x, y) { [0, 0, 0] }],
    ["hud-only", 24, false, ->(x, y) { y >= 8 ? [255, 255, 255] : [0, 0, 0] }],
    ["opaque-black", 32, false, ->(x, y) { [0, 0, 0] }],
    ["half-visible", 24, false, ->(x, y) { x < 5 ? [0, 128, 0] : [0, 0, 0] }],
    ["below-half", 24, false, ->(x, y) { x < 4 ? [128, 0, 0] : [0, 0, 0] }],
    ["top-down", 32, true, ->(x, y) { [0, 0, 128] }]
  ].each do |name, bits, top_down, pixel|
    path = File.join(root, "#{name}.bmp")
    bmp(path, bits, top_down, &pixel)
    cases << [name, path, "10x10", "0,0,10,8", %w[half-visible top-down].include?(name) ? 0 : 1]
  end
  original = File.binread(File.join(root, "top-down.bmp"))
  header = original.byteslice(0, 54)
  header[2, 4] = [original.bytesize + 12].pack("V")
  header[10, 4] = [66].pack("V")
  header[30, 4] = [3].pack("V")
  bitfields = File.join(root, "bitfields.bmp")
  File.binwrite(bitfields, header + [0xff0000, 0xff00, 0xff].pack("V3") + original.byteslice(54..))
  cases << ["RGB-bitfields", bitfields, "10x10", "0,0,10,8", 0]
  cases.concat([
    ["missing", File.join(root, "missing.bmp"), "10x10", "0,0,10,8", 1],
    ["wrong-size", File.join(root, "half-visible.bmp"), "20x10", "0,0,10,8", 1],
    ["empty-crop", File.join(root, "half-visible.bmp"), "10x10", "0,0,0,8", 1],
    ["outside-crop", File.join(root, "half-visible.bmp"), "10x10", "1,0,10,8", 1]
  ])
  truncated = File.join(root, "truncated.bmp")
  File.binwrite(truncated, File.binread(File.join(root, "half-visible.bmp"))[0...-1])
  cases << ["truncated", truncated, "10x10", "0,0,10,8", 1]
  cases.each do |name, path, screen, viewport, wanted|
    out, err, status = Open3.capture3(RbConfig.ruby, CHECK, path, "--screen", screen, "--viewport", viewport)
    passed = status.exitstatus == wanted
    puts "#{passed ? 'PASS' : 'FAIL'} #{name}: exit #{status.exitstatus}, expected #{wanted}"
    unless passed
      puts out + err
      failures += 1
    end
  end
  puts "visibility controls: #{cases.length - failures} passed, #{failures} failed"
end
exit(failures.zero? ? 0 : 1)
