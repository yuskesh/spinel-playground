#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tests/doom/oracle/make-fixture.rb — build a synthetic reference directory in
# the C oracle's column layout, from the Ruby port's own output.
#
#   make-fixture.rb <candidate-dir> <out-dir>
#
# **This is not an oracle and must never be used as one.**  It re-lays the
# candidate's own numbers into the reference's shape, so a comparison against it
# is a test OF THE COMPARATOR, not of DOOM.  Its purpose is to let
# tests/doom/compare-controls.sh prove that the comparator rejects a deleted
# frame, a duplicated frame, a changed row and so on, on a host that has no C
# reference implementation.  Debian is such a host: the reference harness needs
# CommonCrypto and a Mac-specific Makefile.
#
# What it reproduces from the reference's shape, because the comparator depends
# on all of it:
#
#   rand.tsv    seq kind gametic leveltime idx_before idx_after value site
#               `kind` is P or M and the comparator keeps only P; `site` is a
#               `file:line` string, so the numeric site is mapped back through
#               the inverse of the comparator's SITE_MAP.
#   frames.tsv  frame gametic fnv1a64 viewhash sha256 -- the header
#               doom/reference/e052_dump_hooks.patch emits.  `frame` is
#               `s_frameno++`, one per dump call, so it is the record identity;
#               `gametic` is whatever the engine's counter then held, so it
#               REPEATS whenever D_Display ran more than once for a tic.  The
#               fixture reproduces both: the 41-frame melt wipe on gametic 2,
#               and -- because a wipe is not the only case and a comparator that
#               only tolerated the wipe would be wrong -- a mid-run gametic
#               carrying two frames, of which the second is the settled screen.
#               `sha256` is "-", which is what the reference writes when it was
#               built without CommonCrypto.
#   player.tsv  copied: the comparator compares these rows field for field.
#   mobjs.tsv   copied, for the same reason.

require_relative "../compare"

INV_SITE = SITE_MAP.invert.freeze

def read_rows(path)
  header = nil
  rows = []
  File.binread(path).force_encoding("UTF-8").gsub(/\r\n?/, "\n").split("\n", -1).each do |line|
    next if line.empty?

    if line.start_with?("#")
      header ||= line[1..].split("\t", -1)
      next
    end
    rows << line.split("\t", -1)
  end
  [header, rows]
end

def write_tsv(path, header, rows)
  File.binwrite(path, "##{header.join("\t")}\n" + rows.map { |r| r.join("\t") }.join("\n") + "\n")
end

def main(argv)
  cand, out = argv
  abort "usage: make-fixture.rb <candidate-dir> <out-dir>" if cand.nil? || out.nil?

  require "fileutils"
  FileUtils.mkdir_p(out)

  # rand: candidate seq gametic idx_before idx_after value site
  _h, rows = read_rows(File.join(cand, "rand.tsv"))
  ref = rows.map do |r|
    site = INV_SITE[Integer(r[5], 10)] || "unmapped.c:#{r[5]}"
    # leveltime is gametic+1 in the reference's own dump; the comparator does
    # not read that column, and it is filled in rather than left blank so the
    # row width matches the header.
    [r[0], "P", r[1], (Integer(r[1], 10) + 1).to_s, r[2], r[3], r[4], site]
  end
  write_tsv(File.join(out, "rand.tsv"),
            %w[seq kind gametic leveltime before after value site], ref)

  # frames: candidate `gametic viewhash fullhash` -> reference
  # `frame gametic fnv1a64 viewhash sha256`, shifted by one gametic, with the
  # melt wipe on gametic 2 and one mid-run gametic deliberately carrying two
  # frames.  MULTI_AT is a candidate tic; set it to -1 to omit that case.
  multi_at = (ENV["MULTI_AT"] || "149").to_i
  _h, rows = read_rows(File.join(cand, "frames.tsv"))
  fr = []
  n = 0
  41.times { fr << [(n += 1).to_s, "2", format("%016x", n), format("%016x", n ^ 0xff), "-"] }
  rows.each do |r|
    t = Integer(r[0], 10)
    g = t + 1
    # The reference renders no level frame for gametics 1 and 2: the title
    # screen is up and the wipe is running.  Those are exactly the candidate
    # tics the comparator excludes, so the fixture must not invent rows for
    # them -- inventing them would hide whether the exclusion is bounded.
    next if g < 3

    if t == multi_at
      # An earlier draw for the same tic that the port never renders: the
      # comparator must accept the gametic on the strength of the settled
      # frame, not reject it for having two.
      n += 1
      fr << [n.to_s, g.to_s, format("%016x", 0xA5A5 ^ n), format("%016x", 0x5A5A ^ n), "-"]
    end
    fr << [(n += 1).to_s, g.to_s, r[2], r[1], "-"]
  end
  write_tsv(File.join(out, "frames.tsv"),
            %w[frame gametic fnv1a64 viewhash sha256], fr)

  %w[player.tsv mobjs.tsv].each do |name|
    h, rows = read_rows(File.join(cand, name))
    write_tsv(File.join(out, name), h, rows)
  end

  puts "make-fixture: wrote a synthetic reference into #{out} (NOT an oracle)"
end

main(ARGV) if $PROGRAM_NAME == __FILE__
