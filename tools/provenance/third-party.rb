# frozen_string_literal: true
#
# tools/provenance/third-party.rb -- THIRD_PARTY.md from docs/imports.tsv and
# the tracked files' SPDX lines.
#
#   ruby tools/provenance/third-party.rb [--root DIR] [--check]
#
# Writes THIRD_PARTY.md under --root (default: this checkout), or with
# --check compares it with what would be written and exits 1 when it differs.
# The file lists, by licence scope:
#
#   1. third-party files: every imports.tsv row whose licence names one
#      outside project and project-ported, with the licence files that
#      cover it (LICENSE*, COPYING* or LICENSES/ beside it or above it, as
#      tools/provenance/check-imports.rb requires);
#   2. this project's own files that declare a licence per file with an
#      SPDX line, by identifier and directory, with the LICENSES/<id> text;
#   3. the rows ported from the owner's earlier repositories, which stated
#      no licence; the owner put them under the project licence.
#
# The project's own licence, Apache-2.0 WITH LLVM-exception, is in LICENSE.
require "optparse"
require "set"

FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
SPDX = /SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)/
OWN = %w[project project-ported].freeze
LICENCE_FILE = /\A(?:LICENSE|COPYING)(?:[.-][^\/]*)?\z/i

opt = { root: File.expand_path("../..", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--check") { opt[:check] = true }
end.parse!
root = opt[:root]
out_path = File.join(root, "THIRD_PARTY.md")

rows = []
File.readlines(File.join(root, "docs/imports.tsv"), chomp: true).each do |l|
  next if l.empty? || l.start_with?("#", "@batch")
  g, batch, lic, note = l.split("\t", 4)
  rows << { glob: g, batch: batch, lic: lic.to_s, note: note.to_s, files: [] }
end
files = IO.popen(["git", "-C", root, "ls-files"], &:readlines).map(&:chomp)
files.each do |f|
  r = rows.find { |x| File.fnmatch?(x[:glob], f, FLAGS) } or next
  r[:files] << f
end

licence_file = ->(f) { File.basename(f).match?(LICENCE_FILE) || f.split("/")[0..-2].include?("LICENSES") }
licences = files.select { |f| licence_file.(f) }
by_dir = licences.group_by { |f| File.dirname(f) }
lic_dir = ->(d) { licences.select { |f| f.split("/")[0..-2].include?("LICENSES") && f.start_with?("#{d}/LICENSES/") } }
dirs_up = ->(f) { d = File.dirname(f); out = []; (out << d; d = File.dirname(d)) until d == "." || d == "/"; out }

# The licence files that cover a row: for each file, the nearest directory
# (its own or above, not the top) that holds one; a licence file covers itself.
covering = lambda do |r|
  r[:files].flat_map do |f|
    next [f] if licence_file.(f)
    d = dirs_up.(f).find { |x| by_dir.key?(x) }
    d ? by_dir[d] : []
  end.uniq.sort
end

md = ->(s) { s.gsub("|", "\\|") }
lines = []
lines << "# Third-party code and licences"
lines << ""
lines << "Generated from [`docs/imports.tsv`](docs/imports.tsv) and the files' SPDX lines by"
lines << "`tools/provenance/third-party.rb`; do not edit by hand."
lines << ""
lines << "The project's own licence is Apache-2.0 WITH LLVM-exception: see"
lines << "[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). It covers every file except"
lines << "those listed in sections 1 and 2, which keep the licence named here."
lines << "Section 3 lists files the project licence covers although they were"
lines << "ported from elsewhere."
lines << ""
lines << "## 1. Third-party files"
lines << ""
lines << "Each directory or file keeps its original licence; the licence text sits"
lines << "beside it or in a directory above it."
lines << ""
lines << "| files | licence | licence text | note |"
lines << "| --- | --- | --- | --- |"
# A row of the project's own that holds only licence texts (tools/ebpf/LICENSES)
# is section 2's text column, not third-party code.
own_texts = ->(r) { r[:batch] == "original" && r[:files].all? { |f| licence_file.(f) } }
rows.select { |r| (r[:lic].split("+") - OWN).any? && !r[:files].empty? && !own_texts.(r) }.each do |r|
  cov = covering.(r)
  text = cov.empty? ? "(in the linked repository)" : cov.map { |c| "`#{c}`" }.join(", ")
  lines << "| `#{md.(r[:glob])}` | #{r[:lic]} | #{text} | #{md.(r[:note])} |"
end
lines << ""
lines << "## 2. This project's files with a per-file licence"
lines << ""
lines << "These files are the project's own and state their licence in an"
lines << "`SPDX-License-Identifier` line; the text is in the `LICENSES/` named. That"
lines << "licence is settled: section 3 does not reopen it, though the same globs"
lines << "appear there."
lines << ""
lines << "| licence | directory | licence text |"
lines << "| --- | --- | --- |"
spdx = Hash.new { |h, k| h[k] = [] }
rows.select { |r| (r[:lic].split("+") - OWN).empty? }.each do |r|
  r[:files].each do |f|
    path = File.join(root, f)
    next if licence_file.(f) || !File.file?(path)
    id = File.binread(path, 65_536).to_s[SPDX, 1] or next
    top = f.split("/")[0, 2].join("/")
    spdx[[id, top]] << f
  end
end
spdx.sort.each do |(id, top), fs|
  text = (dirs_up.(fs[0]) + ["."]).map { |d| d == "." ? "LICENSES/#{id}" : "#{d}/LICENSES/#{id}" }.find { |p| files.include?(p) }
  lines << "| #{id} | `#{top}` | #{text ? "`#{text}`" : '(missing)'} |"
end
lines << ""
lines << "## 3. Ported from the owner's earlier repositories"
lines << ""
lines << "These came from the project owner's earlier repositories, which stated no"
lines << "licence. The owner put them under the project licence on 2026-11-20, except"
lines << "for the files with an SPDX line, which keep it and which section 2 lists."
lines << ""
lines << "| files | note |"
lines << "| --- | --- |"
rows.select { |r| r[:lic].split("+").include?("project-ported") && !r[:files].empty? }.each do |r|
  lines << "| `#{md.(r[:glob])}` | #{md.(r[:note])} |"
end
text = lines.join("\n") + "\n"

if opt[:check]
  same = File.file?(out_path) && File.read(out_path) == text
  puts "third-party: THIRD_PARTY.md #{same ? 'is current' : 'differs from what docs/imports.tsv gives; run tools/provenance/third-party.rb'}"
  exit(same ? 0 : 1)
end
File.write(out_path, text)
puts "third-party: wrote THIRD_PARTY.md (#{lines.size} lines)"
