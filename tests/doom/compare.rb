#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tests/doom/compare.rb — compare the Ruby port's staged-oracle output against
# the C reference implementation's, keyed on gametic.
#
#   compare.rb --reference DIR --candidate DIR --ntics N [--allowances FILE]
#
# Adapted from the predecessor's doom/tools/cmp_e052.rb and doom/tools/gates/l6.rb
# (read-only, revision recorded in docs/provenance.md).  Both are preserved
# where they encode something the reference's own dump hook determines:
#
#   * the SITE_MAP from reference `file:line` to the port's site numbers.  The
#     random table is a single stream, so a wrong call site with the right
#     consumption count produces identical values and indices.  Without this
#     map that class of divergence is invisible; the predecessor hit it.
#   * the frame key offset.  `D_DoomLoop` runs `G_Ticker(); gametic++;
#     D_Display();`, so the screen produced by tic N is recorded under
#     gametic N+1.
#   * **a gametic may carry several reference frames, and that is correct.**
#     `E052_Frame` (doom/reference/e052_dump_hooks.patch) writes one row per
#     call with `s_frameno++` as the first column and whatever `gametic` then
#     holds as the second:
#
#         fprintf(s_frame, "%ld\t%d\t%016llx\t%016llx\t%s\n",
#                 s_frameno++, gametic, fh, vh, sha_hex);
#
#     So `frame` is the RECORD IDENTITY -- unique and strictly increasing --
#     and `gametic` is a grouping key that repeats whenever `D_Display` runs
#     more than once for one tic.  The title-screen melt wipe is the obvious
#     case and not the only one.  Requiring a unique gametic would reject
#     correct reference output; the rule is one row per *frame*, one or more
#     frames per *gametic*, and the port's single frame for a tic must match
#     one of the reference frames recorded for that gametic.  That last part is
#     `l6.rb`'s `byt[g].include?(x[bcol])` and it is kept.
#
# Reference header, from the same patch:
#   #frame  gametic  fnv1a64  viewhash  sha256
# The port's:
#   #gametic  viewhash  fullhash
# `sha256` is "-" unless the reference was built with CommonCrypto, which is
# why the oracle run is macOS-only; this comparator does not read that column.
#
# What this adds over the predecessor's pair, because decision 0006 task 3 asks
# for it:
#
#   1. STRUCTURE IS VALIDATED BEFORE ANY VALUE IS COMPARED, with a key defined
#      separately for each side: the reference's record identity (`frame`,
#      unique and increasing) and its grouping key (`gametic`, non-decreasing);
#      the candidate's `gametic` (unique, increasing, contiguous).  `cmp_e052.rb`
#      compares `min(a.size, b.size)` rows and mentions a count difference
#      afterwards, which lets a truncated reference agree for the rows that
#      exist.
#   2. THE COMPARISON COUNT IS ITSELF CHECKED.  The only tics excluded are the
#      ones whose reference frame does not exist -- candidate tics 0 and 1, whose
#      gametics 1 and 2 precede the first rendered level frame -- and the
#      comparator requires the excluded set to be exactly those.  Passing by
#      comparing fewer tics is therefore not available to it.
#   3. FAILURE IS AN EXIT STATUS *AND* A REASON.  `l6.rb` does exit non-zero, so
#      the gate had a verdict; `cmp_e052.rb`, the diagnostic tool this is mostly
#      adapted from, returns a message and always exits 0.  This merges the two
#      roles, so the thing that explains a divergence is the same thing that
#      fails on it.
#
# Known discrepancies are declared in an allowances file, never widened
# silently.  An allowance that does not fire is reported too: an expected
# difference that disappeared is a change, and changes are for investigation.

require "set"

# The first gametic whose frame the reference records for the level.  Candidate
# tics 0 and 1 map to gametics 1 and 2, which the reference spends on the title
# screen and the melt wipe into it.  This is a bound, not a filter: EXCLUDED_TICS
# is exactly the set the comparator is allowed to skip, and it verifies that the
# set it actually skipped is that one.
START_GAMETIC = 3
EXCLUDED_CANDIDATE_TICS = [0, 1].freeze

