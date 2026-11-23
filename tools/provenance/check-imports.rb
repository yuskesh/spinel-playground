# frozen_string_literal: true
#
# tools/provenance/check-imports.rb -- every tracked file under exactly one row
# of docs/imports.tsv.
#
#   ruby tools/provenance/check-imports.rb [--root DIR] [--register FILE]
#        [--provenance FILE] [--files LIST]
#
# The register's format is in its own header. The files are `git ls-files`
# in --root (default: this checkout), or the paths in LIST, one a line; the
# register and the provenance record default to docs/imports.tsv and
# docs/provenance.md under --root.
#
# Each failure is one line naming its kind:
#
#   unregistered    a file under no row
#   overlap         a file under two or more rows
#   empty row       a row no file is under
#   unknown batch   a batch no @batch line declares
#   no section      an @batch heading docs/provenance.md does not have
#   unknown license a licence word outside the vocabulary
#   SPDX mismatch   a file whose SPDX-License-Identifier the row's licence
#                   does not name (a project-ported row only counts them: the
#                   source states no licence, so the file's line is the only
#                   statement there is)
#   licence text    a file of a third-party row (a licence other than
#                   project and project-ported) with no licence file
#                   beside it or in a directory above it, or a file of the
#                   project's own whose SPDX line has no LICENSES/<id> above
#                   it (the top level counts for LICENSES/<id> only); a
#                   licence file is LICENSE*, COPYING* or a file under
#                   LICENSES/, and covers itself
#   game data       a file that starts with an IWAD or PWAD header, or is
#                   named *.wad in any case
#   GPL binary      a file that is not text (a NUL byte anywhere in it) in
#                   a GPL row, with a GPL SPDX line, or below a LICENSE or
#                   COPYING that is the GPL: those ship as source only
#
# The summary gives the files per licence and the SPDX lines per licence.
# Exit 0 when nothing failed, 1 when something did, 2 on a usage error.
require "optparse"
require "set"

LICENSES = %w[MIT Apache-2.0 GPL-2.0 GPL-3.0 LGPL-2.1 LGPL-3.0 BSD-2-Clause BSD-3-Clause ISC zlib Unicode-3.0 project project-ported].freeze
FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
SPDX = /SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)/
OWN = %w[project project-ported].freeze
LICENCE_FILE = /\A(?:LICENSE|COPYING)(?:[.-][^\/]*)?\z/i

