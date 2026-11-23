# The layout reduced to the fields the SCHEMA initialises -- the stored ones.
# A prepared field's bytes are Full's, so comparing them against Full would be
# comparing Full with itself; what is checkable is that every cell the schema
# claims to initialise holds what the reference holds before the first tick.
#
#   ruby stored-layout.rb SCHEMA LAYOUT_IN LAYOUT_OUT [only] [EXCLUDE_FILE]
#
# `only` is `stored` (the default) or `prepared`. EXCLUDE_FILE is one field
# name per line, dropped from the result -- used to leave out the fields the
# reference encoder REFUSED and the ones it could not reach, whose bytes on
# the reference side are the schema's initial rather than the original's.
# Comparing those would compare the schema with itself.
schema, layout_in, layout_out, only, exclude_path = ARGV
only ||= "stored"
%w[stored prepared].include?(only) or abort("stored-layout: unknown subset #{only.inspect}")
excluded = {}
if exclude_path && !exclude_path.empty? && File.exist?(exclude_path)
  File.foreach(exclude_path) { |ln| n = ln.strip; excluded[n] = true unless n.empty? }
end
stored = {}
File.foreach(schema) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  next if excluded[f[0]]
  prepared = f[4].start_with?("prepared:")
  stored[f[0]] = true if prepared == (only == "prepared")
end
rows = []
File.foreach(layout_in) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  rows << f if stored[f[0]]
end
off = 0
File.open(layout_out, "w") do |io|
  io.puts("# The stored subset of the canonical layout, re-offset.")
  io.puts("#field\telement\tcount\tbytes\toffset")
  rows.each do |f|
    io.puts([f[0], f[1], f[2], f[3], off].join("\t"))
    off += f[3].to_i
  end
  io.puts("#total\t-\t-\t#{off}\t-")
end
puts "stored fields #{rows.length} bytes #{off}"
