# frozen_string_literal: true
#
# tools/doom/failure-site.rb -- where a DOOM entry's failed call stopped.
#
#   ruby tools/doom/failure-site.rb --build DIR [--units DIR] < output
#   ruby tools/doom/failure-site.rb --firmware DIR [--units DIR] < console
#
# A debugging aid for entries built with spinel-core-kernel --failure-sites:
# each entry's failing path stored its site's id, and the caller printed it.
#
#   --build DIR     host programs over tests/doom-core/harness/artifacts.sh's
#                   entries built with DC_FAILURE_SITES=1, whose adapters print
#                     spinel-core: <entry> answered <status> at failure site <id>
#                   and whose tables are DIR/stage/<entry>/sites.tsv beside the
#                   pack map DIR/stage/<entry>/map.tsv;
#   --firmware DIR  a spinel-core-app --failure-sites build, whose main prints
#                     SPC_FAILURE_SITE <entry> <status> <id>
#                   and whose tables are DIR/sites/<entry>.tsv, with
#                   DIR/sites/<entry>.map.tsv for an entry packed by pack-core
#                   (the session's DOOM entries); an application entry's table
#                   already names the application's own file and line.
#
# For each such line on stdin, this prints the site's maintained place:
# through the pack map (tools/doom/packed-place.rb) the CORE unit under
# --units and its own line. Site 0 is a refusal of the wrapper's own (its
# argument checks), which records no site. Other lines are not printed; the
# exit status is 1 when there was no such line.
require "open3"
require "optparse"
require "rbconfig"

ROOT = File.expand_path("../..", __dir__)
opt = { units: File.join(ROOT, "examples/doom/core/src") }
OptionParser.new do |o|
  o.on("--build DIR") { |v| opt[:build] = v }
  o.on("--firmware DIR") { |v| opt[:firmware] = v }
  o.on("--units DIR") { |v| opt[:units] = v }
end.parse!
abort "failure-site: one of --build and --firmware is required" unless opt[:build].nil? ^ opt[:firmware].nil?

# the site table and the pack map (nil when there is none) of an entry
tables = lambda do |entry|
  if opt[:build]
    stage = File.join(opt[:build], "stage", entry)
    [File.join(stage, "sites.tsv"), File.join(stage, "map.tsv")]
  else
    map = File.join(opt[:firmware], "sites", "#{entry}.map.tsv")
    [File.join(opt[:firmware], "sites", "#{entry}.tsv"), File.exist?(map) ? map : nil]
  end
end

found = 0
$stdin.each_line do |l|
  l = l.scrub("?")
  m = l.match(/spinel-core: (\w+) answered (-?\d+) at failure site (\d+)/) ||
      l.match(/SPC_FAILURE_SITE (\w+) (-?\d+) (\d+)/) or next
  entry, status, id = m[1], m[2], m[3].to_i
  found += 1
  if id.zero?
    puts "#{entry}: status #{status}, no failure site (the wrapper's own argument checks)"
    next
  end
  sites, map = tables.(entry)
  File.exist?(sites) or abort "failure-site: no #{sites}; was #{entry} built with --failure-sites?"
  row = File.readlines(sites, chomp: true).map { |r| r.split("\t") }.find { |r| r[0] == id.to_s } or
    abort "failure-site: #{sites} has no site #{id}"
  _, file, line, column, kind, what = row
  place = "#{file}:#{line}: #{kind}: #{what}"
  if map
    placed, st = Open3.capture2(RbConfig.ruby, File.join(__dir__, "packed-place.rb"),
                                "--map", map, "--packed", file, "--units", opt[:units], stdin_data: "#{place}\n")
    abort "failure-site: packed-place.rb failed" unless st.success?
    place = placed.chomp
  end
  puts "#{entry}: #{place} (failure site #{id}, column #{column})"
end
exit(found.zero? ? 1 : 0)
