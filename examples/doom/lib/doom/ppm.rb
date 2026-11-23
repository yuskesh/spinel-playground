# doom/lib/doom/ppm.rb
#
# Writes an 8-bit index plane as PPM (P6). **A tool only for checking by eye.**
#
# The differential oracle compares indices as they are (to rule out differences in
# reading the palette). PPM is an exit outside that, where a person looks at whether
# "it is plausible as a picture"; no gate rests on it.

require_relative "bytes"

module Doom
  module Ppm
    # How transparent pixels are painted (PPM has no transparency). Magenta by default.
    TRANSPARENT_R = 255
    TRANSPARENT_G = 0
    TRANSPARENT_B = 255

    # plane: a w*h String of 8-bit indices
    def self.write(path, plane, w, h, palette, transparent)
      out = Bytes.buffer(w * h * 3, 0)
      i = 0
      n = w * h
      o = 0
      while i < n
        v = plane.getbyte(i)
        if v == transparent
          out.setbyte(o, TRANSPARENT_R)
          out.setbyte(o + 1, TRANSPARENT_G)
          out.setbyte(o + 2, TRANSPARENT_B)
        else
          out.setbyte(o, palette.r(v))
          out.setbyte(o + 1, palette.g(v))
          out.setbyte(o + 2, palette.b(v))
        end
        o += 3
        i += 1
      end
      File.open(path, "wb") do |f|
        f.write("P6\n")
        f.write("#{w} #{h}\n")
        f.write("255\n")
        f.write(out)
      end
      out.bytesize + 3 + "#{w} #{h}\n".bytesize + 4
    end
  end
end
