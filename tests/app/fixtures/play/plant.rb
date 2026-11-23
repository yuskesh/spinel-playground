# tests/app/fixtures/play/plant.rb -- a copy of a session image with one
# core_state slot set, for tests/app/play.sh's stops:
#
#   ruby tests/app/fixtures/play/plant.rb IMAGE OUT FIELD VALUE
#
# The slot's place is image.tsv's (a core_state row's offset), the value one
# little-endian i64, and image.sha256 is rewritten for the new writable.bin,
# so the planted image is read as any other.
require "digest"
require "fileutils"

src, out, field, value = ARGV
FileUtils.rm_rf(out)
FileUtils.cp_r(src, out)
row = File.readlines(File.join(out, "image.tsv")).map { |l| l.chomp.split("\t") }
          .find { |c| c[0] == field && c[4] == "core_state" } or abort("plant.rb: #{field} is no core_state slot of #{src}")
wf = File.join(out, "writable.bin")
w = File.binread(wf)
off = Integer(row[5], 10)
before = w.byteslice(off, 8)
w[off, 8] = [Integer(value, 10)].pack("q<")
abort("plant.rb: #{field} already holds #{value}") if before == w.byteslice(off, 8)
File.binwrite(wf, w)
sums = File.read(File.join(out, "image.sha256")).sub(/^\h{64}(  writable\.bin)$/) { "#{Digest::SHA256.file(wf).hexdigest}#{$1}" }
File.write(File.join(out, "image.sha256"), sums)
