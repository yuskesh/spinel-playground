# test_e168.rb -- E168: the Ruby `spinel-capcheck` is byte-equal to the frozen Python.
#
# Three claims:
#   (a) over the whole corpus **stdout / stderr / rc are all byte-equal**. A partial match on a needle
#       is not enough — a partial match hides drift in the wording (design D-2).
#   (b) the frozen Python (`frozen/spinel-capcheck.py`), `spinel_platform.py`, the ledgers
#       (`menus.yaml` / `arena.yaml`) and the 2 profiles are **not rewritten by a single byte**
#       (identity pin).
#   (c) the frozen `spinel-mlirgen.py` can still read `spinel_platform.py` as before
#       (the module was not moved — only the CLI was).
#
# **Turned into goldens later**. The frozen Python's output is
# recorded in `results/E168/golden/`, and by default the comparison is with that (python3 is
# not started). Three modes:
#
#   both    (default at the first checkpoint) compare with both the frozen tool and the golden
#   golden  (default from the second checkpoint) compare with the golden only = **no python3 needed**
#   record  run the frozen tool, write the golden, **run it once more and count drift**
#
# That the recorded golden is "the frozen tool's answer" is held by `golden/provenance.tsv`.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../../ab/golden"

class E168Test < Minitest::Test
  HERE = File.expand_path(File.dirname(__FILE__))
  REPO = File.expand_path("../../..", HERE)
  TABLE = File.join(HERE, "e168_cases.tsv")
  IDENTITY = File.join(HERE, "e168_identity.tsv")
  # **A substitution point for controls**. The runner's INJECT uses it to demonstrate
  # "a tool that should be there is missing" (the default is the 2 in the repo).
  FROZEN = ENV["SPINEL_E168_FROZEN"] ||
           File.join(REPO, "tools/platform/frozen/spinel-capcheck.py")
  RUBY_CLI = ENV["SPINEL_E168_RUBY_CLI"] ||
             File.join(REPO, "tools/platform/spinel-capcheck")

  COLUMNS = %w[id sub argv expect_rc note os_specific skip_on].freeze
  # pins 5 -> 4 (the SHA pin of the frozen `spinel_platform.py` was retired
  # together with its subject. The canonical sources are menus.yaml and the native PlatformLedger).
  SHAPE = { "cases" => 46, "pins" => 4 }.freeze
  RCS = [0, 1, 2].freeze

  E168 = File.join(REPO, "docs/experiments/results/E168")
  GOLDEN = Golden::Store.new(ENV["SPINEL_E168_GOLDEN"] || E168)
  MODE = ENV["SPINEL_E168_MODE"] || "golden"   # second checkpoint: the default is golden (no python3 needed)
  GOLDEN_DRIFT = ENV["SPINEL_E168_GOLDEN_DRIFT"] == "1"
  # The list of frozen files (held by provenance; left out of the identity pin — D-4).
  FROZEN_FILES = ["tools/platform/frozen/spinel-capcheck.py"].freeze

  CLASS_DRIFT = ENV["SPINEL_E168_CLASS_DRIFT"] == "1"
  PIN_DRIFT = ENV["SPINEL_E168_PIN_DRIFT"] == "1"
  CASE_SKIP = ENV["SPINEL_E168_CASE_SKIP"]

  # `skip_on` declares **this OS does not compare** (design D-2).
  # Not hidden but stepped down from. The number stepped down appears in the runner's summary.
  def skipped_here = rows_all.count { |r| r["skip_on"] == Golden.os_tag }

  def rows_all
    @rows_all ||= begin
      lines = File.readlines(TABLE, chomp: true, encoding: "UTF-8").reject(&:empty?)
      raise "the header of cases.tsv differs from the declaration" unless lines.first.split("\t") == COLUMNS

      lines.drop(1).map { |l| COLUMNS.zip(l.split("\t", -1)).to_h }
    end
  end

  def os_specific_of(r) = r["os_specific"].to_s == "-" ? [] : r["os_specific"].split(",")

  def rows
    @rows ||= begin
      r = rows_all.reject { |x| x["skip_on"] == Golden.os_tag }
      r = r.reject { |x| x["id"] == CASE_SKIP } if CASE_SKIP
      r
    end
  end

  def pins
    @pins ||= begin
      lines = File.readlines(IDENTITY, chomp: true, encoding: "UTF-8").reject(&:empty?)
      raise "the header of e168_identity.tsv differs from the declaration" unless lines.first.split("\t") == %w[path sha256]
      lines.drop(1).map { |l| l.split("\t") }
    end
  end

  def note_of(r)
    raw = r["note"].to_s
    return {} if raw.empty? || raw == "-"
    raw.split(";").reject(&:empty?).map { |kv| k, _, v = kv.partition("="); [k, v] }.to_h
  end

  def argv_of(r) = r["argv"].split(" ").reject(&:empty?).map { |a| a.gsub("@R@", REPO) }

  # A line naming the tool's own path (`usage: see the header of …`) is **correctly**
  # spelled differently per implementation. Only that line is masked, and **every other line must be byte-equal**.
  # That the masking is not too wide is controlled by counting "the difference is only that line".
  # Used only to explain a red result (the comparison itself is by bytes).
  def show(bytes) = bytes.dup.force_encoding("UTF-8").scrub("?")

  def mask_self(text, path) = text.gsub(path.dup.force_encoding(Encoding::BINARY), "@SELF@")

  # **Output is taken as binary**. Bytes are compared, not characters —
  # with an encoding in between, "bytes that could not be read" would be rounded inside the comparator.
  def run_case(cmd, argv)
    if MODE == "golden" && cmd.any? { |x| File.basename(x.to_s) == "python3" }
      raise "tried to start python3 in golden mode: #{cmd.inspect}"
    end

    out, err, st = Open3.capture3({ "PYTHONDONTWRITEBYTECODE" => "1", "LC_ALL" => "C" },
                                  *cmd, *argv, chdir: REPO)
    [out.dup.force_encoding(Encoding::BINARY),
     err.dup.force_encoding(Encoding::BINARY), st]
  end

  def test_case_table_is_the_declared_slice
    assert_equal SHAPE["cases"], rows.size, "case count"
    ids = rows.map { |r| r["id"] }
    assert_equal ids.uniq, ids, "duplicate ids"
    assert_equal SHAPE["pins"], pins.size, "pin count of identity.tsv"
    rows.each do |r|
      assert_includes RCS, r["expect_rc"].to_i, "#{r['id']}: expect_rc outside the closed set"
      assert_includes %w[check profile tier -], r["sub"], "#{r['id']}: sub"
    end
    # The 3 subcommands and the 3 rcs **are each present in the corpus**.
    %w[check profile tier].each do |s|
      refute_empty rows.select { |r| r["sub"] == s }, "no row for subcommand #{s}"
    end
    RCS.each do |c|
      refute_empty rows.select { |r| r["expect_rc"].to_i == c }, "no row for rc #{c}"
    end
  end

  def test_pins_hold
    pins.each do |path, want|
      full = File.join(REPO, path)
      assert File.file?(full), "the pinned file is missing (#{path})"
      got = Digest::SHA256.hexdigest(File.binread(full))
      got = got.sub(/.\z/, "0") if PIN_DRIFT && path.end_with?("menus.yaml")
      assert_equal want, got, "#{path}: the pin drifted — E168 only reads the frozen Python"
    end
  end

  # Here was `test_frozen_mlirgen_still_imports_spinel_platform`:
  # a control that the frozen `spinel-mlirgen.py` reads `spinel_platform.py` with an import from the same directory.
  # **Both were retired and deleted**, so the test was dropped
  # together with its subject. The canonical ledger is `menus.yaml` and the native
  # `PlatformLedger`, and the other tests in this file match them.

  # Runs the frozen tool once and returns its output shaped "for comparison". **Only the `mask: self` lines**
  # name the tool's own path, so they are masked before recording (that the masking is not too wide
  # is counted each time by `only` below).
  def frozen_output(r)
    out, err, st = run_case(["python3", FROZEN], argv_of(r))
    err = mask_self(err, FROZEN) if note_of(r)["mask"] == "self"
    [out, err, st.exitstatus]
  end

  def product_output(r)
    out, err, st = run_case([RUBY_CLI], argv_of(r))
    err = mask_self(err, RUBY_CLI) if note_of(r)["mask"] == "self"
    [out, err, st.exitstatus]
  end

  # ---- recording the golden (`--record`) -----------------------------------
  # **Taken from the frozen Python's output**. Taken from the product, the golden would only say
  # "the product matches the product" (design D-3).
  def test_record_the_golden
    skip "mode=#{MODE}" unless MODE == "record"

    # **Do not overwrite the base from another OS** (a safety valve).
    GOLDEN.guard_base_overwrite!(Golden.os_tag) unless GOLDEN.record_over?

    shas = []
    rows.each do |r|
      out, err, rc = frozen_output(r)
      shas.concat(GOLDEN.record(r["id"], over: GOLDEN.record_over?, repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc))
    end
    GOLDEN.write_shas(shas, over: GOLDEN.record_over?)
    GOLDEN.write_provenance(
      os: Golden.os_tag, python: Golden.python_version,
      frozen_sha: Golden.sha_list(REPO, FROZEN_FILES),
      inputs_sha: (Golden.sha_list(REPO, pins.map { |p, _| p }).split(";") +
                   ["@repo=#{REPO}"]).sort.join(";"),
      commit: Golden.git_commit(REPO)
    )
    assert_equal rows.size, GOLDEN.ids.size, "number of cases recorded"
    # **Right after recording, run the frozen tool once more in another run and compare**.
    # Reading back the bytes just written says nothing — if the frozen tool produced something different per run
    # (as Enzyme did once), it shows here.
    check_drift!
  end

  # ---- the recorded golden is the frozen tool's answer (drift) -------------
  # Runs the frozen tool once more **in a run separate from the recording** and compares with the golden.
  # Writing the same bytes and reading them back says nothing — if the frozen tool produced something different
  # per run (as Enzyme did once), it shows here.
  def test_the_golden_is_what_the_frozen_python_says
    skip "mode=#{MODE}" unless MODE == "both"

    check_drift!
  end

  def check_drift!
    drift = []
    rows.each do |r|
      out, err, rc = frozen_output(r)
      drift.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc))
    end
    assert_empty drift, "the golden differs from the frozen tool's raw output (drift=#{drift.size})\n#{drift.first(4).join("\n")}"
  end

  # ---- comparing the product with the golden (default) ----------------------
  # The recorded golden must hold **no spelling that changes per run**.
  # It looks not only for `/tmp/` but also for **the recording machine's repo root** — once, the
  # recording machine's absolute path stayed in E168's stderr and passed green on Linux,
  # and turned red only on the Mac. The scan had been too narrow.
  def test_the_golden_has_no_run_local_paths
    skip "mode=#{MODE}" if MODE == "record"

    hits = Golden.scan_run_local(GOLDEN.base_dir, repo: REPO)
    assert_empty hits, "a per-run path remains in the golden\n" +
                       hits.first(4).map { |f, i, l| "  #{f}:#{i} #{l}" }.join("\n")
  end

  def test_the_product_matches_the_golden
    skip "mode=#{MODE}" if MODE == "record"

    assert File.executable?(RUBY_CLI), "the Ruby CLI is missing (#{RUBY_CLI})"
    bad = []
    checked = 0
    rows.each do |r|
      out, err, rc = product_output(r)
      want = r["expect_rc"].to_i
      want = (want == 0 ? 1 : 0) if CLASS_DRIFT && r["id"] == "e090_g_s1_accept"
      assert_equal want, rc, "#{r['id']}: the Ruby rc differs from the table\n#{show(err)}"
      out = out + "\n".b if GOLDEN_DRIFT && r["id"] == rows.first["id"]
      bad.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc))
      checked += 1
    end
    assert_empty bad, "differs from the golden (#{bad.size})\n#{bad.first(4).join("\n")}"
    assert_equal SHAPE["cases"], checked, "number of cases compared"
  end

  # ---- direct differential with the frozen tool (first checkpoint only) -----
  # The golden is "a copy of the frozen tool's answer", so at the first checkpoint it is shown that **comparing
  # with the product at the copy** and **comparing with the frozen tool itself** reach the same conclusion.
  def test_ruby_matches_the_frozen_python
    skip "mode=#{MODE}" unless MODE == "both"

    assert File.file?(FROZEN), "the frozen Python is missing (#{FROZEN}) — something to compare with is needed"
    assert File.executable?(RUBY_CLI), "the Ruby CLI is missing (#{RUBY_CLI})"
    checked = 0
    rows.each do |r|
      pout, perr, prc = frozen_output(r)
      rout, rerr, rrc = product_output(r)
      want = r["expect_rc"].to_i
      want = (want == 0 ? 1 : 0) if CLASS_DRIFT && r["id"] == "e090_g_s1_accept"
      assert_equal want, prc, "#{r['id']}: the frozen Python's rc differs from the table\n#{show(perr)}"
      assert_equal want, rrc, "#{r['id']}: the Ruby rc differs from the table\n#{show(rerr)}"
      if note_of(r)["mask"] == "self"
        only = (perr.lines - rerr.lines) + (rerr.lines - perr.lines)
        assert_empty only.reject { |l| l.include?("@SELF@") },
                     "#{r['id']}: there are differences besides the line that names the tool's own path"
      end
      assert_equal perr, rerr, "#{r['id']}: stderr\n--- python\n#{show(perr)}--- ruby\n#{show(rerr)}"
      assert_equal pout, rout, "#{r['id']}: stdout\n--- python\n#{show(pout)}--- ruby\n#{show(rout)}"
      checked += 1
    end
    assert_equal SHAPE["cases"], checked, "number of cases compared"
  end
end
