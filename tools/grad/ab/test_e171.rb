# test_e171.rb -- E171: the host grad lane's 2 tools (Ruby) are byte-equal to the frozen Python.
#
# Five claims:
#   (a) over the whole corpus **stdout / stderr / rc and the outputs are byte-equal**. For gradgen the outputs
#       are **the whole** `-o` tree (`.c` / `.ll` / `.o` / TSV / `.gen.rb` /
#       `rtcheck/`); first it states that the set of relative paths is equal on both legs and that **their count
#       matches the table's declaration**, then it compares the contents as binary.
#   (b) **No spelling is masked**. Two rules stand in its place. Both were found necessary
#       by measurement, and they have one root —— **Enzyme v0.0.290's output depends on heap
#       addresses** (it holds containers ordered by address).
#         (b1) both legs pass **the same absolute path** to `-o`, and move the artifacts to
#              `py/` `rb/` after the run. Even when `_grad.ll` differs only in the 2 `ModuleID` lines,
#              its length shifts the allocations, and `_diff.ll` changes.
#         (b2) both legs run **with ASLR off** (`setarch -R` on Linux). Without that,
#              **the frozen Python does not even match itself** (in one measurement, 4 runs in the same dir
#              with the same argv gave 4 different results; with `setarch -R`, 3 runs were all the same).
#   (c) the frozen Python / the rules ledger / the kernels / the fixtures are **not rewritten by a single byte**
#       (42 identity pin lines + the runner's RepoGuard).
#   (d) an implementation that should be there is never turned green by a skip (a missing Ruby / frozen Python / Enzyme /
#       GC pass is red).
#   (e) that (b1) and (b2) are **each necessary** is shown by the matching negative controls
#       (saying the rules are not decoration). The positive control is "2 runs in the same dir with ASLR off
#       match exactly"; without it, the green of (a) could also come from
#       "both legs having the same nondeterminism".
#
# The inputs are **copied into a temp dir** from the tracked results (the tracked ones are read-only).
# Both legs read **inputs at the same absolute paths in the same temp dir** and write to **the same `-o`**
# (the design's "separate only the output dirs" was rejected by the measurement in (b)).
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../../ab/golden"

