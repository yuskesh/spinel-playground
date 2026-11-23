# test_e169.rb -- E169: the native `spinel-rtcheck` is byte-equal to the frozen Python.
#
# Four claims:
#   (a) over the whole corpus **stdout / stderr / rc + the 4 files of `-o` are all byte-equal**
#       (design D-1). Matching verdicts are not enough — the callers (gradgen's O5,
#       an earlier proof) read down to the detail and the chain in paths.txt.
#   (b) **the vocabulary is in one place**. The 5 sets + allow list of `tools/realtime/alloc_vocabulary.tsv`
#       **match exactly** the sets of the frozen `spinel_alloc_free.py`
#       (D-2). **Once the frozen Python was retired, the only copy left is the tsv**, so
#       the comparison was retired with its subject, and what remains is a claim closed over the tsv alone (the D-6 hole).
#   (c) the frozen Python (`frozen/spinel-rtcheck.py` / `spinel_alloc_free.py`), the corpus
#       kernel and `nogc_list.py` are **not rewritten by a single byte** (identity pin).
#   (d) no native binary means **red**. It does not keep quiet like rc 0 or rc 3 (D-4).
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require_relative "../../ab/golden"

class E169Test < Minitest::Test
  HERE = File.expand_path(File.dirname(__FILE__))
  REPO = File.expand_path("../../..", HERE)
  E169 = File.join(REPO, "docs/experiments/results/E169")
  TABLE = File.join(E169, "cases.tsv")
  IDENTITY = File.join(E169, "identity.tsv")
  VOCAB = File.join(REPO, "tools/realtime/alloc_vocabulary.tsv")
  FROZEN = ENV["SPINEL_E169_FROZEN"] ||
           File.join(REPO, "tools/realtime/frozen/spinel-rtcheck.py")
  BUILD = ENV["CONTRACT_BUILD_DIR"] || File.join(REPO, "tools/mlir/native/build")
  NATIVE = ENV["SPINEL_E169_NATIVE"] || File.join(BUILD, "bin/spinel-rtcheck")
  LLVM = ENV["LLVM_PREFIX"] || "/usr/lib/llvm-22"

  COLUMNS = %w[id input entries flags expect_rc artifacts note os_specific skip_on].freeze
  # pins 7 -> 6 (the SHA pin of the frozen `spinel_alloc_free.py` was retired
  # together with its subject. The canonical source is the one file alloc_vocabulary.tsv = D-2).
  SHAPE = { "cases" => 21, "pins" => 6 }.freeze
  RCS = [0, 1, 2].freeze

  # ---- E173 (P014 Phase 1): golden fixture --------------------------------
  # The frozen Python's output is recorded in `results/E169/golden/`. The modes are
  # both (first checkpoint) / golden (from the second checkpoint, **does not start python3**) / record.
  GOLDEN = Golden::Store.new(ENV["SPINEL_E169_GOLDEN"] || E169)
  MODE = ENV["SPINEL_E169_MODE"] || "golden"   # second checkpoint: the default is golden (no python3 needed)
  GOLDEN_DRIFT = ENV["SPINEL_E169_GOLDEN_DRIFT"] == "1"
  FROZEN_FILES = ["tools/realtime/frozen/spinel-rtcheck.py"].freeze
  BC_ARCHIVES = %w[libspinel_rt_lto.a libspinel_rt_mt_lto.a].freeze

  CLASS_DRIFT = ENV["SPINEL_E169_CLASS_DRIFT"] == "1"
  PIN_DRIFT = ENV["SPINEL_E169_PIN_DRIFT"] == "1"
  CASE_SKIP = ENV["SPINEL_E169_CASE_SKIP"]

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

  def env_for(dir)
    { "PYTHONDONTWRITEBYTECODE" => "1", "LC_ALL" => "C",
      "LLVM_PREFIX" => LLVM, "LLVM" => LLVM, "TMPDIR" => dir }
  end

  # Bytes are compared, not characters.
  def run_tool(cmd, argv, dir)
    if MODE == "golden" && cmd.any? { |x| File.basename(x.to_s) == "python3" }
      raise "tried to start python3 in golden mode: #{cmd.inspect}"
    end

    out, err, st = Open3.capture3(env_for(dir), *cmd, *argv, chdir: REPO)
    [out.dup.force_encoding(Encoding::BINARY),
     err.dup.force_encoding(Encoding::BINARY), st]
  end

  def show(bytes) = bytes.dup.force_encoding("UTF-8").scrub("?")

  # The temp dir name of intermediate files differs per run (`mkdtemp` / `createUniqueDirectory`).
  # It appears in `spinel -c`'s "Wrote <path>" and in one line of `--keep`, so **only there**
  # is it masked. That the masking is not too wide is controlled by counting "the difference is only in lines containing that spelling".
  WORK_RE = %r{\S*rtcheck\.[A-Za-z0-9_.\-]+}.freeze
  def mask_work(bytes)
    bytes.gsub(Regexp.new(WORK_RE.source.dup.force_encoding(Encoding::BINARY)), "@WORK@")
  end

  # whole.ll / whole.bc, made once with `--keep` (the corpus's input face). **No more tracked
  # files** — the 8 MB .ll is not put in the repo; the suite makes it every time.
  def fixtures
    @@fixtures ||= begin
      dir = Dir.mktmpdir("e169-fix.")
      at_exit { FileUtils.rm_rf(dir) }
      _o, err, st = run_tool([NATIVE],
                             ["tools/realtime/test/cases.rb", "--int-overflow", "wrap",
                              "--entry", "pure_add", "--keep"], dir)
      raise "--keep failed (#{st.exitstatus})\n#{show(err)}" unless st.exitstatus.zero?
      # The native temp dir contains a `-`, like `rtcheck.-24244f`
      # (`createUniqueDirectory`). The frozen Python's `mkdtemp` does not.
      kept = show(err)[/#{Regexp.escape(dir)}\/rtcheck\.[A-Za-z0-9_.\-]+/] ||
             show(err)[/\/tmp\/rtcheck\.[A-Za-z0-9_.\-]+/]
      raise "cannot pick up --keep's tmp dir from stderr:\n#{show(err)}" unless kept
      # **The native tool leaves no `whole.ll` / `whole.bc`**, because it unpacks the archive and links
      # in-process, which is the point of E169 D-3. The frozen Python's
      # `build_whole_ll` steps (llvm-ar x -> llvm-link -> llvm-dis) are
      # taken here to make them — **without starting python3**.
      link_whole(kept, dir)
      FileUtils.rm_rf(kept)
      File.write(File.join(dir, "entries.txt"),
                 "# E169 corpus: --entries FILE の口 (# はコメント)\npure_add\n\nstr_build\n")
      dir
    end
  end

  # A copy of the second half (from the link on) of the frozen `spinel-rtcheck.py`'s `build_whole_ll`.
  # The first half (spinel -c and clang -emit-llvm) was done by the native `--keep`.
  def link_whole(kept, dir)
    tu = File.join(kept, "cases.tu.ll")
    raise "the native --keep left no cases.tu.ll" unless File.file?(tu)

    threads = File.binread(File.join(kept, "cases.c"))[0, 400_000]
                  .include?("/* SPINEL_USES_THREADS */".b)
    arch = File.join(ENV["BC_DIR"] || File.join(REPO, "tools/llvm/build"),
                     threads ? "libspinel_rt_mt_lto.a" : "libspinel_rt_lto.a")
    raise "the runtime bitcode is missing (#{arch}) — tools/llvm/build_rt_bc.sh" unless File.file?(arch)

    rt = File.join(kept, "rtbc")
    FileUtils.mkdir_p(rt)
    _o, e, st = Open3.capture3(File.join(LLVM, "bin/llvm-ar"), "x", File.expand_path(arch), chdir: rt)
    raise "llvm-ar x failed\n#{e}" unless st.exitstatus.zero?

    members = Dir.children(rt).select { |f| f.end_with?(".o") }.sort.map { |f| File.join(rt, f) }
    bc = File.join(dir, "cases.whole.bc")
    _o, e, st = Open3.capture3(File.join(LLVM, "bin/llvm-link"), tu, *members, "-o", bc)
    raise "llvm-link failed\n#{e}" unless st.exitstatus.zero?

    _o, e, st = Open3.capture3(File.join(LLVM, "bin/llvm-dis"), bc,
                               "-o", File.join(dir, "cases.whole.ll"))
    raise "llvm-dis failed\n#{e}" unless st.exitstatus.zero?
  end

  def argv_of(r, dir, outdir)
    inp = { "@LL@" => File.join(fixtures, "cases.whole.ll"),
            "@BC@" => File.join(fixtures, "cases.whole.bc") }.fetch(r["input"], r["input"])
    argv = [inp]
    if r["entries"] == "@ENTRIES@"
      argv += ["--entries", File.join(fixtures, "entries.txt")]
    elsif r["entries"] != "-"
      r["entries"].split(" ").each { |e| argv += ["--entry", e] }
    end
    r["flags"].split(" ").each do |f|
      next if f.empty? || f == "-"
      argv << f.gsub("@OUT@", outdir.to_s)
    end
    argv
  end

  def note_of(r)
    raw = r["note"].to_s
    return {} if raw.empty? || raw == "-"
    raw.split(";").reject(&:empty?).map { |kv| k, _, v = kv.partition("="); [k, v] }.to_h
  end

  def wants_outdir?(r) = r["flags"].include?("@OUT@")
  def artifacts_of(r) = r["artifacts"] == "-" ? [] : r["artifacts"].split(",")

  # ---- 1. the table itself ----------------------------------------------------
  def test_case_table_is_the_declared_slice
    assert_equal SHAPE["cases"], rows.size, "case count"
    ids = rows.map { |r| r["id"] }
    assert_equal ids.uniq, ids, "duplicate ids"
    assert_equal SHAPE["pins"], pins.size, "pin count of identity.tsv"
    RCS.each { |c| refute_empty rows.select { |r| r["expect_rc"].to_i == c }, "no row for rc #{c}" }
    # Both rows that compare all 4 faces (`-o`) and rows with stdout/stderr only must be present.
    refute_empty rows.select { |r| wants_outdir?(r) }, "no -o row"
    refute_empty rows.reject { |r| wants_outdir?(r) }, "no row without -o"
    rows.each do |r|
      assert_includes RCS, r["expect_rc"].to_i, "#{r['id']}: expect_rc outside the closed set"
      next if %w[@LL@ @BC@].include?(r["input"])
      assert File.file?(File.join(REPO, r["input"])), "#{r['id']}: the input is missing"
    end
  end

  def test_pins_hold
    pins.each do |path, want|
      full = File.join(REPO, path)
      assert File.file?(full), "the pinned file is missing (#{path})"
      got = Digest::SHA256.hexdigest(File.binread(full))
      got = got.sub(/.\z/, "0") if PIN_DRIFT && path.end_with?("alloc_vocabulary.tsv")
      assert_equal want, got, "#{path}: the pin drifted — E169 only reads the frozen Python"
    end
  end

  # ---- 2. the vocabulary is in one place (D-2) -------------------------------
  # **Its shape changed.** This section used to be "the sets of `alloc_vocabulary.tsv`
  # match exactly the sets of the frozen `spinel_alloc_free.py`" = **a comparison while there were
  # two copies**. Once the frozen Python was retired there is one copy, and nothing to compare
  # it with (retired together with its subject). On the native side CMake's
  # `spinel_generate_alloc_vocabulary` **generates a header from this tsv**, so
  # comparing the tsv with native would be circular and no control.
  #
  # What stays is **a claim closed over the tsv alone**: that it copies the D-6 hole (`[a-z]+f`).
  # That does not depend on whether Python exists, so it became a separate test.
  # The INJECT `vocab-drift` (adding a word to the tsv to break the match with the frozen Python)
  # was retired with its subject too — there is nothing left to break.
  def test_vocabulary_tsv_keeps_the_d6_hole
    tsv = Hash.new { |h, k| h[k] = [] }
    File.readlines(VOCAB, chomp: true, encoding: "UTF-8").each do |l|
      next if l.start_with?("#") || l.empty?

      f = l.split("\t")
      next if f[0] == "set"

      tsv[f[0]] << f[1]
    end
    # Check by spelling **that the D-6 hole is copied**. Removing it turns red.
    assert_includes tsv["allow_regex"], "[a-z]+f",
                    "D-6: the allow list's `[a-z]+f` (the hole that lets the printf family through) was dropped — " \
                    "E169 copies it for byte equality (the fix belongs to a separate experiment)"
    # The sets must not be empty. With only the one check above, "the table is broken and
    # only allow_regex can be read" would be missed.
    %w[alloc pause abort_hint setjmp].each do |k|
      refute_empty tsv[k], "#{k} in alloc_vocabulary.tsv is empty — reading the table came up short"
    end
  end

  def test_native_tool_is_present
    assert File.executable?(NATIVE),
           "the native spinel-rtcheck is missing (#{NATIVE}) — build tools/mlir/native. " \
           "**It does not fall back to Python** (design D-4)"
  end

  # ---- E173: golden fixture ----------------------------------------------
  # Returns the output **shaped** for comparison. E169 normalizes 2 things, both of which the existing
  # differential checks already used when declared:
  #   * `mask_work` — the spelling of the intermediate dir (differs per run)
  #   * `verbose-echo` — the native tool unpacks the archive and links in-process, so
  #     it does not print the 2 lines `+ llvm-link` / `+ llvm-dis` (D-3)
  # **The golden is kept in this shaped form**. Keeping raw bytes would always split per run.
  def normalized(r, out, err)
    err = err.lines.reject { |l| l.start_with?("+ ".b) }.join if note_of(r)["divergent"] == "verbose-echo"
    [mask_work(out), mask_work(err)]
  end

  def leg(r, cmd, dir, odir)
    FileUtils.mkdir_p(odir) if odir
    out, err, st = run_tool(cmd, argv_of(r, dir, odir), dir)
    o, e = normalized(r, out, err)
    [o, e, st.exitstatus]
  end

  def test_record_the_golden
    skip "mode=#{MODE}" unless MODE == "record"

    # **Do not overwrite the base from another OS** (a safety valve).
    GOLDEN.guard_base_overwrite!(Golden.os_tag) unless GOLDEN.record_over?

    shas = []
    inputs = []
    rows.each do |r|
      Dir.mktmpdir("e169-rec.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "py") : nil
        out, err, rc = leg(r, ["python3", FROZEN], dir, odir)
        shas.concat(GOLDEN.record(r["id"], over: GOLDEN.record_over?, repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
    end
    GOLDEN.write_shas(shas, over: GOLDEN.record_over?)
    # **The corpus input (whole.ll / whole.bc) is not tracked** (8 MB), and
    # its sha cannot be pinned either —— the `ModuleID` of `cases.tu.ll` contains the per-run
    # temp dir, so `whole.ll` has different bytes every time (measured).
    # Instead **the input's materials** are pinned: the kernel (`cases.rb`, identity pin), the
    # runtime bitcode archive, and the toolchain. When those are the same, `whole.ll` is
    # "a module with the same meaning", and indeed golden mode passes with a different `whole.ll`
    # every time (= measured: the output does not depend on the ModuleID).
    BC_ARCHIVES.each do |f|
      path = File.join(ENV["BC_DIR"] || File.join(REPO, "tools/llvm/build"), f)
      inputs << "#{f}=#{Golden.sha(File.binread(path))}" if File.file?(path)
    end
    GOLDEN.write_provenance(
      os: Golden.os_tag, python: Golden.python_version,
      frozen_sha: Golden.sha_list(REPO, FROZEN_FILES),
      inputs_sha: (Golden.sha_list(REPO, pins.map { |p, _| p }).split(";") + inputs +
                   ["@repo=#{REPO}"]).sort.join(";"),
      commit: Golden.git_commit(REPO)
    )
    assert_equal rows.size, GOLDEN.ids.size, "number of cases recorded"
    # **Right after recording, run the frozen tool once more in another run and compare**.
    # Reading back the bytes just written says nothing — if the frozen tool produced something different per run
    # (as Enzyme did once), it shows here.
    check_drift!
  end

  def test_the_golden_is_what_the_frozen_python_says
    skip "mode=#{MODE}" unless MODE == "both"

    check_drift!
  end

  def check_drift!
    drift = []
    rows.each do |r|
      Dir.mktmpdir("e169-drift.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "py") : nil
        out, err, rc = leg(r, ["python3", FROZEN], dir, odir)
        drift.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
    end
    assert_empty drift, "the golden differs from the frozen tool's raw output (drift=#{drift.size})\n#{drift.first(4).join("\n")}"
  end

  # The recorded input itself (whole.ll / whole.bc) must be the same as in provenance.
  # The golden is "the answer for that input", so if the input moved, the golden is void.
  def test_the_recorded_inputs_are_the_ones_we_have
    skip "mode=#{MODE}" if MODE == "record"

    prov = File.readlines(GOLDEN.provenance_table, chomp: true, encoding: "UTF-8")
    row = prov.drop(1).map { |l| l.split("\t", -1) }.find { |c| c[1] == Golden.os_tag }
    refute_nil row, "provenance has no row for #{Golden.os_tag}"
    want = row[4].split(";").map { |kv| kv.split("=") }.to_h
    seen = 0
    BC_ARCHIVES.each do |f|
      path = File.join(ENV["BC_DIR"] || File.join(REPO, "tools/llvm/build"), f)
      next unless want.key?(f)

      assert File.file?(path), "the runtime bitcode is missing (#{path})"
      assert_equal want[f], Golden.sha(File.binread(path)),
                   "#{f} differs from when it was recorded — the golden is the answer for those materials"
      seen += 1
    end
    assert_operator seen, :>, 0, "provenance has no runtime bitcode row"
  end

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

    bad = []
    rows.each do |r|
      Dir.mktmpdir("e169-gold.") do |dir|
        odir = wants_outdir?(r) ? File.join(dir, "na") : nil
        out, err, rc = leg(r, [NATIVE], dir, odir)
        want = r["expect_rc"].to_i
        want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "pin_region"
        assert_equal want, rc, "#{r['id']}: the native rc differs from the table\n#{show(err)}"
        out = out + "\n".b if GOLDEN_DRIFT && r["id"] == rows.first["id"]
        bad.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: odir))
      end
    end
    assert_empty bad, "differs from the golden (#{bad.size})\n#{bad.join("\n")}"
  end

  # ---- 4. all 4 faces byte-equal over the whole corpus ----------------------
  def test_native_matches_the_frozen_python
    skip "mode=#{MODE}" unless MODE == "both"

    checked = 0
    rows.each do |r|
      Dir.mktmpdir("e169-case.") do |dir|
        pdir = wants_outdir?(r) ? File.join(dir, "py") : nil
        ndir = wants_outdir?(r) ? File.join(dir, "na") : nil
        [pdir, ndir].compact.each { |d| FileUtils.mkdir_p(d) }
        pout, perr, pst = run_tool(["python3", FROZEN], argv_of(r, dir, pdir), dir)
        nout, nerr, nst = run_tool([NATIVE], argv_of(r, dir, ndir), dir)
        want = r["expect_rc"].to_i
        want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "pin_region"
        assert_equal want, pst.exitstatus, "#{r['id']}: the frozen Python's rc differs from the table\n#{show(perr)}"
        assert_equal want, nst.exitstatus, "#{r['id']}: the native rc differs from the table\n#{show(nerr)}"
        assert_equal pout, nout, "#{r['id']}: stdout\n--- python\n#{show(pout)}--- native\n#{show(nout)}"
        # The echo of `-v`'s build stage differs **by exactly the subprocesses the native tool dropped**
        # (D-3: the archive is unpacked and linked in-process, so it does not print `+ llvm-link` and
        # `+ llvm-dis`). Only those lines are removed, and **the rest must be byte-equal**.
        # The removed side is controlled too, by counting "only the 2 lines llvm-link / llvm-dis".
        if note_of(r)["divergent"] == "verbose-echo"
          pe = perr.lines.reject { |l| l.start_with?("+ ".b) }
          ne = nerr.lines.reject { |l| l.start_with?("+ ".b) }
          # Mask the intermediate dir before subtracting (paths appear inside the echo too, so without masking
          # everything would look like a "difference").
          dropped = perr.lines.select { |l| l.start_with?("+ ".b) }.map { |l| mask_work(l) } -
                    nerr.lines.select { |l| l.start_with?("+ ".b) }.map { |l| mask_work(l) }
          assert_equal 2, dropped.size, "#{r['id']}: the dropped echo is not 2 lines"
          assert dropped.all? { |l| l.include?("llvm-link") || l.include?("llvm-dis") },
                 "#{r['id']}: the dropped echo is something other than llvm-link / llvm-dis"
          assert_equal mask_work(pe.join), mask_work(ne.join),
                       "#{r['id']}: stderr (after removing the build stage's echo)"
        else
          # First state that **the difference before masking is only in the temp dir lines**.
          only = (perr.lines - nerr.lines) + (nerr.lines - perr.lines)
          assert_empty only.reject { |l| l.include?("rtcheck.") },
                       "#{r['id']}: there are differences besides the intermediate dir lines\n" +
                       only.reject { |l| l.include?("rtcheck.") }.first(6).map { |l| show(l) }.join
          assert_equal mask_work(perr), mask_work(nerr),
                       "#{r['id']}: stderr (after masking the intermediate dir)\n--- python\n#{show(perr)}--- native\n#{show(nerr)}"
        end
        if wants_outdir?(r)
          assert_equal artifacts_of(r), Dir.children(pdir).sort, "#{r['id']}: the frozen Python's -o file set"
          assert_equal artifacts_of(r), Dir.children(ndir).sort, "#{r['id']}: the native -o file set"
          artifacts_of(r).each do |f|
            assert_equal File.binread(File.join(pdir, f)), File.binread(File.join(ndir, f)),
                         "#{r['id']}: #{f}"
          end
        end
        checked += 1
      end
    end
    assert_equal rows.size, checked, "number of cases compared"
  end
end
