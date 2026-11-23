# framework/codec.rb -- the one implementation of percent encoding.
#
# It is used from 2 places:
#   1. reading an `application/x-www-form-urlencoded` request body and query string
#      (there is no Rack and no CGI library, so it is our own; `+` is a space, `%XX` a byte)
#   2. framework/model.rb's record encoding (there is no JSON, so lines + percent escapes)
#
# `require "json"` needs a native `.o`, so **this target's Ruby cannot read
# JSON** (the `--host-api` option in tools/wasm/README.md). So the encoding is our own.
module Codec
  HEX = "0123456789ABCDEF"

  # "%E3%81%82" -> U+3042 (one hiragana letter). Only when plus_as_space=true is "+" a space
  # (true for forms, false for the record encoding).
  #
  # `hex.to_i(16).chr` makes one byte. Appending each byte of UTF-8 in turn gives
  # the right multibyte string (Spinel's String keeps the bytes when concatenating).
  def self.percent_decode(str, plus_as_space = true)
    s = str.to_s
    out = ""
    i = 0
    n = s.length
    while i < n
      c = s[i]
      if c == "%" && i + 2 < n
        hex = s[i + 1, 2]
        if hex_pair?(hex)
          out += hex.to_i(16).chr
          i += 3
          next
        end
      end
      if c == "+" && plus_as_space
        out += " "
      else
        out += c
      end
      i += 1
    end
    out
  end

  # The minimal escaping for the record encoding: only the 4 characters that break lines and separators.
  # UTF-8 in a value stays as it is, so a value in KV can be read by eye.
  def self.percent_escape_record(str)
    s = str.to_s
    out = ""
    i = 0
    n = s.length
    while i < n
      c = s[i]
      if c == "%"
        out += "%25"
      elsif c == "\n"
        out += "%0A"
      elsif c == "\r"
        out += "%0D"
      else
        out += c
      end
      i += 1
    end
    out
  end

  # A form / query string -> Hash. For a repeated key **the last wins** (as in Rack).
  # There are no array parameters (`a[]=1&a[]=2`): what is absent is not quietly made an empty array.
  def self.parse_form(str)
    out = {}
    s = str.to_s
    return out if s.empty?

    s.split("&").each do |pair|
      next if pair.empty?
      i = pair.index("=")
      if i.nil?
        out[percent_decode(pair)] = ""
      else
        key = percent_decode(pair[0, i])
        value = percent_decode(pair[(i + 1), pair.length - i - 1])
        out[key] = value unless key.empty?
      end
    end
    out
  end

  def self.hex_pair?(hex)
    return false if hex.length != 2
    hex_digit?(hex[0]) && hex_digit?(hex[1])
  end

  def self.hex_digit?(c)
    HEX.index(c.upcase) != nil
  end
end