SITE_MAP = {
  "p_mobj.c:532" => 1, "p_mobj.c:827" => 2,
  "p_lights.c:99" => 3, "p_lights.c:104" => 4,
  "p_lights.c:135" => 5, "p_lights.c:199" => 6,
  "p_enemy.c:625" => 7, "p_enemy.c:630" => 8,
  "p_enemy.c:344" => 9, "p_enemy.c:396" => 10, "p_enemy.c:438" => 11,
  "p_enemy.c:757" => 12, "p_enemy.c:245" => 13,
  "p_lights.c:44" => 14,
  "p_mobj.c:858" => 15, "p_mobj.c:862" => 16,
  "p_mobj.c:886" => 17, "p_mobj.c:889" => 18,
  "p_mobj.c:909" => 19,
  "p_inter.c:898" => 20, "p_inter.c:724" => 46,
  "p_pspr.c:642" => 22, "p_pspr.c:646" => 23,
  "p_pspr.c:473" => 24, "p_pspr.c:475" => 25,
  "p_pspr.c:503" => 27,
  "p_enemy.c:801" => 29, "p_enemy.c:802" => 30,
  "p_enemy.c:824" => 31, "p_enemy.c:825" => 32,
  "p_inter.c:820" => 21,
}.freeze

class Failure < StandardError; end

# --report-all collects every divergence instead of stopping at the first, and
# prints them in allowance-file format for a human to review.  It NEVER writes a
# file and NEVER changes the exit status: a run with divergences fails whether
# or not they were listed.  Regenerating an allowance list from a failing run is
# how a real regression becomes a tolerated one, so the tool will hand over the
# text and no more.
$report_all = false
$collected = []

def read_text(path)
  # Read binary and normalise line endings ourselves: text mode would collapse
  # \r\n and \r silently, and a stray \r inside a field would then be invisible.
  File.binread(path).force_encoding("UTF-8").gsub(/\r\n?/, "\n")
end

def read_tsv(path, label)
  raise Failure, "#{label}: no such file: #{path}" unless File.exist?(path)

  raw = read_text(path)
  raise Failure, "#{label}: #{path} is empty" if raw.empty?

  header = nil
  rows = []
  raw.split("\n", -1).each do |line|
    next if line.empty?

    if line.start_with?("#")
      header ||= line[1..].split("\t", -1)
      next
    end
    rows << line.split("\t", -1)
  end
  raise Failure, "#{label}: #{path} has no header line" if header.nil?
  raise Failure, "#{label}: #{path} has a header but no data rows" if rows.empty?

  [header, rows]
end

def ival(str, label, what)
  Integer(str, 10)
rescue ArgumentError, TypeError
  raise Failure, "#{label}: #{what} is not an integer: #{str.inspect}"
end

# Structural validation, run before any value is compared.  Checks, in order:
# every key parses as an integer; keys are strictly increasing (ordering, which
# subsumes uniqueness); the covered range is contiguous with no gap (coverage);
# and the row count is the expected one (length).
def validate_keyed(rows, key_col, label, expect_lo, expect_hi)
  keys = rows.each_with_index.map { |r, i| ival(r[key_col], label, "key on row #{i}") }

  keys.each_cons(2).with_index do |(a, b), i|
    raise Failure, "#{label}: key #{a} repeats at row #{i + 1}" if a == b
    raise Failure, "#{label}: keys are not increasing: row #{i} is #{a}, row #{i + 1} is #{b}" if b < a
  end

  present = keys.to_set
  missing = (expect_lo..expect_hi).reject { |k| present.include?(k) }
  unless missing.empty?
    shown = missing.first(8).join(", ")
    more = missing.size > 8 ? ", … #{missing.size - 8} more" : ""
    raise Failure, "#{label}: #{missing.size} key(s) missing from #{expect_lo}..#{expect_hi}: #{shown}#{more}"
  end

  want = expect_hi - expect_lo + 1
  got = keys.count { |k| k >= expect_lo && k <= expect_hi }
  raise Failure, "#{label}: expected #{want} rows in #{expect_lo}..#{expect_hi}, found #{got}" if got != want

  keys
