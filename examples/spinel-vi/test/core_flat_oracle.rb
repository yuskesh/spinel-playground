# Independent flat-string oracle for E101. Run with CRuby only.
def digest(text)
  h = 1469598103934665603
  i = 0
  while i < text.bytesize
    h = ((h ^ text.getbyte(i)) * 1099511628211) & 0xffffffffffffffff
    i += 1
  end
  lines = 1
  i = 0
  while i < text.bytesize
    lines += 1 if text.getbyte(i) == 10
    i += 1
  end
  [text.bytesize, h, lines]
end

# Independent line-start oracle: hash every byte offset that begins a logical
# line, including 0 and the empty line after a trailing LF.
def line_starts_digest(text)
  h = 1469598103934665603
  count = 1
  h = ((h ^ 0) * 1099511628211) & 0xffffffffffffffff
  i = 0
  while i < text.bytesize
    if text.getbyte(i) == 10
      count += 1
      h = ((h ^ (i + 1)) * 1099511628211) & 0xffffffffffffffff
    end
    i += 1
  end
  [count, h]
end

SEEDS = [1, 17, 49374]
INITIALS = ["", "one\ntwo\n", "abcd\x00\n\x00ef"]
si = 0
while si < SEEDS.length
  seed = SEEDS[si]
  text = INITIALS[si]
  state = seed
  step = 0
  cursor = 0
  while step < 160
    state = (state * 1103515245 + 12345) & 0x7fffffff
    if state % 4 == 0 || text.bytesize == 0
      pos = state % (text.bytesize + 1)
      payloads = ["", "A", "xy", "\n", "\x00Z", "q\nR"]
      bytes = payloads[(state >> 8) % payloads.length]
      text = text.byteslice(0, pos).to_s + bytes + text.byteslice(pos, text.bytesize - pos).to_s
      cursor = pos + bytes.bytesize
    else
      pos = state % text.bytesize
      count = 1 + ((state >> 7) % (text.bytesize - pos))
      text = text.byteslice(0, pos).to_s + text.byteslice(pos + count, text.bytesize - pos - count).to_s
      cursor = pos if cursor > pos
      cursor = pos if cursor > pos + count
    end
    cursor = text.bytesize if cursor > text.bytesize
    line = 0
    i = 0
    while i < cursor
      line += 1 if text.getbyte(i) == 10
      i += 1
    end
    line_start = cursor
    while line_start > 0 && text.getbyte(line_start - 1) != 10
      line_start -= 1
    end
    d = digest(text)
    starts = line_starts_digest(text)
    puts "#{seed},#{step},#{d[0]},#{d[1]},#{d[2]},#{cursor},#{line},#{cursor - line_start},#{starts[0]},#{starts[1]}"
    step += 1
  end
  si += 1
end
