# test_e170.rb -- E170: the raster lane's 3 tools (Ruby) are byte-equal to the frozen Python.
#
# Four claims:
#   (a) over the whole corpus **stdout / stderr / rc and the outputs are byte-equal**.
#   (b) `sp_job_table.h` **stays tracked and does not move** — guarded by `emit`'s output being byte-equal
#       to the tracked header (the same claim as T8, from the suite's side too).
#   (c) the 3 frozen Python tools and the 4 frozen MLIR files / `entries.tsv` are **not rewritten by a single
#       byte** (identity pin).
#   (d) a tool that should be there is never turned green by a skip (a missing Ruby / frozen Python is red).
#
# The input Job IR is **not tracked**. The suite makes 3 tics from `doom/tools/build.sh dump_jobs`
# and the WAD every time (like E169's `.ll`). The built binary and the dump are
# made once and kept in class variables.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../../ab/golden"

class E170Test < Minitest::Test
  HERE = File.expand_path(File.dirname(__FILE__))
  REPO = File.expand_path("../../..", HERE)
  E170 = File.join(REPO, "docs/experiments/results/E170")
  TABLE = File.join(E170, "cases.tsv")
  IDENTITY = File.join(E170, "identity.tsv")
  FROZEN_DIR = ENV["SPINEL_E170_FROZEN"] || File.join(REPO, "tools/raster/frozen")
  RUBY_DIR = ENV["SPINEL_E170_RUBY"] || File.join(REPO, "tools/raster")
  WAD = ENV["DOOM_WAD"] || "/tmp/doom-wad/doom1.wad"

  E170_DIR = File.join(REPO, "docs/experiments/results/E170")
  # ---- E173 (P014 Phase 1): golden fixture --------------------------------
  GOLDEN = Golden::Store.new(ENV["SPINEL_E170_GOLDEN"] || E170_DIR)
  MODE = ENV["SPINEL_E170_MODE"] || "golden"   # second checkpoint: the default is golden (no python3 needed)
  GOLDEN_DRIFT = ENV["SPINEL_E170_GOLDEN_DRIFT"] == "1"
  FROZEN_FILES = %w[spinel-jobtable spinel-jobcheck spinel-rastergen]
                 .map { |t| "tools/raster/frozen/#{t}" }.freeze

  COLUMNS = %w[id tool argv expect_rc artifacts note os_specific skip_on].freeze
  SHAPE = { "cases" => 51, "pins" => 6 }.freeze
  RCS = [0, 1, 2].freeze
  TICS = { "DEMO1_0" => %w[DEMO1 0], "DEMO1_2045" => %w[DEMO1 2045],
           "DEMO3_456" => %w[DEMO3 456] }.freeze

  CLASS_DRIFT = ENV["SPINEL_E170_CLASS_DRIFT"] == "1"
  PIN_DRIFT = ENV["SPINEL_E170_PIN_DRIFT"] == "1"
  HEADER_DRIFT = ENV["SPINEL_E170_HEADER_DRIFT"] == "1"
  CASE_SKIP = ENV["SPINEL_E170_CASE_SKIP"]
  ONLY_TOOL = ENV["SPINEL_E170_ONLY_TOOL"]   # to look at one tool only, midway through a checkpoint

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
      raise "the header of identity.tsv differs from the declaration" unless lines.first.split("\t") == %w[path sha256]
      lines.drop(1).map { |l| l.split("\t") }
    end
  end

  def show(bytes) = bytes.dup.force_encoding("UTF-8").scrub("?")

  # ---- preparing the inputs (once only) --------------------------------------
  def fixtures
    @@fixtures ||= begin
      dir = Dir.mktmpdir("e170-fix.")
      at_exit { FileUtils.rm_rf(dir) }
      raise "the WAD is missing (#{WAD}) — doom/tools/fetch_wad.sh" unless File.file?(WAD)
      bin = File.join(dir, "bin")
      out, err, st = Open3.capture3({ "LLVM" => ENV["LLVM"] || "/usr/lib/llvm-22" },
                                    "bash", File.join(REPO, "doom/tools/build.sh"),
                                    bin, "dump_jobs", chdir: REPO)
      raise "building dump_jobs failed\n#{out}#{err}" unless st.exitstatus.zero?
      jobs = File.join(dir, "jobs")
      TICS.each do |name, (lump, tic)|
        d = File.join(jobs, name)
        FileUtils.mkdir_p(d)
        _o, e, s = Open3.capture3(File.join(bin, "dump_jobs"), WAD, lump, tic, d)
        raise "dump_jobs #{name} failed\n#{e}" unless s.exitstatus.zero?
      end
      # The MLIR that jobcheck reads is **made by the frozen Python** (an input on the oracle's side).
      mlir = File.join(dir, "mlir")
      FileUtils.mkdir_p(mlir)
      { "tic0" => "DEMO1_0", "tic1" => "DEMO1_2045", "tic2" => "DEMO3_456" }.each do |tag, d|
        j = File.join(jobs, d)
        # **The inputs are prepared in Ruby too** (so that the default run does not start
        # python3). As E170 showed, the 2 implementations' outputs are byte-equal,
        # so the corpus is the same whichever makes it.
        _o, e, s = Open3.capture3(File.join(RUBY_DIR, "spinel-rastergen"),
                                  "mlir", "--jobs", j, "--table", File.join(j, "table.tsv"),
                                  "--kind", "every", "-o", File.join(mlir, "#{tag}.every.mlir"))
        raise "preparing the MLIR failed\n#{e}" unless s.exitstatus.zero?
      end
      { "jobs" => jobs, "mlir" => mlir }
    end
  end

  def argv_of(r, outdir)
    r["argv"].split(" ").reject(&:empty?).map do |a|
      a.gsub("@JOBS@", fixtures["jobs"]).gsub("@MLIR@", fixtures["mlir"])
       .gsub("@OUT@", outdir.to_s)
    end
  end

  def wants_outdir?(r) = r["argv"].include?("@OUT@")
  def artifacts_of(r) = r["artifacts"] == "-" ? [] : r["artifacts"].split(",")

  def run_tool(exe, argv, dir)
    if MODE == "golden" && exe.any? { |x| File.basename(x.to_s) == "python3" }
      raise "tried to start python3 in golden mode: #{exe.inspect}"
    end

    out, err, st = Open3.capture3({ "LC_ALL" => "C", "PYTHONDONTWRITEBYTECODE" => "1",
                                    "TMPDIR" => dir },
                                  *exe, *argv, chdir: REPO)
    [out.dup.force_encoding(Encoding::BINARY),
     err.dup.force_encoding(Encoding::BINARY), st]
  end

  # Only **the `(choose from …)` part** of argparse's `invalid choice` line
  # is spelled differently by Python version (3.12 has `'emit', 'check'`, 3.13 has `emit, check`).
  # Ruby's spelling can match only one of them, so **only the inside of those parentheses**
  # is masked. rc, usage and `invalid choice: 'x'` are compared by bytes.
  CHOOSE_RE = /\(choose from .*\)$/.freeze
  def mask_choose(bytes)
    bytes.lines.map { |l|
      l.include?("invalid choice:".b) ? l.sub(/\(choose from [^\n]*\)/n, "(choose from @CHOICES@)") : l
    }.join
  end

  # A tmp path in the output differs per run. **Only that spelling** is masked, and that the masking is
  # not too wide is controlled by counting "the difference is only in lines containing that spelling".
  def mask(bytes, dirs)
    out = bytes
    dirs.each_with_index do |d, i|
      out = out.gsub(d.dup.force_encoding(Encoding::BINARY), "@D#{i}@".b)
    end
    out
  end

  # ---- 1. the table itself ----------------------------------------------------
  def test_case_table_is_the_declared_slice
    assert_equal SHAPE["cases"], rows.size, "case count"
    ids = rows.map { |r| r["id"] }
    assert_equal ids.uniq, ids, "duplicate ids"
    assert_equal SHAPE["pins"], pins.size, "pin count of identity.tsv"
    %w[jobtable rastergen jobcheck].each do |t|
      refute_empty rows.select { |r| r["tool"] == t }, "no row for #{t}"
    end
    RCS.each { |c| refute_empty rows.select { |r| r["expect_rc"].to_i == c }, "no row for rc #{c}" }
    refute_empty rows.select { |r| wants_outdir?(r) }, "no row compares outputs"
    rows.each { |r| assert_includes RCS, r["expect_rc"].to_i, "#{r['id']}: expect_rc" }
  end

  def test_pins_hold
    pins.each do |path, want|
      full = File.join(REPO, path)
      assert File.file?(full), "the pinned file is missing (#{path})"
      got = Digest::SHA256.hexdigest(File.binread(full))
      got = got.sub(/.\z/, "0") if PIN_DRIFT && path.end_with?("sp_job_table.h")
      assert_equal want, got, "#{path}: the pin drifted — E170 only reads the frozen Python"
    end
  end

  # ---- 2. `sp_job_table.h` does not move -------------------------------------
  def test_generated_header_matches_the_tracked_one
    header = File.join(REPO, "tools/raster/sp_job_table.h")
    Dir.mktmpdir("e170-hdr.") do |dir|
      j = File.join(fixtures["jobs"], "DEMO1_0")
      out, err, st = run_tool([File.join(RUBY_DIR, "spinel-jobtable")],
                              ["emit", File.join(j, "table.tsv")], dir)
      assert_equal 0, st.exitstatus, "emit failed\n#{show(err)}"
      want = File.binread(header)
      want = want + "\n".b if HEADER_DRIFT
      assert_equal want, out, "the generated header differs from the tracked one (sp_job_table.h does not move)"
    end
  end

  # ---- 3. the 3 tools are present --------------------------------------------
  def test_both_implementations_are_present
    %w[spinel-jobtable spinel-jobcheck spinel-rastergen].each do |t|
      # The frozen Python was retired (the golden fixture is the counterpart). It is needed only in the record / both
      # modes.
      assert File.file?(File.join(FROZEN_DIR, t)), "the frozen Python is missing (#{t})" unless MODE == "golden"
      assert File.executable?(File.join(RUBY_DIR, t)), "the Ruby #{t} is missing"
    end
  end

  # ---- E173: golden fixture ----------------------------------------------
  # Returns the output **shaped** for comparison. E170 normalizes 2 things, both of which the existing
  # differential checks already used when declared: the spelling of the output dir, and argparse's
  # `(choose from …)` (it differs between Python 3.12 and 3.13).
  # **The corpus's input dir is masked too**. The Job IR is not tracked and the suite makes it from the WAD
  # every time, so `@JOBS@` / `@MLIR@` are temp dirs that differ per run.
  # One of the diagnostics (`no table row named … in <path>`) names one.
  def mask_fix(bytes)
    b = bytes
    b = b.gsub(fixtures["jobs"].dup.force_encoding(Encoding::BINARY), "@JOBS@".b)
    b.gsub(fixtures["mlir"].dup.force_encoding(Encoding::BINARY), "@MLIR@".b)
  end

  def leg(r, exe, dir, odir)
    FileUtils.mkdir_p(odir) if odir
    out, err, st = run_tool(exe, argv_of(r, odir), dir)
    out = mask(out, [odir]) if odir
    err = odir ? mask(err, [odir]) : mask_choose(err)
    [mask_fix(out), mask_fix(err), st.exitstatus]
  end

  def frozen_exe(r) = ["python3", File.join(FROZEN_DIR, "spinel-" + r["tool"])]
  def ruby_exe(r) = [File.join(RUBY_DIR, "spinel-" + r["tool"])]

  def test_record_the_golden
    skip "mode=#{MODE}" unless MODE == "record"

    # **Do not overwrite the base from another OS** (a safety valve).
    GOLDEN.guard_base_overwrite!(Golden.os_tag) unless GOLDEN.record_over?

    shas = []
    rows.each do |r|
      Dir.mktmpdir("e170-rec.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "py") : nil
        out, err, rc = leg(r, frozen_exe(r), dir, odir)
        shas.concat(GOLDEN.record(r["id"], over: GOLDEN.record_over?, repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
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
    check_drift!
  end

  def test_the_golden_is_what_the_frozen_python_says
    skip "mode=#{MODE}" unless MODE == "both"

    check_drift!
  end

  def check_drift!
    drift = []
    rows.each do |r|
      Dir.mktmpdir("e170-drift.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "py") : nil
        out, err, rc = leg(r, frozen_exe(r), dir, odir)
        drift.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
    end
    assert_empty drift, "the golden differs from the frozen tool's raw output (drift=#{drift.size})\n#{drift.first(4).join("\n")}"
  end

  # The recorded golden must hold no per-run spelling (`/tmp/…`).
  # If it did, it would be "green only on the recording machine".
  def test_the_golden_has_no_run_local_paths
    skip "mode=#{MODE}" if MODE == "record"

    hits = Golden.scan_run_local(GOLDEN.base_dir, repo: REPO)
    assert_empty hits, "a per-run path remains in the golden\n" +
                       hits.first(4).map { |f, i, l| "  #{f}:#{i} #{l}" }.join("\n")
  end

  def test_the_product_matches_the_golden
    skip "mode=#{MODE}" if MODE == "record"

    bad = []
    rows.each do |r|
      Dir.mktmpdir("e170-gold.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "rb") : nil
        out, err, rc = leg(r, ruby_exe(r), dir, odir)
        want = r["expect_rc"].to_i
        want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "jt_check_header"
        assert_equal want, rc, "#{r['id']}: the Ruby rc differs from the table\n#{show(err)}"
        out = out + "\n".b if GOLDEN_DRIFT && r["id"] == rows.first["id"]
        bad.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
    end
    assert_empty bad, "differs from the golden (#{bad.size})\n#{bad.first(4).join("\n")}"
  end

  # ---- 4. the whole corpus ------------------------------------------------------
  def test_ruby_matches_the_frozen_python
    skip "mode=#{MODE}" unless MODE == "both"

    checked = 0
    rows.each do |r|
      next if ONLY_TOOL && r["tool"] != ONLY_TOOL
      Dir.mktmpdir("e170-case.") do |dir|
        pdir = wants_outdir?(r) ? File.join(dir, "py") : nil
        ndir = wants_outdir?(r) ? File.join(dir, "rb") : nil
        [pdir, ndir].compact.each { |d| FileUtils.mkdir_p(d) }
        pout, perr, pst = run_tool(["python3", File.join(FROZEN_DIR, "spinel-" + r["tool"])],
                                   argv_of(r, pdir), dir)
        rout, rerr, rst = run_tool([File.join(RUBY_DIR, "spinel-" + r["tool"])],
                                   argv_of(r, ndir), dir)
        want = r["expect_rc"].to_i
        want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "jt_check_header"
        assert_equal want, pst.exitstatus, "#{r['id']}: the frozen Python's rc differs from the table\n#{show(perr)}"
        assert_equal want, rst.exitstatus, "#{r['id']}: the Ruby rc differs from the table\n#{show(rerr)}"
        dirs = [pdir, ndir].compact
        if dirs.empty?
          assert_equal pout, rout, "#{r['id']}: stdout\n--- python\n#{show(pout)}--- ruby\n#{show(rout)}"
          # First state that **the difference before masking is only in the `invalid choice` line**.
          only = (perr.lines - rerr.lines) + (rerr.lines - perr.lines)
          assert_empty only.reject { |l| l.include?("invalid choice:".b) },
                       "#{r['id']}: there are differences besides argparse's invalid choice line\n" +
                       only.reject { |l| l.include?("invalid choice:".b) }.first(4).map { |l| show(l) }.join
          assert_equal mask_choose(perr), mask_choose(rerr),
                       "#{r['id']}: stderr (after masking choose from)\n--- python\n#{show(perr)}--- ruby\n#{show(rerr)}"
        else
          # The output dir's spelling differs, so **only that spelling** is masked before comparing.
          only = (mask(pout, [pdir]).lines - mask(rout, [ndir]).lines)
          assert_empty only.reject { |l| l.include?("@D0@") },
                       "#{r['id']}: the stdout differences are not only in the output dir lines"
          assert_equal mask(pout, [pdir]), mask(rout, [ndir]), "#{r['id']}: stdout (after masking the dir)"
          assert_equal mask(perr, [pdir]), mask(rerr, [ndir]), "#{r['id']}: stderr (after masking the dir)"
          assert_equal artifacts_of(r), Dir.children(pdir).sort, "#{r['id']}: the frozen Python's outputs"
          assert_equal artifacts_of(r), Dir.children(ndir).sort, "#{r['id']}: the Ruby outputs"
          artifacts_of(r).each do |f|
            assert_equal File.binread(File.join(pdir, f)), File.binread(File.join(ndir, f)),
                         "#{r['id']}: #{f}"
          end
        end
        checked += 1
      end
    end
    assert_operator checked, :>, 0, "not a single case was compared"
  end
end