opt = { root: File.expand_path("../..", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--register FILE") { |v| opt[:register] = v }
  o.on("--provenance FILE") { |v| opt[:provenance] = v }
  o.on("--files LIST") { |v| opt[:files] = v }
end.parse!
root = opt[:root]
register = opt[:register] || File.join(root, "docs/imports.tsv")
provenance = opt[:provenance] || File.join(root, "docs/provenance.md")
[register, provenance].each { |f| File.file?(f) or abort("check-imports: no #{f}") }

fail_lines = []
failed = ->(kind, msg) { fail_lines << "#{kind}: #{msg}" }

headings = File.readlines(provenance, chomp: true).filter_map { |l| l[/\A#+\s+(.*)\z/, 1] }.to_set
batches = { "original" => nil }
rows = []
File.readlines(register, chomp: true).each_with_index do |l, i|
  next if l.empty? || l.start_with?("#")
  at = "#{File.basename(register)}:#{i + 1}"
  f = l.split("\t")
  if f[0] == "@batch"
    batches[f[1]] = f[2]
    failed.("no section", "#{at}: batch #{f[1]}: docs/provenance.md has no heading '#{f[2]}'") unless headings.include?(f[2])
    next
  end
  rows << { at: at, glob: f[0], batch: f[1].to_s, lic: f[2].to_s, hits: 0 }
end
rows.each do |r|
  r[:batch].split("+").each { |b| failed.("unknown batch", "#{r[:at]}: #{b}") unless batches.key?(b) }
  r[:lic].split("+").each { |x| failed.("unknown license", "#{r[:at]}: #{x}") unless LICENSES.include?(x) }
end

files = if opt[:files]
          File.readlines(opt[:files], chomp: true).reject(&:empty?)
        else
          IO.popen(["git", "-C", root, "ls-files"], &:readlines).map(&:chomp)
        end

tracked = files.to_set
licence_file = ->(f) { File.basename(f).match?(LICENCE_FILE) || f.split("/")[0..-2].include?("LICENSES") }
# The directories from f's own up to, not including, the root: a
# third-party licence sits with its files, never only at the top. An SPDX
# text (LICENSES/<id>) may also sit at the top.
dirs_up = ->(f) { d = File.dirname(f); out = []; (out << d; d = File.dirname(d)) until d == "." || d == "/"; out }
licence_dirs = files.select { |f| licence_file.(f) }.map { |f| File.dirname(f) }.to_set
spdx_texts = files.filter_map { |f| f if File.dirname(f).end_with?("/LICENSES") || File.dirname(f) == "LICENSES" }.to_set
# The directories whose LICENSE or COPYING beside the files is a GPL text:
# everything below them ships as source only, whatever its own row says.
gpl_dirs = files.select { |f| File.basename(f).match?(LICENCE_FILE) }.filter_map do |f|
  path = File.join(root, f)
  File.dirname(f) if File.file?(path) && File.binread(path, 4096).to_s.include?("GNU GENERAL PUBLIC LICENSE")
end.to_set
# A NUL byte anywhere in the file, read in blocks.
nul = lambda do |path|
  File.open(path, "rb") { |io| while (b = io.read(1 << 20)); return true if b.include?("\0"); end }
  false
end
per_license = Hash.new(0)
spdx = Hash.new(0)
files.each do |f|
  hit = rows.select { |r| File.fnmatch?(r[:glob], f, FLAGS) }
  hit.each { |r| r[:hits] += 1 }
  if hit.empty?
    failed.("unregistered", f)
    next
  elsif hit.size > 1
    failed.("overlap", "#{f}: #{hit.map { |r| r[:at] }.join(', ')}")
    next
  end
  r = hit[0]
  per_license[r[:lic]] += 1
  path = File.join(root, f)
  next unless File.file?(path)
  head = File.binread(path, 65_536).to_s
  failed.("game data", "#{f}: an IWAD or PWAD header or a .wad name") if head.start_with?("IWAD", "PWAD") || f.match?(/\.wad\z/i)
  lics = r[:lic].split("+")
  stated = head[SPDX, 1]
  # GPL scope: the row's licence, the file's own SPDX line, or a GPL licence
  # text beside it or above it; a licence text itself is not checked
  why = if lics.any? { |x| x.start_with?("GPL") } then "#{r[:at]} says #{r[:lic]}"
        elsif stated&.start_with?("GPL") then "its SPDX line says #{stated}"
        elsif (d = dirs_up.(f).find { |x| gpl_dirs.include?(x) }) then "it is under #{d}/, whose licence is the GPL"
        end
  if why && !licence_file.(f) && nul.(path)
    failed.("GPL binary", "#{f}: #{why}, which ships as source only")
  end
  if (lics - OWN).any? && !licence_file.(f) && dirs_up.(f).none? { |d| licence_dirs.include?(d) }
    failed.("licence text", "#{f}: #{r[:at]} says #{r[:lic]}, and no licence file is beside it or above it")
  end
  next unless stated
  if (lics - OWN).empty? && !licence_file.(f) && (dirs_up.(f) + ["."]).none? { |d| spdx_texts.include?(d == "." ? "LICENSES/#{stated}" : "#{d}/LICENSES/#{stated}") }
    failed.("licence text", "#{f}: its SPDX line says #{stated}, and no LICENSES/#{stated} is above it")
  end
  spdx["#{stated} in a #{r[:lic]} row"] += 1
  next if r[:lic] == "project-ported" || r[:lic].split("+").include?(stated)
  failed.("SPDX mismatch", "#{f}: the file says #{stated}, #{r[:at]} says #{r[:lic]}")
end
rows.select { |r| r[:hits].zero? }.each { |r| failed.("empty row", "#{r[:at]}: #{r[:glob]}") }

puts "check-imports: #{files.size} files, #{rows.size} rows, #{batches.size - 1} batches"
per_license.sort.each { |k, v| puts "  #{k}: #{v} files" }
spdx.sort.each { |k, v| puts "  SPDX #{k}: #{v} files" }
fail_lines.each { |m| puts "FAIL #{m}" }
puts "check-imports: #{fail_lines.empty? ? 'ok' : "#{fail_lines.size} failure(s)"}"
exit(fail_lines.empty? ? 0 : 1)