class E171Test < Minitest::Test
  HERE = File.expand_path(File.dirname(__FILE__))
  REPO = File.expand_path("../../..", HERE)
  E171 = File.join(REPO, "docs/experiments/results/E171")
  TABLE = File.join(E171, "cases.tsv")
  IDENTITY = File.join(E171, "identity.tsv")
  FIXTURES = File.join(E171, "fixtures/searchgate")
  E080 = File.join(REPO, "docs/experiments/results/E080/tables")
  FROZEN_DIR = ENV["SPINEL_E171_FROZEN"] || File.join(REPO, "tools/grad/frozen")
  RUBY_DIR = ENV["SPINEL_E171_RUBY"] || File.join(REPO, "tools/grad")

  DARWIN = RbConfig::CONFIG["host_os"] =~ /darwin/i ? true : false
  OSKEY = DARWIN ? "darwin" : "linux"

  # The frozen Python's defaults are Mac spellings (Homebrew's LLVM, `.dylib`), so Linux
  # passes them explicitly. **Both legs get the same value**, so byte equality does not move.
  ENZYME = ENV["SPINEL_ENZYME"] || File.join(
    REPO, "third_party/enzyme/build/Enzyme",
    DARWIN ? "LLVMEnzyme-22.dylib" : "LLVMEnzyme-22.so"
  )
  GCPASS = ENV["SPINEL_GCPASS"] ||
           File.join(REPO, "tools/llvm/passes/build/libSpinelGCRoots.so")
  # `--llvm` is the dir holding clang / opt / llvm-nm. On macOS the frozen Python's default
  # (Homebrew) is passed as it is. **Linux goes through a shim**: when linking the G3/G4 drivers,
  # glibc keeps `crypt` in libcrypt, and the frozen Python's link
  # line has no `-lcrypt`, so it fails with `undefined reference to crypt`
  # (macOS's `crypt` is in libc). The shim adds `-lcrypt` **only to invocations that link**,
  # and **both legs go through the same shim**, so byte equality does not move.
  LLVM_PREFIX = ENV["LLVM_PREFIX"] || ENV["LLVM"] ||
                (DARWIN ? "/opt/homebrew/opt/llvm" : "/usr/lib/llvm-22")

  def self.llvm_bin
    @llvm_bin ||= begin
      if ENV["SPINEL_E171_LLVMBIN"]
        ENV["SPINEL_E171_LLVMBIN"]
      elsif DARWIN
        File.join(LLVM_PREFIX, "bin")
      else
        # **The spelling of the shim dir is fixed too**. `opt` is started as `<llvm_bin>/opt`,
        # so the **length** of this dir name becomes the length of `opt`'s own argv[0].
        # If that shifts, Enzyme's output changes even with ASLR off —— because a per-run
        # `mktmpdir` was used, checking the golden in another process always split
        # from `_diff.ll` on (measured).
        dir = File.join(WORK_ROOT, "llvm")
        FileUtils.mkdir_p(dir)
        real = File.join(LLVM_PREFIX, "bin")
        Dir.children(real).each do |t|
          next if t == "clang"

          link = File.join(dir, t)
          File.symlink(File.join(real, t), link) unless File.symlink?(link) || File.exist?(link)
        end
        sh = File.join(dir, "clang")
        File.write(sh, <<~SHIM)
          #!/bin/sh
          for a in "$@"; do
            case "$a" in -c|-S|-E|-emit-llvm|--version)
              exec #{real}/clang "$@" ;;
            esac
          done
          exec #{real}/clang "$@" -lcrypt
        SHIM
        File.chmod(0o755, sh)
        dir
      end
    end
  end

  # ---- E173 (P014 Phase 1): golden fixture --------------------------------
  # **E171 alone fixes the work dir**. As measured, Enzyme's output
  # depends on heap addresses, and the addresses shift with the **length** of the input module's `ModuleID`
  # (= the spelling of the output dir). With a per-run `mktmpdir`, everything from `_diff.ll` on
  # changes every time and cannot become a golden. So golden mode uses
  # `<TMPDIR>/e171-golden/<case-id>`, **the same spelling as when recording**, puts its
  # root in provenance, and turns red when it differs (declared, not masked).
  GOLDEN = Golden::Store.new(ENV["SPINEL_E171_GOLDEN"] || E171)
  MODE = ENV["SPINEL_E171_MODE"] || "golden"   # second checkpoint: the default is golden (no python3 needed)
  GOLDEN_DRIFT = ENV["SPINEL_E171_GOLDEN_DRIFT"] == "1"
  # `Dir.tmpdir` is `/var/folders/…` on darwin, a different spelling from the recording (Linux, /tmp),
  # so the root is fixed to **`/tmp/e171-golden` on both OSes**.
  WORK_ROOT = ENV["SPINEL_E171_WORK"] || "/tmp/e171-golden"
  # darwin cannot turn ASLR off, and the outputs from Enzyme on wobble even for the frozen Python itself.
  # On darwin **only the stable faces before Enzyme** are compared
  # with the golden (the design's skip_on made finer, per file. Linux compares every file).
  UNSTABLE_ON_DARWIN = [/_diff\.ll\z/, /_min\.ll\z/, /_grad\.o\z/, /\Abite_.*_adjoint\.ll\z/, /_gate\z/].freeze
  # In cases that ran Enzyme, the G3 / G4 drivers **run** the adjoint object and print values,
  # so on darwin stdout (= gates.tsv) / the stderr summary / build.tsv also take Enzyme's
  # wobble (last digits, adjoint names, object_bytes). For cases that ran Enzyme
  # (the golden has `*_diff.ll`), these are not compared on darwin (declared, not masked).
  DARWIN_DRIVER_FILES = %w[stdout stderr artifacts/gates.tsv artifacts/build.tsv].freeze
  def stable_only(adir)
    return nil unless Golden.darwin? && adir && File.directory?(adir)

    Golden.files_under(adir).reject { |rel| UNSTABLE_ON_DARWIN.any? { |re| File.basename(rel) =~ re } }
  end

  def enzyme_case?(id) = GOLDEN.recorded_artifacts(id).any? { |rel| rel.end_with?("_diff.ll") }

  def drop_darwin_unstable(bad)
    return bad unless Golden.darwin?

    bad.reject do |m|
      id, rest = m.split(": ", 2)
      enzyme_case?(id) && DARWIN_DRIVER_FILES.any? { |f| rest.to_s.start_with?("#{f} ") }
    end
  end
  FROZEN_FILES = %w[spinel-gradgen spinel-searchgate spinel-gradfs]
                 .map { |t| "tools/grad/frozen/#{t}" }.freeze

  COLUMNS = %w[id tool cwd argv expect_rc artifacts note os_specific skip_on].freeze
  SHAPE = { "cases" => 52, "searchgate" => 33, "gradgen" => 19, "pins" => 39 }.freeze
  RCS = [0, 1, 2].freeze

  CLASS_DRIFT = ENV["SPINEL_E171_CLASS_DRIFT"] == "1"
  PIN_DRIFT = ENV["SPINEL_E171_PIN_DRIFT"] == "1"
  CASE_SKIP = ENV["SPINEL_E171_CASE_SKIP"]
  ONLY_TOOL = ENV["SPINEL_E171_ONLY_TOOL"]   # to look at one tool only, midway through a checkpoint

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

  # `expect_rc` is a bare integer or a per-OS spelling (`linux=1,darwin=0`). **There is one row whose answer
  # differs by OS**, so rather than lie with a single number it is written in the table (the reason is in the note column).
  def expect_rc(r)
    v = r["expect_rc"]
    return v.to_i if v =~ /\A\d+\z/

    h = v.split(",").map { |kv| kv.split("=") }.to_h
    raise "#{r['id']}: expect_rc has no #{OSKEY} (#{v})" unless h.key?(OSKEY)

    h[OSKEY].to_i
  end

  def tool_path(dir, r)
    exe = File.join(dir, "spinel-#{r['tool']}")
    dir == FROZEN_DIR ? ["python3", exe] : [exe]
  end

  # gradgen calls subprocesses (spinel / typedump / rtcheck / clang / opt / llvm-nm),
  # so their defaults are passed to both legs equally.
  def extra_argv(r)
    return [] unless r["tool"] == "gradgen"
    return [] if r["argv"].strip == "-h"

    ["--enzyme", ENZYME, "--gc-pass", GCPASS, "--llvm", self.class.llvm_bin]
  end

  def argv_of(r, outdir)
    r["argv"].split(" ").reject(&:empty?).map do |a|
      a.gsub("@FIX@", FIXTURES).gsub("@E080@", E080).gsub("@OUT@", outdir.to_s)
    end
  end

  def wants_outdir?(r) = r["argv"].include?("@OUT@")

  # `tree:<N>` means "the tree has N regular files". `-` means the outputs are not compared.
  def tree_count(r)
    r["artifacts"] =~ /\Atree:(\d+)\z/ ? Regexp.last_match(1).to_i : nil
  end

  def named_artifacts(r)
    return [] if r["artifacts"] == "-" || tree_count(r)

    r["artifacts"].split(",")
  end

  def files_under(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir)
       .reject { |f| File.directory?(File.join(dir, f)) }.sort
  end

  # **The prefix that turns ASLR off** ((b2)). `setarch -R` on Linux; macOS has no way.
  # Without it, **red, not a skip** — never green while silently exposed to address dependence.
  def self.aslr_off
    return @aslr_off if defined?(@aslr_off)

    @aslr_off =
      if ENV["SPINEL_E171_ASLR_ON"] == "1"
        []
      elsif DARWIN
        []
      else
        ok = system("setarch", "-R", "true", out: File::NULL, err: File::NULL)
        raise "setarch -R is unavailable — E171 compares with ASLR off (the suite's (b2))" unless ok

        %w[setarch -R]
      end
  end

  # **The whole environment is fixed**. Even with ASLR off, a child process's initial stack is
  # decided by argv and **the byte count of env**. Inheriting the parent's environment as it is,
  # runs with and without `SPINEL_E171_MODE=record` differ by 19 bytes of env,
  # `opt`'s heap layout changes and Enzyme's output changes (measured).
  # With `unsetenv_others: true`, **only the env the suite lists** is passed, so recording and checking
  # get the same layout even in different processes.
  # **`PATH` is fixed too**. If env's byte count changes, `opt`'s heap layout changes,
  # so inheriting the caller's PATH would split from the golden only in "runs that put the shim at the head of PATH".
  # A canonical value is used and matched against provenance.
  # darwin: `/usr/bin/ruby` is the system 2.6, which cannot parse the Ruby product tools, so
  # **the bindir of the running CRuby** is put at the head (the spelling recorded in provenance).
  FIXED_PATH = ENV["SPINEL_E171_PATH"] ||
               (Golden.darwin? ? "#{RbConfig::CONFIG['bindir']}:/usr/local/bin:/usr/bin:/bin"
                               : "/usr/local/bin:/usr/bin:/bin")
  # `LC_ALL` / `LANG` **change env's byte count by being present or not**, so the caller's
  # values are not inherited but fixed. While they were inherited, `LC_ALL=C ruby test_e171.rb` and
  # `ruby test_e171.rb` gave different Enzyme output and split from the golden.
  # `HOME` is constant per machine, so it is inherited (E171's goldens were per machine to begin with).
  FIXED_ENV = { "LC_ALL" => "C", "LANG" => "C" }.freeze
  FIXED_ENV_KEYS = %w[HOME].freeze

  def run_tool(exe, argv, chdir, aslr_off: true)
    exe = self.class.aslr_off + exe if aslr_off
    # In golden mode **python3 is not started**. That is the very claim of the golden work,
    # so the suite checks it structurally itself, not by tinkering with PATH.
    if MODE == "golden" && exe.any? { |x| File.basename(x.to_s) == "python3" }
      raise "tried to start python3 in golden mode: #{exe.inspect}"
    end

    env = { "PYTHONDONTWRITEBYTECODE" => "1", "TMPDIR" => chdir, "PATH" => FIXED_PATH }
    # The native rtcheck and the GC pass look at `LLVM` / `LLVM_PREFIX`. The default is
    # Mac's Homebrew, so Linux needs it explicit (the same value on both legs).
    %w[LLVM LLVM_PREFIX].each { |k| env[k] = ENV[k] if ENV[k] }
    FIXED_ENV_KEYS.each { |k| env[k] = ENV[k] if ENV[k] }
    env.merge!(FIXED_ENV)
    out, err, st = Open3.capture3(env, *exe, *argv, chdir: chdir, unsetenv_others: true)
    [out.dup.force_encoding(Encoding::BINARY),
     err.dup.force_encoding(Encoding::BINARY), st]
  end

  # Runs one leg. **Both legs write to `<dir>/out`**, and move it to `dest` after the run.
  # The spelling of the output dir leaks into the artifacts ((b) at the top), so this is a precondition
  # of the byte comparison.
  def run_leg(r, dir, work, tooldir, dest, aslr_off: true)
    odir = wants_outdir?(r) ? File.join(dir, "out") : nil
    if odir
      FileUtils.rm_rf(odir)
      FileUtils.mkdir_p(odir)
    end
    out, err, st = run_tool(tool_path(tooldir, r), argv_of(r, odir) + extra_argv(r), work,
                            aslr_off: aslr_off)
    FileUtils.mv(odir, dest) if odir
    [out, err, st, odir ? dest : nil]
  end

  # Copies a case's inputs into a temp dir. Both legs use **the same** dir as cwd.
  def prepare(r, dir)
    return dir if r["cwd"] == "-"

    FileUtils.cp_r(File.join(REPO, r["cwd"]) + "/.", dir)
    FileUtils.mkdir_p(File.join(dir, "spinel"))
    { "grad.rb" => "grad.rb", "grad_rules.rb" => "grad_rules.rb" }.each_key do |f|
      dst = File.join(dir, "spinel", f)
      FileUtils.cp(File.join(REPO, "tools/grad/spinel", f), dst) unless File.exist?(dst)
    end
    dir
  end

  # ---- 1. the table itself ----------------------------------------------------
  def test_case_table_is_the_declared_slice
    assert_equal SHAPE["cases"], rows.size, "case count"
    ids = rows.map { |r| r["id"] }
    assert_equal ids.uniq, ids, "duplicate ids"
    assert_equal SHAPE["pins"], pins.size, "pin count of identity.tsv"
    %w[searchgate gradgen].each do |t|
      assert_equal SHAPE[t], rows.count { |r| r["tool"] == t }, "row count of #{t}"
    end
    RCS.each { |c| refute_empty rows.select { |r| expect_rc(r) == c }, "no row for rc #{c}" }
    refute_empty rows.select { |r| tree_count(r) }, "no row compares a tree"
    refute_empty rows.select { |r| named_artifacts(r).any? }, "no row compares by name"
    rows.each do |r|
      assert_includes RCS, expect_rc(r), "#{r['id']}: expect_rc"
      assert_includes %w[searchgate gradgen], r["tool"], "#{r['id']}: tool"
      refute_empty r["note"], "#{r['id']}: the note is empty — write what the row exercises"
      next if r["cwd"] == "-"

      assert File.directory?(File.join(REPO, r["cwd"])), "#{r['id']}: the cwd is missing"
    end
    # The rows that pass `@OUT@` and **the rows that compare outputs** differ (`gg_die_absent` only makes
    # an empty dir). This says that both are present.
    refute_empty rows.select { |r| wants_outdir?(r) && r["artifacts"] == "-" },
                 "no row passes an output dir but has no outputs (the negative control)"
  end

  def test_pins_hold
    pins.each do |path, want|
      full = File.join(REPO, path)
      assert File.file?(full), "the pinned file is missing (#{path})"
      got = Digest::SHA256.hexdigest(File.binread(full))
      got = got.sub(/.\z/, "0") if PIN_DRIFT && path.end_with?("spinel/grad.rb")
      assert_equal want, got, "#{path}: the pin drifted — E171 only reads the frozen Python"
    end
  end

  # ---- 2. both implementations and the prerequisites are present -----------
  def test_both_implementations_are_present
    %w[spinel-gradgen spinel-searchgate].each do |t|
      # The frozen Python was retired (the golden fixture is the counterpart). It is needed only in the record / both
      # modes.
      assert File.file?(File.join(FROZEN_DIR, t)), "the frozen Python is missing (#{t})" unless MODE == "golden"
      assert File.executable?(File.join(RUBY_DIR, t)), "the Ruby #{t} is missing"
      first = File.open(File.join(RUBY_DIR, t), "rb") { |f| f.readline }
      assert_includes first, "ruby", "#{t} is not Ruby (#{first.strip})"
    end
  end

  def test_toolchain_is_present_not_skipped
    assert File.file?(ENZYME),
           "the Enzyme plugin is missing (#{ENZYME}) — docs/tools/enzyme.md. **Never green by a skip**"
    assert ENZYME.end_with?(DARWIN ? ".dylib" : ".so"), "the plugin's spelling on this OS"
    assert File.file?(GCPASS),
           "the GC pass is missing (#{GCPASS}) — see the build steps of tools/llvm/passes. **Never green by a skip**"
    assert File.executable?(File.join(REPO, "tools/realtime/spinel-rtcheck")),
           "rtcheck (E169, what G2 calls) is missing"
    assert File.executable?(File.join(REPO, "tools/contract/build/spinel-typedump")),
           "typedump (what G1 calls) is missing"
    assert File.executable?(File.join(REPO, "vendor/spinel/bin/spinel")), "the vendor's spinel is missing"
  end

  # ---- 3. the output dir rules are necessary and sufficient -----------------
  # Positive control: 2 runs into **the same dir path** match exactly. Without it, the green of (a)
  # could also come from "both legs having the same nondeterminism".
  def test_the_frozen_python_repeats_itself_into_the_same_directory
    # **A control that starts the frozen Python**, so it steps down in golden mode.
    skip "mode=#{MODE}" unless MODE == "both"

    r = rows.find { |x| x["id"] == "gg_e076_twoexits" }
    raise "gg_e076_twoexits is not in the corpus" if r.nil?

    Dir.mktmpdir("e171-det.") do |dir|
      work = prepare(r, dir)
      legs = %w[a b].map do |leg|
        out, err, st, dest = run_leg(r, dir, work, FROZEN_DIR, File.join(dir, leg))
        assert_equal expect_rc(r), st.exitstatus, "rc of the determinism control #{leg}\n#{show(err)}"
        [out, err, dest]
      end
      assert_equal legs[0][0], legs[1][0], "the frozen Python's stdout differs between runs"
      assert_equal legs[0][1], legs[1][1], "the frozen Python's stderr differs between runs"
      fa = files_under(legs[0][2])
      assert_equal fa, files_under(legs[1][2]), "the frozen Python's set of outputs differs between runs"
      assert_equal tree_count(r), fa.size, "tree count of the determinism control"
      fa.each do |f|
        assert_equal File.binread(File.join(legs[0][2], f)),
                     File.binread(File.join(legs[1][2], f)),
                     "the frozen Python's #{f} differs between runs (with the same dir path)"
      end
    end
  end

  # Negative control (b1): 2 runs into **different dir paths** give different `_diff.ll`. Different
  # even with ASLR off —— `_grad.ll` differs only in the 2 lines `ModuleID` / `source_filename`,
  # and `opt` is deterministic for that input, yet the length of the spelling shifts the allocations.
  # **When this control stops being green** (when Enzyme no longer depends on addresses), run_leg's
  # move becomes unnecessary. Rather than vanishing silently, this turns red to tell.
  def test_a_different_output_directory_changes_the_adjoint
    # **A control that starts the frozen Python**, so it steps down in golden mode.
    skip "mode=#{MODE}" unless MODE == "both"

    r = rows.find { |x| x["id"] == "gg_e076_demoB" }
    raise "gg_e076_demoB is not in the corpus" if r.nil?

    Dir.mktmpdir("e171-leak.") do |dir|
      work = prepare(r, dir)
      outs = %w[aa bbbbbb].map do |leg|
        odir = File.join(dir, leg)
        FileUtils.mkdir_p(odir)
        _o, err, st = run_tool(tool_path(FROZEN_DIR, r), argv_of(r, odir) + extra_argv(r), work)
        assert_equal expect_rc(r), st.exitstatus, "rc of the leak control #{leg}\n#{show(err)}"
        odir
      end
      # The difference on the input side (`_grad.ll`) is **only the 2 lines ModuleID / source_filename**.
      g = outs.map { |o| File.binread(File.join(o, "score_learn_grad.ll")).lines }
      only = (g[0] - g[1])
      assert_equal 2, only.size, "the _grad.ll difference is not 2 lines (#{only.size})"
      assert only.all? { |x| x.include?("ModuleID".b) || x.include?("source_filename".b) },
             "the _grad.ll difference is not only in ModuleID / source_filename"
      refute_equal File.binread(File.join(outs[0], "score_learn_diff.ll")),
                   File.binread(File.join(outs[1], "score_learn_diff.ll")),
                   "_diff.ll is the same with a different output dir — if the address dependence is gone, " \
                   "run_leg's move and this control itself can be folded (as E171 recorded)"
    end
  end

  # Negative control (b2): 2 runs into the same dir **without turning ASLR off** give different `_diff.ll`.
  # Only the frozen Python runs (the port has nothing to do with it), so this also shows that it does not
  # look like "a defect of the Ruby".
  def test_address_randomisation_alone_changes_the_adjoint
    # **A control that starts the frozen Python**, so it steps down in golden mode.
    skip "mode=#{MODE}" unless MODE == "both"

    skip "macOS has no way to turn ASLR off (an honest boundary)" if DARWIN

    r = rows.find { |x| x["id"] == "gg_e078_hvp" }
    raise "gg_e078_hvp is not in the corpus" if r.nil?

    Dir.mktmpdir("e171-aslr.") do |dir|
      work = prepare(r, dir)
      randomised = %w[r1 r2].map do |leg|
        _o, err, st, dest = run_leg(r, dir, work, FROZEN_DIR, File.join(dir, leg),
                                    aslr_off: false)
        assert_equal expect_rc(r), st.exitstatus, "rc of the ASLR control #{leg}\n#{show(err)}"
        dest
      end
      # The input (`_grad.ll`) is identical —— only Enzyme's output differs.
      assert_equal File.binread(File.join(randomised[0], "hvp_kernel_grad.ll")),
                   File.binread(File.join(randomised[1], "hvp_kernel_grad.ll")),
                   "ASLR control: the inputs passed to opt have come out different"
      refute_equal File.binread(File.join(randomised[0], "hvp_kernel_diff.ll")),
                   File.binread(File.join(randomised[1], "hvp_kernel_diff.ll")),
                   "the frozen Python matched itself without turning ASLR off — if the address dependence " \
                   "is gone, (b2) and this control can be folded (as E171 recorded)"
      # The positive control is exercised by test_the_frozen_python_repeats_itself_into_the_same_directory
      # above (ASLR off), but it is also paired here **with the same input**.
      steady = %w[s1 s2].map do |leg|
        _o, _e, _st, dest = run_leg(r, dir, work, FROZEN_DIR, File.join(dir, leg))
        dest
      end
      assert_equal File.binread(File.join(steady[0], "hvp_kernel_diff.ll")),
                   File.binread(File.join(steady[1], "hvp_kernel_diff.ll")),
                   "the frozen Python does not match itself even with ASLR off"
    end
  end

  # ---- E173: golden fixture ----------------------------------------------
  # Only the spelling of the work dir changes per run. The golden is kept **with that spelling masked**
  # (the diagnostics and the generated C name absolute paths). The address-dependent faces (`_diff.ll` on)
  # also depend on the **length** of the spelling, so the work dir itself is fixed (WORK_ROOT above).
  def mask_work(bytes, work, odir)
    b = bytes.gsub(odir.dup.force_encoding(Encoding::BINARY), "@OUT@".b)
    b.gsub(work.dup.force_encoding(Encoding::BINARY), "@WORK@".b)
  end

  # On darwin `/tmp` is a symlink to `/private/tmp`, and `spinel -S`'s `#line` and
  # rtcheck's paths get the realpath spelling. The declared work root's realpath is
  # **normalized to the recording (Linux) spelling** (not masking: it unifies another spelling of the declared root
  # into one. provenance's `@work_root=` is this spelling).
  def self.real_root
    FileUtils.mkdir_p(WORK_ROOT)
    File.realpath(WORK_ROOT)
  rescue StandardError
    WORK_ROOT
  end
  REAL_ROOT = real_root

  def unrealpath(bytes)
    return bytes if REAL_ROOT == WORK_ROOT

    bytes.gsub(REAL_ROOT.dup.force_encoding(Encoding::BINARY), WORK_ROOT.dup.force_encoding(Encoding::BINARY))
  end

  def unrealpath_tree!(adir)
    return if REAL_ROOT == WORK_ROOT || adir.nil? || !File.directory?(adir)

    Golden.files_under(adir).each do |rel|
      full = File.join(adir, rel)
      bytes = File.binread(full)
      next if bytes.include?("\0".b)   # binaries are not touched (paths appear only in text)

      fixed = unrealpath(bytes)
      File.binwrite(full, fixed) unless fixed == bytes
    end
  end

  def golden_leg(r, tooldir, dest)
    dir = File.join(WORK_ROOT, r["id"])
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    work = prepare(r, dir)
    out, err, st, adir = run_leg(r, dir, work, tooldir, dest)
    o = File.join(dir, "out")
    unrealpath_tree!(adir)
    [mask_work(unrealpath(out), dir, o), mask_work(unrealpath(err), dir, o), st.exitstatus, adir]
  end

  def test_record_the_golden
    skip "mode=#{MODE}" unless MODE == "record"

    # **Do not overwrite the base from another OS** (a safety valve).
    GOLDEN.guard_base_overwrite!(Golden.os_tag) unless GOLDEN.record_over?

    shas = []
    rows.each do |r|
      out, err, rc, adir = golden_leg(r, FROZEN_DIR, File.join(WORK_ROOT, r["id"], "py"))
      shas.concat(GOLDEN.record(r["id"], over: GOLDEN.record_over?, repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: adir, only: stable_only(adir)))
    end
    GOLDEN.write_shas(shas, over: GOLDEN.record_over?)
    GOLDEN.write_provenance(
      os: Golden.os_tag, python: Golden.python_version,
      frozen_sha: Golden.sha_list(REPO, FROZEN_FILES),
      # **The work root is recorded too**. Enzyme's output depends on the length of this spelling.
      inputs_sha: (Golden.sha_list(REPO, pins.map { |p, _| p }).split(";") +
                   ["@work_root=#{WORK_ROOT}", "@path=#{FIXED_PATH}",
                    "@repo=#{REPO}"]).sort.join(";"),
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
      out, err, rc, adir = golden_leg(r, FROZEN_DIR, File.join(WORK_ROOT, r["id"], "py2"))
      drift.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: adir, only: stable_only(adir)))
    end
    drift = drop_darwin_unstable(drift)
    # darwin's frozen Python (the system 3.9) spells argparse differently from the recording machine (Linux 3.13),
    # so **only the files overridden for darwin** are subject to drift
    # (on the shared side the Linux golden is true as it is). Undeclared differences are caught by the product check.
    if Golden.darwin?
      declared = rows.to_h { |r| [r["id"], os_specific_of(r)] }
      drift = drift.select do |m|
        id, rest = m.split(": ", 2)
        declared.fetch(id, []).any? { |g| rest.to_s.start_with?("#{g} ") }
      end
    end
    assert_empty drift, "the golden differs from the frozen tool's raw output (drift=#{drift.size})\n#{drift.join("\n")}"
  end

  # The work root at the time the golden was recorded must be the same as now.
  # **If not, everything from `_diff.ll` on always splits** (address dependence). Rather than turning red silently,
  # it stops and names the reason.
  def test_the_work_root_is_the_one_that_was_recorded
    skip "mode=#{MODE}" if MODE == "record"

    prov = File.readlines(GOLDEN.provenance_table, chomp: true, encoding: "UTF-8")
    row = prov.drop(1).map { |l| l.split("\t", -1) }.find { |c| c[1] == Golden.os_tag }
    refute_nil row, "provenance has no row for #{Golden.os_tag}"
    want = row[4].split(";").find { |kv| kv.start_with?("@work_root=") }
    refute_nil want, "provenance has no work root"
    wp = row[4].split(";").find { |kv| kv.start_with?("@path=") }
    refute_nil wp, "provenance has no PATH"
    assert_equal wp.sub("@path=", ""), FIXED_PATH,
                 "the child process's PATH differs from the recording. If env's byte count changes, " \
                 "opt's heap layout changes (measured). Match it with SPINEL_E171_PATH"
    assert_equal want.sub("@work_root=", ""), WORK_ROOT,
                 "the work root differs from the recording. Enzyme's output depends on the **length** of the output dir's spelling, " \
                 "so the golden matches only under the same root. " \
                 "Match it with SPINEL_E171_WORK, or record again with --record"
  end

  def test_the_golden_has_no_run_local_paths
    skip "mode=#{MODE}" if MODE == "record"

    # `WORK_ROOT` is a path **fixed and declared**, so it is excluded (that it does not change
    # per run is exercised by test_the_work_root_is_the_one_that_was_recorded).
    hits = Golden.scan_run_local(GOLDEN.base_dir, allow: [WORK_ROOT], repo: REPO)
    assert_empty hits, "a per-run path remains in the golden\n" +
                       hits.first(4).map { |f, i, l| "  #{f}:#{i} #{l}" }.join("\n")
  end

  def test_the_product_matches_the_golden
    skip "mode=#{MODE}" if MODE == "record"

    bad = []
    rows.each do |r|
      out, err, rc, adir = golden_leg(r, RUBY_DIR, File.join(WORK_ROOT, r["id"], "rb"))
      want = expect_rc(r)
      want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "sg_ok"
      assert_equal want, rc, "#{r['id']}: the Ruby rc differs from the table\n#{show(err)}"
      out = out + "\n".b if GOLDEN_DRIFT && r["id"] == rows.first["id"]
      bad.concat(GOLDEN.check(r["id"], repo: REPO, os_specific: os_specific_of(r), out: out, err: err, rc: rc, artifacts_dir: adir, only: stable_only(adir)))
    end
    bad = drop_darwin_unstable(bad)
    assert_empty bad, "differs from the golden (#{bad.size})\n#{bad.join("\n")}"
  end

  # ---- 4. the whole corpus ------------------------------------------------------
  # **No spelling is masked**. Both legs write to the same `<dir>/out`, and after the run it is moved
  # to `py/` `rb/` (run_leg). Raw bytes are compared.
  def test_ruby_matches_the_frozen_python
    skip "mode=#{MODE}" unless MODE == "both"

    checked = 0
    rows.each do |r|
      next if ONLY_TOOL && r["tool"] != ONLY_TOOL

      Dir.mktmpdir("e171-#{r['id']}.") do |dir|
        work = prepare(r, dir)
        pout, perr, pst, pdir = run_leg(r, dir, work, FROZEN_DIR, File.join(dir, "py"))
        rout, rerr, rst, rdir = run_leg(r, dir, work, RUBY_DIR, File.join(dir, "rb"))
        want = expect_rc(r)
        want = (want.zero? ? 1 : 0) if CLASS_DRIFT && r["id"] == "sg_ok"
        assert_equal want, pst.exitstatus,
                     "#{r['id']}: the frozen Python's rc differs from the table\n#{show(perr)}"
        assert_equal want, rst.exitstatus,
                     "#{r['id']}: the Ruby rc differs from the table\n#{show(rerr)}"
        assert_equal pout, rout,
                     "#{r['id']}: stdout\n--- python\n#{show(pout)}--- ruby\n#{show(rout)}"
        assert_equal perr, rerr,
                     "#{r['id']}: stderr\n--- python\n#{show(perr)}--- ruby\n#{show(rerr)}"
        unless pdir.nil?
          pf = files_under(pdir)
          rf = files_under(rdir)
          assert_equal pf, rf, "#{r['id']}: the sets of relative output paths differ"
          if (n = tree_count(r))
            assert_equal n, pf.size, "#{r['id']}: the tree count differs from the table's declaration"
          else
            assert_equal named_artifacts(r).sort, pf, "#{r['id']}: the output names"
          end
          pf.each do |f|
            assert_equal File.binread(File.join(pdir, f)), File.binread(File.join(rdir, f)),
                         "#{r['id']}: #{f} differs by bytes"
          end
        end
        checked += 1
      end
    end
    assert_operator checked, :>, 0, "not a single case was compared"
  end
end
