# frozen_string_literal: true
#
# tests/doom-core/slice-snapshot.rb — cut the named fields out of a full
# snapshot, in the reduced layout's order.
#
#   ruby tests/doom-core/slice-snapshot.rb FULL_LAYOUT SUB_LAYOUT SRC DST
#
# THE SOURCE IS CHECKED BEFORE IT IS PROJECTED. This used to read offsets out
# of the full layout and copy, which asks nothing at all about the file it is
# copying from: Mac review appended ONE BYTE to a full snapshot and the
# projection, the comparator and the whole lane downstream were unmoved,
# because every byte the projection reads is at an offset below the end. A
# projection cannot tell you about the part it does not look at, so the length
# is checked here, where the whole file is still in view.
PROG = File.basename(__FILE__)
abort("usage: #{PROG} FULL_LAYOUT SUB_LAYOUT SRC DST") unless ARGV.length == 4
full_layout, sub_layout, src, dst = ARGV

def rows(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }
      .map { |l| l.chomp.split("\t", -1) }
end

at = {}
order = []
rows(full_layout).each do |f|
  at.key?(f[0]) and abort("#{PROG}: #{full_layout}: #{f[0]} is described twice")
  at[f[0]] = [Integer(f[4], 10), Integer(f[3], 10)]
  order << f[0]
end
at.empty? and abort("#{PROG}: #{full_layout} describes no field")

# THE OFFSETS ARE THE RUNNING SUM, which is the invariant `compare-state.rb`
# already checks and the one this file needed. Comparing the summed lengths
# with the end does NOT catch a gap and an overlap that cancel: Mac review's
# three two-byte fields at 0, 1 and 4 sum to six and end at six, while the
# second overlaps the first and two bytes in the middle belong to nothing. That
# layout projected `abbcef` out of `abcdef` and exited 0.
#
# Read in the file's own order, because that order is the snapshot's order: a
# layout that is contiguous only after sorting is not the layout the bytes were
# written in.
running = 0
order.each do |nm|
  o, n = at[nm]
  o == running or
    abort("#{PROG}: #{full_layout}: #{nm} begins at #{o} and the fields before it " \
          "end at #{running}")
  running += n
end
described = running
size = File.size(src)
size == described or
  abort("#{PROG}: #{src} is #{size} byte(s) and #{full_layout} describes #{described}")

bytes = File.binread(src)
out = +"".b
rows(sub_layout).each do |f|
  o, n = at[f[0]]
  o or abort("#{PROG}: #{sub_layout} names #{f[0]}, which #{full_layout} does not describe")
  # The sub layout carries its own length, and a projection that took a
  # different number of bytes than the field is declared to have would produce
  # a file the comparator reads with everything after it shifted.
  want = Integer(f[3], 10)
  want == n or
    abort("#{PROG}: #{f[0]} is #{n} byte(s) in #{full_layout} and #{want} in #{sub_layout}")
  slice = bytes.byteslice(o, n)
  slice && slice.bytesize == n or
    abort("#{PROG}: #{f[0]} wants #{n} byte(s) at #{o} and #{src} has #{size}")
  out << slice
end
File.binwrite(dst, out)