end

def validate_width(header, rows, label)
  rows.each_with_index do |r, i|
    next if r.size == header.size

    raise Failure, "#{label}: row #{i} has #{r.size} fields, the header declares #{header.size}"
  end
end

# An allowance does not excuse "this tic may differ".  It pins WHAT differs:
# the field, the value the reference is expected to hold and the value the
# candidate is expected to hold.  A different divergence at the same tic -- a
# different value in the same field, or a change in another field -- is a new
# defect and is rejected, which is the whole point: a tolerated difference is a
# recorded fact, not an exemption for the tic.
#
# File format, tab separated, `#` comments:
#
#   stream  gametic  field  reference-value  candidate-value  reason
#
# `field` is a column name for the row streams and the hash column for the frame
# streams.  For a wide row it may be `*`, in which case reference-value and
# candidate-value are the SHA-256 of the whole row as written, joined with tabs;
# the pinning is then over the entire row rather than field by field.
Allowance = Struct.new(:stream, :key, :field, :ref, :cand, :reason, :fired)

def read_allowances(path)
  return [] if path.nil?
  raise Failure, "allowances: no such file: #{path}" unless File.exist?(path)

  out = []
  read_text(path).split("\n", -1).each_with_index do |line, i|
    next if line.empty? || line.start_with?("#")

    f = line.split("\t", -1)
    if f.size != 6
      raise Failure, "allowances: line #{i + 1} has #{f.size} fields, want 6 " \
                     "(stream, gametic, field, reference value, candidate value, reason)"
    end
    raise Failure, "allowances: line #{i + 1} has an empty reason" if f[5].strip.empty?
    raise Failure, "allowances: line #{i + 1} has an empty field name" if f[2].empty?
    if f[3] == f[4]
      raise Failure, "allowances: line #{i + 1} declares the same value on both sides (#{f[3]}), " \
                     "which is not a difference"
    end

    out << Allowance.new(f[0], ival(f[1], "allowances", "gametic on line #{i + 1}"),
                         f[2], f[3], f[4], f[5], false)
  end

  dup = out.group_by { |a| [a.stream, a.key, a.field] }.find { |_k, v| v.size > 1 }
  raise Failure, "allowances: #{dup[0][0]}@#{dup[0][1]} declares field #{dup[0][2]} twice" if dup

  out
end

def row_digest(row)
  require "digest"
  Digest::SHA256.hexdigest(row.join("\t"))
end

# The observed difference, as a set of [field, reference value, candidate value],
# must equal the declared set exactly.  Not a subset: an undeclared field that
# also differs is a new defect, and a declared field that stopped differing is a
# change too.
def difference_allowed?(allowances, stream, key, observed)
  declared = allowances.select { |a| a.stream == stream && a.key == key }
  return false if declared.empty?

  want = declared.map { |a| [a.field, a.ref, a.cand] }.sort
  return false if want != observed.sort

  declared.each { |a| a.fired = true }
  true
end

# ---- the streams ----------------------------------------------------------

