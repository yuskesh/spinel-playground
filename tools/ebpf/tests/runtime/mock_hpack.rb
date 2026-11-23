# frozen_string_literal: true
#
# mock_hpack.rb — HPACK (RFC 7541) for mock_otlp_grpc.rb: a whole decoder
# (static and dynamic tables, every representation, Huffman strings) and an
# encoder that writes literal fields without indexing.
#
# The decoder takes any conforming header block, not only the form
# src/runtime/otlp/otlp_grpc.c sends (literal, new name, no Huffman), so
# that a control can send it requests from an independent HTTP/2 client.

module MockHpack
  class Error < StandardError; end

  # Appendix A.
  STATIC = [
    [":authority", ""], [":method", "GET"], [":method", "POST"], [":path", "/"],
    [":path", "/index.html"], [":scheme", "http"], [":scheme", "https"], [":status", "200"],
    [":status", "204"], [":status", "206"], [":status", "304"], [":status", "400"],
    [":status", "404"], [":status", "500"], ["accept-charset", ""], ["accept-encoding", "gzip, deflate"],
    ["accept-language", ""], ["accept-ranges", ""], ["accept", ""], ["access-control-allow-origin", ""],
    ["age", ""], ["allow", ""], ["authorization", ""], ["cache-control", ""],
    ["content-disposition", ""], ["content-encoding", ""], ["content-language", ""], ["content-length", ""],
    ["content-location", ""], ["content-range", ""], ["content-type", ""], ["cookie", ""],
    ["date", ""], ["etag", ""], ["expect", ""], ["expires", ""],
    ["from", ""], ["host", ""], ["if-match", ""], ["if-modified-since", ""],
    ["if-none-match", ""], ["if-range", ""], ["if-unmodified-since", ""], ["last-modified", ""],
    ["link", ""], ["location", ""], ["max-forwards", ""], ["proxy-authenticate", ""],
    ["proxy-authorization", ""], ["range", ""], ["referer", ""], ["refresh", ""],
    ["retry-after", ""], ["server", ""], ["set-cookie", ""], ["strict-transport-security", ""],
    ["transfer-encoding", ""], ["user-agent", ""], ["vary", ""], ["via", ""],
    ["www-authenticate", ""]
  ].freeze

  # Appendix B, as the code length of each of the 256 octets; EOS (256) is 30
  # bits. The code is canonical: codes ascend with length, and within one
  # length with the symbol, which is how they are rebuilt here.
  HUFFMAN_LENGTHS = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30
  ].freeze
  EOS = 256

  # {[length, code] => symbol}
  HUFFMAN = begin
    table = {}
    code = -1
    prev = 0
    (0..EOS).sort_by { |s| [HUFFMAN_LENGTHS[s], s] }.each do |s|
      len = HUFFMAN_LENGTHS[s]
      code = (code + 1) << (len - prev)
      prev = len
      table[[len, code]] = s
    end
    table.freeze
  end

  module_function

  def huffman_decode(bytes)
    out = +"".b
    code = 0
    len = 0
    bytes.each_byte do |b|
      7.downto(0) do |i|
        code = (code << 1) | ((b >> i) & 1)
        len += 1
        raise Error, "Huffman code longer than 30 bits" if len > 30

        sym = HUFFMAN[[len, code]]
        next if sym.nil?
        raise Error, "EOS inside a Huffman string" if sym == EOS

        out << sym.chr
        code = 0
        len = 0
      end
    end
    # 5.2: the padding is the most significant bits of EOS, fewer than 8
    raise Error, "Huffman padding is not a prefix of EOS" if len >= 8 || code != (1 << len) - 1

    out
  end

  # 5.1: an integer with an N-bit prefix at s[pos]; [value, next position].
  def integer(s, pos, n)
    raise Error, "header block ends inside an integer" if pos >= s.bytesize

    max = (1 << n) - 1
    v = s.getbyte(pos) & max
    pos += 1
    return [v, pos] if v < max

    shift = 0
    loop do
      raise Error, "header block ends inside an integer" if pos >= s.bytesize
      raise Error, "integer too large" if shift > 28

      b = s.getbyte(pos)
      pos += 1
      v += (b & 0x7f) << shift
      shift += 7
      break if (b & 0x80).zero?
    end
    [v, pos]
  end

  def string(s, pos)
    raise Error, "header block ends before a string" if pos >= s.bytesize

    huff = s.getbyte(pos) & 0x80 != 0
    len, pos = integer(s, pos, 7)
    raise Error, "string runs past the header block" if pos + len > s.bytesize

    raw = s.byteslice(pos, len)
    [huff ? huffman_decode(raw) : raw.b, pos + len]
  end

  def encode_integer(v, n, first = 0)
    max = (1 << n) - 1
    return (first | v).chr.b if v < max

    out = (first | max).chr.b
    v -= max
    while v >= 128
      out << ((v & 0x7f) | 0x80).chr
      v >>= 7
    end
    out << v.chr
  end

  # Literal header fields without indexing, new names, raw strings (6.2.2).
  def encode(headers)
    headers.each_with_object(+"".b) do |(name, value), out|
      out << "\x00".b << encode_integer(name.bytesize, 7) << name.b
      out << encode_integer(value.bytesize, 7) << value.to_s.b
    end
  end

  # A decoder keeps its dynamic table across the header blocks of one
  # connection (2.3.2), so there is one per connection.
  class Decoder
    def initialize(max_size = 4096)
      @limit = max_size # SETTINGS_HEADER_TABLE_SIZE as this side announced it
      @max = max_size
      @table = [] # newest first
      @size = 0
    end

    # The header list of one block, as [name, value] pairs.
    def decode(block)
      s = block.b
      pos = 0
      out = []
      first = true
      while pos < s.bytesize
        b = s.getbyte(pos)
        if b & 0x80 != 0 # 6.1 indexed
          i, pos = MockHpack.integer(s, pos, 7)
          out << entry(i)
        elsif b & 0x40 != 0 # 6.2.1 with incremental indexing
          name, value, pos = literal(s, pos, 6)
          out << [name, value]
          add(name, value)
        elsif b & 0x20 != 0 # 6.3 dynamic table size update
          raise Error, "a table size update after a field" unless first

          size, pos = MockHpack.integer(s, pos, 5)
          raise Error, "table size #{size} above the announced #{@limit}" if size > @limit

          @max = size
          evict
          next
        else # 6.2.2 without indexing, 6.2.3 never indexed
          name, value, pos = literal(s, pos, 4)
          out << [name, value]
        end
        first = false
      end
      out
    end

    private

    def literal(s, pos, n)
      idx, pos = MockHpack.integer(s, pos, n)
      if idx.zero?
        name, pos = MockHpack.string(s, pos)
      else
        name = entry(idx)[0]
      end
      value, pos = MockHpack.string(s, pos)
      [name, value, pos]
    end

    def entry(i)
      raise Error, "index 0" if i.zero?
      return STATIC[i - 1] if i <= STATIC.size

      e = @table[i - STATIC.size - 1]
      raise Error, "index #{i} is past the dynamic table" if e.nil?

      e
    end

    def add(name, value)
      @table.unshift([name, value])
      @size += name.bytesize + value.bytesize + 32
      evict
    end

    def evict
      while @size > @max
        name, value = @table.pop
        @size -= name.bytesize + value.bytesize + 32
      end
    end
  end
end
