#!/usr/bin/env ruby
# Check visible RGB content inside a GPU screenshot's 3D viewport.
# This checks visibility, not agreement with a CPU renderer.
require "optparse"

module RasterVisibility
  class InvalidImage < StandardError; end

  def self.measure(path, screen, viewport)
    data = File.binread(path)
    raise InvalidImage, "missing BMP header" if data.bytesize < 54 || data.byteslice(0, 2) != "BM"
    size, offset = data.byteslice(2, 12).unpack("Vx4V")
    dib, width, height, planes, bits, compression = data.byteslice(14, 20).unpack("Vl<l<vvV")
    if dib < 40 || 14 + dib > data.bytesize || planes != 1 || width <= 0 || height.zero?
      raise InvalidImage, "invalid BMP dimensions/header"
    end
    unless [width, height.abs] == screen
      raise InvalidImage, "screen is #{width}x#{height.abs}, expected #{screen.join('x')}"
    end
    x, y, w, h = viewport
    if [x, y].min < 0 || [w, h].min <= 0 || x + w > width || y + h > height.abs
      raise InvalidImage, "empty or out-of-bounds viewport"
    end
    unless [8, 24, 32].include?(bits) && [0, 3].include?(compression) && (compression != 3 || bits == 32)
      raise InvalidImage, "unsupported BMP format (#{bits} bits, compression #{compression})"
    end
    metadata_end = 14 + dib
    rgb_mask = 0x00ffffff
    if compression == 3
      masks_at = 14 + 40
      raise InvalidImage, "truncated RGB masks" if masks_at + 12 > data.bytesize
      red, green, blue = data.byteslice(masks_at, 12).unpack("V3")
      if [red, green, blue].any?(&:zero?) || (red & green) != 0 || (red & blue) != 0 || (green & blue) != 0
        raise InvalidImage, "invalid RGB masks"
      end
      rgb_mask = red | green | blue
      metadata_end = [metadata_end, masks_at + 12].max
    end
    palette = nil
    if bits == 8
      colors = data.byteslice(46, 4).unpack1("V")
      colors = 256 if colors.zero?
      raise InvalidImage, "invalid BMP palette" if colors > 256 || metadata_end + colors * 4 > data.bytesize
      palette = Array.new(colors) { |i| data.byteslice(metadata_end + i * 4, 3).bytes.any? { |b| b != 0 } }
      metadata_end += colors * 4
    end
    stride = ((width * bits + 31) / 32) * 4
    ending = offset + stride * height.abs
    if offset < metadata_end || ending > data.bytesize || size < ending || size > data.bytesize
      raise InvalidImage, "truncated or overlapping BMP pixel data"
    end
    nonblack = 0
    (y...y + h).each do |row|
      storage_row = height < 0 ? row : height.abs - 1 - row
      start = offset + storage_row * stride + x * (bits / 8)
      w.times do |col|
        pos = start + col * (bits / 8)
        lit = if bits == 8
                index = data.getbyte(pos)
                raise InvalidImage, "pixel outside BMP palette" if index >= palette.length
                palette[index]
              elsif bits == 24
                data.getbyte(pos) != 0 || data.getbyte(pos + 1) != 0 || data.getbyte(pos + 2) != 0
              else
                (data.byteslice(pos, 4).unpack1("V") & rgb_mask) != 0
              end
        nonblack += 1 if lit
      end
    end
    [nonblack, w * h]
  end

  def self.main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = "usage: visibility.rb IMAGE --screen WIDTHxHEIGHT --viewport X,Y,WIDTH,HEIGHT"
      opts.on("--screen SIZE") { |v| options[:screen] = v }
      opts.on("--viewport RECT") { |v| options[:viewport] = v }
    end
    parser.parse!(argv)
    raise InvalidImage, parser.to_s unless argv.length == 1 && options[:screen] && options[:viewport]
    path = argv.first
    screen = options[:screen].split("x").map { |v| Integer(v, 10) }
    viewport = options[:viewport].split(",").map { |v| Integer(v, 10) }
    unless screen.length == 2 && viewport.length == 4 && screen.min > 0
      raise InvalidImage, "invalid screen/viewport arguments"
    end
    nonblack, area = measure(path, screen, viewport)
    passed = nonblack * 2 >= area
    puts format("visibility: %s %s: %d/%d non-black RGB pixels (%.2f%%; minimum 50%%)",
                passed ? "PASS" : "FAIL", path, nonblack, area, 100.0 * nonblack / area)
    passed ? 0 : 1
  rescue SystemCallError, ArgumentError, OptionParser::ParseError, InvalidImage => error
    warn "visibility: FAIL #{path}: #{error.message}"
    1
  end
end

exit RasterVisibility.main(ARGV) if $PROGRAM_NAME == __FILE__