def compare_rand(refdir, canddir, ntics, _allow, report)
  label = "rand"
  rh, rr = read_tsv(File.join(refdir, "rand.tsv"), "#{label}/reference")
  ch, cr = read_tsv(File.join(canddir, "rand.tsv"), "#{label}/candidate")
  validate_width(rh, rr, "#{label}/reference")
  validate_width(ch, cr, "#{label}/candidate")

  # reference: seq kind gametic leveltime before after value site
  # candidate: seq gametic before after value site
  ref = rr.select { |x| x[1] == "P" }
          .map { |x| [ival(x[2], label, "gametic"), ival(x[4], label, "before"),
                      ival(x[5], label, "after"), ival(x[6], label, "value"), x[7]] }
          .select { |x| x[0] < ntics }
  cand = cr.map { |x| [ival(x[1], label, "gametic"), ival(x[2], label, "before"),
                       ival(x[3], label, "after"), ival(x[4], label, "value"),
                       ival(x[5], label, "site")] }
           .select { |x| x[0] < ntics }

  if ref.size != cand.size
    raise Failure, "#{label}: reference has #{ref.size} P_Random calls below tic #{ntics}, candidate has #{cand.size}"
  end
  raise Failure, "#{label}: no P_Random calls below tic #{ntics}" if ref.empty?

  # The call sequence is an ordered stream, not a keyed one: its gametic column
  # must be non-decreasing, and that is what is checked here.
  ref.each_cons(2).with_index do |(a, b), i|
    raise Failure, "#{label}/reference: gametic goes backwards at call #{i + 1}: #{a[0]} then #{b[0]}" if b[0] < a[0]
  end

  ref.each_with_index do |r, i|
    c = cand[i]
    want_site = SITE_MAP[r[4]]
    site_bad = !want_site.nil? && want_site != c[4]
    next unless r[0, 4] != c[0, 4] || site_bad

    detail = if site_bad && r[0, 4] == c[0, 4]
               "same value and index, different call site: reference #{r[4]} (site #{want_site}), candidate site #{c[4]}"
             else
               "reference tic=#{r[0]} #{r[1]}->#{r[2]} v=#{r[3]} #{r[4]}, " \
                 "candidate tic=#{c[0]} #{c[1]}->#{c[2]} v=#{c[3]} site=#{c[4]}"
             end
    raise Failure, "#{label}: first mismatch at call #{i}: #{detail}"
  end

  report << "#{label}: OK (#{ref.size} P_Random calls identical, call sites checked)"
end

def compare_by_tic(refdir, canddir, name, ntics, allowances, report)
  label = name.sub(/\.tsv\z/, "")
  rh, rr = read_tsv(File.join(refdir, name), "#{label}/reference")
  ch, cr = read_tsv(File.join(canddir, name), "#{label}/candidate")
  validate_width(rh, rr, "#{label}/reference")
  validate_width(ch, cr, "#{label}/candidate")

  # mobjs.tsv carries several rows per tic (one per thinker), so its key is not
  # unique by construction; only the per-tic streams are validated as keyed.
  multi = rr.first.size > 2 && name == "mobjs.tsv"
  rsel = rr.select { |x| ival(x[0], label, "gametic") < ntics }
  csel = cr.select { |x| ival(x[0], label, "gametic") < ntics }
  raise Failure, "#{label}: reference has no rows below tic #{ntics}" if rsel.empty?

  unless multi
    # 0..ntics-1 on both sides: the requested range, not the observed one.
    hi = ntics - 1
    validate_keyed(rsel, 0, "#{label}/reference", 0, hi)
    validate_keyed(csel, 0, "#{label}/candidate", 0, hi)
  end

  if rsel.size != csel.size
    raise Failure, "#{label}: reference has #{rsel.size} rows below tic #{ntics}, candidate has #{csel.size}"
  end

  known = 0
  rsel.each_with_index do |r, i|
    c = csel[i]
    next if r == c

    key = ival(r[0], label, "gametic")
    bad = (0...[r.size, c.size].min).select { |k| r[k] != c[k] }
    bad |= (([r.size, c.size].min)...([r.size, c.size].max)).to_a if r.size != c.size
    observed = bad.map { |k|
      col = rh && k < rh.size ? rh[k] : k.to_s
      [col, r[k].to_s, c[k].to_s]
    }
    # A whole-row pin is offered for wide rows; it is checked first so that a
    # `*` declaration and a field list are not both required.
    whole = [["*", row_digest(r), row_digest(c)]]
    if difference_allowed?(allowances, label, key, whole) ||
       difference_allowed?(allowances, label, key, observed)
      known += 1
      next
    end

    det = observed.first(8).map { |col, rv, cv| "#{col}: reference=#{rv} candidate=#{cv}" }.join(", ")
    declared = allowances.select { |a| a.stream == label && a.key == key }
    extra = if declared.empty?
              ""
            else
              " (gametic #{key} has #{declared.size} declared discrepancy field(s) " \
                "#{declared.map(&:field).join(", ")}, and this difference is not it)"
            end
    raise Failure, "#{label}: first mismatch at row #{i} (gametic #{r[0]}): #{det}#{extra}"
  end

  suffix = known.zero? ? "" : ", #{known} declared discrepancy row(s)"
  report << "#{label}: OK (#{rsel.size} rows identical#{suffix})"
