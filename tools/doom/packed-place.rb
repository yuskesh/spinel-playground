# frozen_string_literal: true
#
# tools/doom/packed-place.rb -- the maintained place of a packed line.
#
#   ruby tools/doom/packed-place.rb --map MAP --packed FILE --units DIR \
#     [--manifest PATH] < kernel.err > kernel.placed
#
# The kernel names the file pack-core wrote (`.../packed.rb:<line>:`). Each
# such place on stdin is rewritten through pack-core's map:
#
#   - a line inside a unit becomes that unit's file under --units and its
#     own line;
#   - `# spinel: int64` on line 1 (decision 0019, refused on a 32-bit target
#     unless tools/core/int64-allow.tsv lists the source) becomes the manifest
#     line that gives the entry its width, `--manifest` naming the manifest
#     as the reader knows it, and the line says which units declare int64
#     themselves.
#
# Anything else is copied unchanged. The map's comment lines `# width` and
# `# declares int64` are pack-core's record of where the declaration came
# from.
require "optparse"

opt = {}
OptionParser.new do |o|
  o.on("--map FILE") { |v| opt[:map] = v }
  o.on("--packed FILE") { |v| opt[:packed] = v }
  o.on("--units DIR") { |v| opt[:units] = v }
  o.on("--manifest PATH") { |v| opt[:manifest] = v }
end.parse!
%i[map packed units].each { |k| abort "packed-place: --#{k} is required" unless opt[k] }

rows = []
width_line = nil
declares = []
File.foreach(opt[:map], chomp: true) do |l|
  if (m = l.match(/\A# width\t[^\t]*\tint64\tmanifest line (\d+)\z/))
    width_line = m[1].to_i
  elsif (m = l.match(/\A# declares int64\t(.*)\z/))
    declares = m[1].split(",")
  elsif l =~ /\A(\d+)\t(\d+)\t([^\t]+)\t/
    rows << [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3)]
  end
end

name = File.basename(opt[:packed])
home = (File.realpath(File.dirname(opt[:packed])) rescue File.dirname(opt[:packed]))
unit = ->(path) { File.join(opt[:units], path) }

$stdin.each_line do |line|
  out = line.gsub(/(?<![\w\/.])((?:[^\s:]*\/)?)#{Regexp.escape(name)}:(\d+):/) do |m|
    prefix, n = Regexp.last_match(1), Regexp.last_match(2).to_i
    next m unless prefix.empty? || ((File.realpath(prefix) rescue nil) == home)
    if n == 1 && line.include?("int-width-int64-refused") && width_line && opt[:manifest]
      "#{opt[:manifest]}:#{width_line}:"
    elsif (row = rows.find { |s, e, _| s <= n && n <= e })
      "#{unit.(row[2])}:#{n - row[0] + 1}:"
    elsif n == 1 && !declares.empty?
      "#{unit.(declares.first)}:1:"
    else
      m
    end
  end
  if out != line && line.include?("int-width-int64-refused") && width_line && opt[:manifest]
    own = declares.map { |d| "#{unit.(d)}:1" }
    out = out.chomp + " (the manifest's `#width` line gives this entry int64" +
          (own.empty? ? ")" : "; #{own.join(', ')} declare#{own.size == 1 ? 's' : ''} it too)") + "\n"
  end
  $stdout.write(out)
end
