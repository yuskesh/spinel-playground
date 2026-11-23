# frozen_string_literal: true
#
# tools/app/lib/core_app/console.rb -- the console byte stream of a
# verification run, demultiplexed (decision 0014 §10, Task 11). The UART
# carries three things: printk text lines, the transport's frames (0xA5,
# channel, length, payload; the application's channels), and the trace
# frames the transport drains from the recorder's rings (channel 0xFE). The
# parser reads from the start, so it is in sync: a 0xA5 outside a frame
# begins one, and a payload byte that happens to be 0xA5 is inside its
# frame's length. Text between frames is kept as lines (the banner, the
# SPC_CYCLES figures, SPC_END).
module CoreApp
  module Console
    TRACE_CHANNEL = 0xFE
    SOF = 0xA5

    Result = Struct.new(:lines, :frames, :trace, :truncated, keyword_init: true)

    # `bytes` is the whole console capture. Returns the text lines, the
    # application frames as [channel, payload bytes], the trace bytes
    # (concatenated 0xFE payloads), and whether the capture ended inside a
    # frame.
    def self.parse(bytes)
      b = bytes.b
      lines = []
      frames = []
      trace = +"".b
      text = +"".b
      i = 0
      truncated = false
      while i < b.bytesize
        c = b.getbyte(i)
        if c == SOF
          if i + 3 > b.bytesize
            truncated = true
            break
          end
          ch = b.getbyte(i + 1)
          len = b.getbyte(i + 2)
          if i + 3 + len > b.bytesize
            truncated = true
            break
          end
          payload = b[i + 3, len]
          if ch == TRACE_CHANNEL
            trace << payload
          else
            frames << [ch, payload.bytes]
          end
          i += 3 + len
        else
          if c == 0x0A
            lines << text.dup.force_encoding("UTF-8").scrub.delete("\r")
            text = +"".b
          else
            text << c.chr
          end
          i += 1
        end
      end
      lines << text.dup.force_encoding("UTF-8").scrub.delete("\r") unless text.empty?
      Result.new(lines: lines, frames: frames, trace: trace, truncated: truncated)
    end

    # The SPC_CYCLES and SPC_END lines as data.
    def self.figures(lines)
      cycles = lines.filter_map do |l|
        next unless l.start_with?("SPC_CYCLES ")
        h = l.split(" ")[1..].to_h { |kv| k, v = kv.split("=", 2); [k, k == "entry" ? v : Integer(v)] }
        h
      end
      stacks = lines.filter_map do |l|
        next unless l.start_with?("SPC_STACK ")
        l.split(" ")[1..].to_h { |kv| k, v = kv.split("=", 2); [k, k == "name" ? v : Integer(v)] }
      end
      endl = lines.find { |l| l.start_with?("SPC_END") }
      dropped = endl && endl[/dropped=(\d+)/, 1]&.to_i
      passes = endl && endl[/transport_passes=(\d+)/, 1]&.to_i
      unregistered = endl && endl[/unregistered=(\d+)/, 1]&.to_i
      { cycles: cycles, stacks: stacks, ended: !endl.nil?, dropped: dropped, unregistered: unregistered, transport_passes: passes }
    end
  end
end