end

def compare_frames(refdir, canddir, ntics, allowances, report, full:)
  label = full ? "frames200" : "frames"
  rh, rr = read_tsv(File.join(refdir, "frames.tsv"), "#{label}/reference")
  ch, cr = read_tsv(File.join(canddir, "frames.tsv"), "#{label}/candidate")
  validate_width(rh, rr, "#{label}/reference")
  validate_width(ch, cr, "#{label}/candidate")

  rcol = full ? 2 : 3   # reference: fnv1a64 (all 200 rows) / viewhash (top 168)
  ccol = full ? 2 : 1   # candidate: fullhash / viewhash
  rr.each_with_index do |x, i|
    raise Failure, "#{label}/reference: row #{i} has no column #{rcol}" if x.size <= rcol
  end
  cr.each_with_index do |x, i|
    raise Failure, "#{label}/candidate: row #{i} has no column #{ccol}" if x.size <= ccol
  end

  # --- the reference's own two keys, validated separately -------------------
  #
  # Record identity is the FRAME number: E052_Frame writes s_frameno++ once per
  # call.  It must be unique and strictly increasing.
  #
  # The gametic is a GROUPING key: D_Display can run more than once for a tic,
  # so several frames legitimately share one gametic.  It must be
  # non-decreasing, and it must not be unique -- demanding uniqueness here would
  # reject correct reference output, which is the whole reason these are two
  # separate rules rather than one.
  frames = rr.each_with_index.map do |x, i|
    [ival(x[0], "#{label}/reference", "frame id on row #{i}"),
     ival(x[1], "#{label}/reference", "gametic on row #{i}"),
     x[rcol]]
  end

  # s_frameno++ advances once per dump, so the ids are contiguous.  A gap means
  # rows were lost between two writes -- a truncated or interleaved file that
  # still looks ordered and still has unique ids.
  idgaps = frames.each_cons(2).select { |a, b| b[0] > a[0] + 1 }
  unless idgaps.empty?
    a, b = idgaps.first
    raise Failure, "#{label}/reference: frame ids jump from #{a[0]} to #{b[0]} " \
                   "(#{idgaps.size} gap(s) in the frame sequence)"
  end

  frames.each_cons(2).with_index do |(a, b), i|
    if a[0] == b[0]
      raise Failure, "#{label}/reference: frame id #{a[0]} appears twice (rows #{i} and #{i + 1}) -- " \
                     "the frame number is the record identity and must be unique"
    end
    if b[0] < a[0]
      raise Failure, "#{label}/reference: frame ids are not increasing: row #{i} is #{a[0]}, row #{i + 1} is #{b[0]}"
    end
    if b[1] < a[1]
      raise Failure, "#{label}/reference: gametic goes backwards at row #{i + 1}: #{a[1]} then #{b[1]}"
    end
  end

  by_gametic = {}
  frames.each { |_id, g, h| (by_gametic[g] ||= []) << h }
  multi = by_gametic.count { |_g, hs| hs.size > 1 }

  # --- the candidate's key --------------------------------------------------
  #
  # One row per simulated tic, so here the gametic IS the record identity.
  cand_all = cr.each_with_index.map do |x, i|
    [ival(x[0], "#{label}/candidate", "gametic on row #{i}"), x[ccol]]
  end
  cand_all.each_cons(2).with_index do |(a, b), i|
    raise Failure, "#{label}/candidate: gametic #{a[0]} repeats at row #{i + 1}" if a[0] == b[0]
    raise Failure, "#{label}/candidate: gametics are not increasing: #{a[0]} then #{b[0]}" if b[0] < a[0]
  end

  in_range = cand_all.select { |t, _| t < ntics }
  raise Failure, "#{label}: candidate has no tics below #{ntics}" if in_range.empty?

  # Expected coverage comes from what was REQUESTED, 0..ntics-1, not from what
  # happened to arrive.  Deriving the range from the observed first and last tic
  # makes truncation invisible: a candidate cut short at either end is still
  # contiguous over its own span, so every tic present finds its reference frame
  # and the run passes having compared fewer.  That was a real defect here --
  # ntics=5 against a candidate holding tics 0..3 exited 0 -- and it is the
  # reason this range is a constant rather than a measurement.
  ct = in_range.map(&:first).to_set
  want = (0...ntics).to_a
  cmissing = want.reject { |t| ct.include?(t) }
  unless cmissing.empty?
    shown = cmissing.first(8).join(", ")
    more = cmissing.size > 8 ? ", … #{cmissing.size - 8} more" : ""
    where = if cmissing.first == 0 then "head"
            elsif cmissing.last == ntics - 1 then "tail"
            else "middle"
            end
    both = cmissing.include?(0) && cmissing.include?(ntics - 1) ? " (both ends)" : " (#{where})"
    raise Failure, "#{label}/candidate: #{cmissing.size} of #{ntics} requested tic(s) missing#{both}: #{shown}#{more}"
  end

  # --- the exclusion, bounded and checked -----------------------------------
  #
  # The screen for candidate tic N is recorded under gametic N+1, and gametics 1
  # and 2 are the title screen and the wipe into it.  Exactly those two
  # candidate tics are skipped; the comparator then checks that the set it
  # skipped is exactly that set, so a bug or a mutation cannot quietly shrink
  # the comparison and pass.
  skipped = in_range.map(&:first).select { |t| t + 1 < START_GAMETIC }
  expected_skip = EXCLUDED_CANDIDATE_TICS.select { |t| in_range.any? { |k, _| k == t } }
  if skipped.sort != expected_skip.sort
    raise Failure, "#{label}: excluded tics #{skipped.inspect}, expected exactly #{expected_skip.inspect}"
  end

  compared = in_range.reject { |t, _| t + 1 < START_GAMETIC }
  raise Failure, "#{label}: nothing left to compare after excluding #{skipped.inspect}" if compared.empty?
  if compared.size != in_range.size - expected_skip.size
    raise Failure, "#{label}: #{compared.size} tics to compare, expected #{in_range.size - expected_skip.size}"
  end

  # --- coverage: every gametic the candidate needs must exist ---------------
  needed = compared.map { |t, _| t + 1 }
  missing = needed.reject { |g| by_gametic.key?(g) }
  unless missing.empty?
    shown = missing.first(8).join(", ")
    more = missing.size > 8 ? ", … #{missing.size - 8} more" : ""
    raise Failure, "#{label}: #{missing.size} gametic(s) missing from the reference: #{shown}#{more}"
  end
  gaps = (needed.first..needed.last).reject { |g| by_gametic.key?(g) }
  unless gaps.empty?
    raise Failure, "#{label}: reference has #{gaps.size} gap(s) in #{needed.first}..#{needed.last}, " \
                   "first at gametic #{gaps.first}"
  end

  # --- values ---------------------------------------------------------------
  #
  # The port renders one frame per tic; the reference may have rendered several.
  # A match against ANY of that gametic's reference frames is the rule the L6
  # gate uses, and it is the right one: the port's frame is the settled screen
  # for the tic, which is among the frames the reference produced for it.
  field = full ? "fullhash" : "viewhash"
  known = 0
  compared.each do |t, h|
    g = t + 1
    next if by_gametic[g].include?(h)

    alts = by_gametic[g]
    # The declaration must name a reference value that the reference actually
    # holds for this gametic, and the candidate value the candidate actually
    # produced.  Declaring the tic is not enough: a different wrong hash here is
    # a new defect, not the recorded one.
    observed = alts.map { |a| [field, a, h] }
    if observed.any? { |o| difference_allowed?(allowances, label, g, [o]) }
      known += 1
      next
    end

    declared = allowances.select { |a| a.stream == label && a.key == g }
    detail = alts.size == 1 ? "reference=#{alts.first}" : "reference has #{alts.size} frames, none matching"
    extra = if declared.empty?
              ""
            else
              " (gametic #{g} declares reference=#{declared.map(&:ref).join("/")} " \
                "candidate=#{declared.map(&:cand).join("/")}, which is not what happened)"
            end
    if $report_all
      $collected << [label, g, field, alts.first, h]
      next
    end
    raise Failure, "#{label}: first mismatch at gametic #{g}: #{detail} candidate=#{h}#{extra}"
  end

  suffix = known.zero? ? "" : ", #{known} declared discrepancy tic(s)"
  multis = multi.zero? ? "" : ", #{multi} gametic(s) carry several reference frames"
  collected_here = $collected.count { |stream, _, _, _, _| stream == label }
  # Under --report-all a stream with collected divergences must not read as OK.
  # A per-stream "OK" beside a failing run is the kind of line that gets quoted
  # on its own later.
  verdict = collected_here.zero? ? "OK" : "DIVERGES (#{collected_here} tic(s))"
  identical = compared.size - collected_here
  report << "#{label}: #{verdict} (#{identical}/#{compared.size} tics identical from gametic " \
            "#{needed.first}, #{skipped.size} excluded#{multis}#{suffix})"
