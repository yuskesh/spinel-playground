# tests/shader/check_image.rb — properties of one drawn image.
#
#   ruby check_image.rb <file> rgba8|r32u <W> <H> [checks...]
#
#   --opaque            every pixel's alpha is 255
#   --min-colors N      at least N distinct RGB values (the shader varies)
#   --lit N             exactly N pixels have a non-zero RGB (rgba8) or id (r32u)
#   --bbox X0,Y0,X1,Y1  those pixels span exactly this inclusive box
#   --ids A,B,...       the non-zero ids are exactly this set (r32u)
#   --tol N             the per-component tolerance of the --at checks after it
#   --at X,Y,R,G,B,A    the pixel at X,Y holds this RGBA, within --tol (rgba8)
#
# Every expectation comes from the shader's declaration or its scene file, never
# from another implementation's output. Prints one line; exit 0 when every
# check holds, 1 otherwise, 2 on a usage error or a file of the wrong size.

path, fmt, w, h, *opts = ARGV
unless path && %w[rgba8 r32u].include?(fmt) && w && h
  warn "usage: check_image.rb <file> rgba8|r32u <W> <H> [checks...]"
  exit 2
end
w = Integer(w)
h = Integer(h)
data = File.binread(path)
if data.bytesize != w * h * 4
  puts "FAIL  #{File.basename(path)}: #{data.bytesize} bytes, expected #{w * h * 4}"
  exit 2
end

px = fmt == "rgba8" ? data.unpack("C*").each_slice(4).to_a : data.unpack("L<*")
lit = []
px.each_with_index do |p, i|
  on = fmt == "rgba8" ? (p[0] | p[1] | p[2]) != 0 : p != 0
  lit << i if on
end

bad = []
said = []
tol = 0
i = 0
while i < opts.size
  o = opts[i]
  arg = opts[i + 1]
  case o
  when "--opaque"
    amin = px.map { |p| p[3] }.min
    said << "alpha min #{amin}"
    bad << "alpha #{amin} < 255" unless amin == 255
    i += 1
    next
  when "--min-colors"
    n = px.map { |p| p[0, 3] }.uniq.size
    said << "#{n} colors"
    bad << "#{n} colors < #{arg}" if n < Integer(arg)
  when "--lit"
    said << "#{lit.size} lit"
    bad << "#{lit.size} lit, expected #{arg}" unless lit.size == Integer(arg)
  when "--bbox"
    want = arg.split(",").map { |s| Integer(s) }
    got = if lit.empty?
            nil
          else
            xs = lit.map { |k| k % w }
            ys = lit.map { |k| k / w }
            [xs.min, ys.min, xs.max, ys.max]
          end
    said << "bbox #{got ? got.join(',') : 'none'}"
    bad << "bbox #{got.inspect}, expected #{want.join(',')}" unless got == want
  when "--ids"
    want = arg.split(",").map { |s| Integer(s) }.sort
    got = lit.map { |k| px[k] }.uniq.sort
    said << "ids #{got.join(',')}"
    bad << "ids #{got.join(',')}, expected #{want.join(',')}" unless got == want
  when "--tol"
    tol = Integer(arg)
  when "--at"
    x, y, *want = arg.split(",").map { |s| Integer(s) }
    got = px[y * w + x]
    said << "(#{x},#{y})=#{got.join(',')}"
    unless want.size == 4 && got.zip(want).all? { |g, e| (g - e).abs <= tol }
      bad << "(#{x},#{y}) is #{got.join(',')}, expected #{want.join(',')} +-#{tol}"
    end
  else
    warn "check_image.rb: unknown check #{o}"
    exit 2
  end
  i += 2
end

puts "#{bad.empty? ? 'ok' : 'FAIL'}  #{File.basename(path)}: #{said.join(', ')}" \
     "#{bad.empty? ? '' : ' -- ' + bad.join('; ')}"
exit(bad.empty? ? 0 : 1)