end

def main(argv)
  refdir = canddir = allowpath = nil
  ntics = nil
  until argv.empty?
    case (a = argv.shift)
    when "--reference"  then refdir = argv.shift
    when "--candidate"  then canddir = argv.shift
    when "--ntics"      then ntics = Integer(argv.shift, 10)
    when "--allowances" then allowpath = argv.shift
    when "--report-all" then $report_all = true
    else
      warn "compare: unknown argument #{a.inspect}"
      return 2
    end
  end
  if refdir.nil? || canddir.nil? || ntics.nil?
    warn "usage: compare.rb --reference DIR --candidate DIR --ntics N [--allowances FILE] [--report-all]"
    return 2
  end

  report = []
  begin
    allowances = read_allowances(allowpath)
    compare_rand(refdir, canddir, ntics, allowances, report)
    compare_by_tic(refdir, canddir, "player.tsv", ntics, allowances, report)
    compare_by_tic(refdir, canddir, "mobjs.tsv", ntics, allowances, report)
    compare_frames(refdir, canddir, ntics, allowances, report, full: false)
    compare_frames(refdir, canddir, ntics, allowances, report, full: true)

    # A declared discrepancy that did not occur is itself a change.  Widening an
    # allowance list is not how a changed reference is handled, and neither is
    # leaving a stale entry in it.
    stale = allowances.reject(&:fired)
    unless stale.empty?
      d = stale.map { |x| "#{x.stream}@#{x.key}:#{x.field}" }.join(", ")
      raise Failure, "allowances: #{stale.size} declared discrepancy(ies) did not occur: #{d}"
    end
  rescue Failure => e
    report.each { |line| $stdout.puts line }
    $stdout.puts "MISMATCH #{e.message}"
    $stdout.puts "compare: FAILED"
    return 1
  end

  report.each { |line| $stdout.puts line }
  unless $collected.empty?
    $stdout.puts "compare: #{$collected.size} divergence(s), as allowance lines for review:"
    $collected.each do |stream, key, field, ref, cand|
      $stdout.puts "#{stream}\t#{key}\t#{field}\t#{ref}\t#{cand}\tTODO: record why this differs"
    end
    $stdout.puts "compare: FAILED (--report-all lists them; it does not excuse them)"
    return 1
  end
  $stdout.puts "compare: all streams agree"
  0
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
