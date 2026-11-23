# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/test_mlir_object_shadow.rb
#
# E154 checkpoint 3 (P013 Task 7): **現行 .bpf.o と MLIR .bpf.o の意味比較。**
#
#   .ir/.ast -> spinel_ebpf_cc -> .bpf.c -> clang        -> 現行 .bpf.o
#            -> 宣言 manifest -> schema.json + .mlir
#                             -> spbpf-compile           -> MLIR .bpf.o
#
# 両方を同じ reader (SpinelEbpf::BpfObject) に通して比べる。
#
# checkpoint 2 (宣言 manifest vs .bpf.c 本文) は test_mlir_shadow.rb が持つ。
# **どちらも独立した gate** で、片方が他方を含むわけではない:
#   checkpoint 2 は record / field offset を覆い、object には載らない。
#   checkpoint 3 は実際の成果物同士を覆い、宣言と emit の両方を経由する。
#
# 対象は 24_xdp_counter の垂直スライス。spbpf dialect が受け付ける program 種別が
# xdp だけ (`kProgramKinds[] = {"xdp"}`) なので、範囲はそこで決まっている。

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

require "spinel_ebpf/mlir_backend"
require "spinel_ebpf/bpf_object"

class MlirObjectShadowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  XDP  = "24_xdp_counter"
  EMIT = "22_emit_pair"

  def ir(f)  = File.join(ROOT, "tests", "fixtures", "#{f}.ir")
  def ast(f) = File.join(ROOT, "tests", "fixtures", "#{f}.ast")
  def base(f) = "u_#{f}"

  # **正式 gate では道具の不在を skip にしない。** 開発中は skip でよいが、
  # SPNL_SHADOW_GATE=1 のときは前提不足として落とす。
  def setup
    missing = []
    missing << "codegen (make -C src/codegen_c)" unless File.executable?(SpinelEbpf::MlirBackend.codegen_path)
    missing << "spbpf-compile (SPNL_SPBPF_COMPILE)" unless File.executable?(SpinelEbpf::MlirBackend.spbpf_path)
    missing << "spnl_spbpf_schema_check (tools/build_spbpf_schema_check.sh)" unless File.executable?(SpinelEbpf::MlirBackend.schema_check_path)
    missing << "clang" unless system("#{SpinelEbpf::MlirBackend.clang_path} --version >/dev/null 2>&1")
    missing << "bpftool" unless system("bpftool version >/dev/null 2>&1")
    missing << "llvm-objdump" unless system("llvm-objdump --version >/dev/null 2>&1")
    return if missing.empty?
    flunk "gate モードなのに前提が無い: #{missing.join(", ")}" if ENV["SPNL_SHADOW_GATE"] == "1"
    skip "object 差動の前提が無い: #{missing.join(", ")}"
  end

  # ---------- 本体 ----------

  # **現行 object と MLIR object の意味が一致すること。**
  def test_objects_agree_on_declared_meaning
    cur, mlir = SpinelEbpf::MlirBackend.both_meanings(ir(XDP), ast(XDP), base(XDP))
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert_empty diff,
      "現行 .bpf.o と MLIR .bpf.o の意味が食い違う:\n" +
      diff.map { |d| "  #{d[:what]}: current=#{d[:current].inspect} mlir=#{d[:mlir].inspect}" }.join("\n")
  end

  # 比較が空同士で緑になっていないことの対照。**両側とも中身がある**こと。
  def test_both_sides_actually_carry_meaning
    cur, mlir = SpinelEbpf::MlirBackend.both_meanings(ir(XDP), ast(XDP), base(XDP))
    [["current", cur], ["mlir", mlir]].each do |who, m|
      assert_equal 1, m[:programs].size, "#{who}: program が読めていない"
      assert_equal 1, m[:maps].size, "#{who}: map が読めていない"
      assert_equal "xdp__main", m[:programs][0][:name], who
      assert_equal 2, m[:programs][0][:verdict], "#{who}: XDP_PASS = 2 が object から読めること"
      # **map effect が両側から読めていること** (Mac の指摘 2026-08-25: 宣言と
      # verdict の外形だけの stub を「同じ意味」と呼ばない)。@rx_pkts += 1 は
      # lookup -> update で、map への参照は 2 命令 (lookup の引数と update の引数)。
      assert_equal({ helpers: %w[map_lookup_elem map_update_elem],
                     map_refs: { "u_#{XDP}_top_rx_pkts" => 2 } },
                   m[:programs][0][:effects],
                   "#{who}: counter body の map effect が object から読めること")
      assert_equal "u_#{XDP}_top_rx_pkts", m[:maps][0][:symbol], who
      assert_equal "hash", m[:maps][0][:kind], who
      assert_equal "u32", m[:maps][0][:key], who
      assert_equal "s64", m[:maps][0][:value], who
      assert_equal 1, m[:maps][0][:max_entries], who
    end
  end

  # ---------- E155: record を運ぶ slice (187_xdp_emit_pair) ----------

  PAIR = "187_xdp_emit_pair"

  # **emit_pair unit で現行 object と MLIR object の意味が一致すること。**
  # record は :carried_only + manifest witness 照合 (MlirBackend.diff が束ねる)。
  def test_emit_pair_objects_agree
    diff = SpinelEbpf::MlirBackend.diff(ir(PAIR), ast(PAIR), base(PAIR))
    assert_empty diff,
      "187 の意味が食い違う:\n" +
      diff.map { |d| "  #{d[:what]}: current=#{d[:current].inspect} mlir=#{d[:mlir].inspect}" }.join("\n")
  end

  # MLIR object は record witness を **常に**運ぶ (現行 object は運べない — 実測)。
  def test_emit_pair_mlir_object_carries_the_record_witness
    m = SpinelEbpf::MlirBackend.meaning(ir(PAIR), ast(PAIR), base(PAIR))
    rec = m[:records].find { |r| r[:symbol] == "u_#{PAIR}_pair_event" }
    refute_nil rec, "MLIR object の BTF に record が無い"
    assert_equal 32, rec[:size]
    assert_equal [["hdr", 0], ["a", 16], ["b", 24]],
                 rec[:fields].map { |f| [f[:name], f[:offset]] }
  end

  # 変異: record の field 型を manifest 側で変える -> witness 照合が赤になる。
  # (layout は 32B のままなので、witness 照合が「型」まで見ていないと緑に見える形)
  def test_mutating_a_record_field_type_is_caught_by_the_witness_diff
    m = SpinelEbpf::MlirBackend.manifest(ir(PAIR), ast(PAIR), base(PAIR))
    good = Dir.mktmpdir("spnl-wit") { |d| SpinelEbpf::BpfObject.meaning(SpinelEbpf::MlirBackend.compile_mlir(m, base(PAIR), d)) }
    mutated = JSON.parse(JSON.generate(m))
    mutated["records"][0]["fields"].find { |f| f["name"] == "b" }["ctype"] = "__u64"
    diff = SpinelEbpf::MlirBackend.record_witness_diff(mutated, good, "mut")
    assert diff.any? { |d| d[:what].include?("type of record") },
      "field 型の変異を witness 照合が捕まえない: #{diff.inspect}"
  end

  # 変異: body を落とす -> helper 列 (reserve/ktime/submit) が消えて赤になる。
  def test_dropping_the_emit_body_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(PAIR), ast(PAIR), base(PAIR))
    m = SpinelEbpf::MlirBackend.manifest(ir(PAIR), ast(PAIR), base(PAIR))
    m["programs"][0]["body"]["steps"] = []
    mlir = Dir.mktmpdir("spnl-drop") { |d| SpinelEbpf::BpfObject.meaning(SpinelEbpf::MlirBackend.compile_mlir(m, base(PAIR), d)) }
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir, records: :carried_only)
    assert diff.any? { |d| d[:what].include?("helper call sequence") },
      "emit body を落とした変異を差動が捕まえない: #{diff.inspect}"
  end

  # ---------- 変異試験 (恒久) ----------
  #
  # **MLIR object 側に変異を入れて、差動が赤になること。** manifest を書き換えて
  # から spbpf-compile を通すので、比べているのは本物の別 object である
  # (Ruby の hash を書き換えるだけの変異では、object を作る経路が死んでいても
  #  緑に見えてしまう)。

  def mutated_mlir_meaning(&mutate)
    m = SpinelEbpf::MlirBackend.manifest(ir(XDP), ast(XDP), base(XDP))
    mutate.call(m)
    Dir.mktmpdir("spnl-mut") do |dir|
      obj = SpinelEbpf::MlirBackend.compile_mlir(m, base(XDP), dir)
      SpinelEbpf::BpfObject.meaning(obj)
    end
  end

  def test_mutating_max_entries_in_the_mlir_object_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(XDP), ast(XDP), base(XDP))
    mlir = mutated_mlir_meaning { |m| m["maps"][0]["max_entries"] += 1 }
    assert_equal 2, mlir[:maps][0][:max_entries], "変異が MLIR object に届いていない"
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert diff.any? { |d| d[:what].include?("max_entries") },
      "max_entries の変異を差動が捕まえない: #{diff.inspect}"
  end

  def test_mutating_verdict_in_the_mlir_object_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(XDP), ast(XDP), base(XDP))
    mlir = mutated_mlir_meaning { |m| m["programs"][0]["verdict"] = 1 }   # XDP_PASS -> XDP_DROP
    assert_equal 1, mlir[:programs][0][:verdict], "変異が MLIR object に届いていない"
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert diff.any? { |d| d[:what].include?("verdict") },
      "verdict の変異を差動が捕まえない: #{diff.inspect}"
  end

  def test_mutating_the_map_key_type_in_the_mlir_object_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(XDP), ast(XDP), base(XDP))
    mlir = mutated_mlir_meaning { |m| m["maps"][0]["key"] = "__u64" }
    assert_equal "u64", mlir[:maps][0][:key], "変異が MLIR object に届いていない"
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert diff.any? { |d| d[:what].include?("key") },
      "key 型の変異を差動が捕まえない: #{diff.inspect}"
  end

  # **program body を落とした object (宣言と verdict の外形は同じ) が赤になること。**
  # E154 の最初の MLIR backend はまさにこの形の stub を出しており、宣言 + verdict
  # だけの差動はそれを緑にしていた (Mac の指摘 2026-08-25)。この変異が緑に戻ったら、
  # 差動はまた「外形だけの比較」に退行している。
  def test_dropping_the_program_body_from_the_mlir_object_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(XDP), ast(XDP), base(XDP))
    mlir = mutated_mlir_meaning { |m| m["programs"][0]["body"]["steps"] = [] }
    assert_equal({ helpers: [], map_refs: {} }, mlir[:programs][0][:effects],
      "変異が MLIR object に届いていない (body が残っている)")
    assert_equal 2, mlir[:programs][0][:verdict],
      "この変異は verdict を守る — verdict 比較だけでは捕まらない形であること"
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert diff.any? { |d| d[:what].include?("helper call sequence") },
      "body を落とした変異を差動が捕まえない: #{diff.inspect}"
    assert diff.any? { |d| d[:what].include?("map references") },
      "map 参照の消失を差動が捕まえない: #{diff.inspect}"
  end

  # body を分類できていない manifest から object を作らないこと。
  def test_unclassified_body_stops_instead_of_emitting_a_stub
    m = SpinelEbpf::MlirBackend.manifest(ir(XDP), ast(XDP), base(XDP))
    m["programs"][0]["body"] = { "state" => "unknown" }
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      Dir.mktmpdir("spnl-unk") { |dir| SpinelEbpf::MlirBackend.compile_mlir(m, base(XDP), dir) }
    end
    assert_match(/body/, err.message)
  end

  def test_mutating_the_program_name_in_the_mlir_object_is_caught
    cur = SpinelEbpf::MlirBackend.current_meaning(ir(XDP), ast(XDP), base(XDP))
    mlir = mutated_mlir_meaning { |m| m["programs"][0]["name"] = "xdp__other" }
    assert_equal "xdp__other", mlir[:programs][0][:name], "変異が MLIR object に届いていない"
    diff = SpinelEbpf::MlirShadow.diff(cur, mlir)
    assert diff.any? { |d| d[:what].include?("presence of") },
      "program 名の変異を差動が捕まえない: #{diff.inspect}"
  end

  # ---------- object reader そのもの ----------

  # **綴りではなく ABI の意味で比べていること。** 現行 object は
  # TYPEDEF '__u32' -> INT 'unsigned int'、MLIR object は INT 'u32' で綴りが違う。
  # 綴りで比べる reader なら上の一致テストが落ちるので、ここは念押しの証明。
  def test_reader_normalises_typedef_spellings
    Dir.mktmpdir("spnl-spell") do |dir|
      cur_obj = SpinelEbpf::MlirBackend.compile_current(ir(XDP), ast(XDP), base(XDP), dir)
      raw = `bpftool btf dump file #{cur_obj} format raw 2>/dev/null`
      assert_includes raw, "TYPEDEF '__u32'", "現行 object は typedef の綴りを持つ"
      assert_equal "u32", SpinelEbpf::BpfObject.meaning(cur_obj)[:maps][0][:key],
        "typedef を解いて (bit 幅, 符号) へ正規化すること"
    end
  end

  # ring buffer / percpu_array を **実物の object から**読めること。
  # (XDP fixture だけだと map 種別が hash 1 つしか通らない)
  def test_reader_reads_ringbuf_and_percpu_from_a_real_object
    Dir.mktmpdir("spnl-emit") do |dir|
      obj = SpinelEbpf::MlirBackend.compile_current(ir(EMIT), ast(EMIT), base(EMIT), dir)
      m = SpinelEbpf::BpfObject.meaning(obj)
      syms = m[:maps].to_h { |x| [x[:symbol], x] }
      assert_equal "percpu_array", syms["u_#{EMIT}_lost"][:kind]
      rb = syms["u_#{EMIT}_pair_events"]
      assert_equal "ringbuf", rb[:kind]
      assert_equal 256 * 1024, rb[:max_entries]
      assert_equal ["u_#{EMIT}_pair_events"], m[:ringbufs]
      # 観測型なので verdict を持たない。
      assert_nil m[:programs][0][:verdict]
      assert_equal "tracepoint/sched/sched_switch", m[:programs][0][:attach]
    end
  end

  # ---------- 対象外の扱い ----------

  # **範囲外は緑にしない。** tracepoint は spbpf dialect が扱えないので停止する。
  def test_out_of_slice_program_kind_stops
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirBackend.meaning(ir(EMIT), ast(EMIT), base(EMIT))
    end
    assert_match(/tracepoint|record/, err.message)
  end

  # **道具が無いことを成功扱いにしない。**
  def test_missing_spbpf_compile_is_loud
    old = ENV["SPNL_SPBPF_COMPILE"]
    ENV["SPNL_SPBPF_COMPILE"] = "/nonexistent/spbpf-compile"
    err = assert_raises(SpinelEbpf::MlirShadow::ShadowError) do
      SpinelEbpf::MlirBackend.meaning(ir(XDP), ast(XDP), base(XDP))
    end
    assert_includes err.message, "spbpf-compile"
  ensure
    ENV["SPNL_SPBPF_COMPILE"] = old
  end

  # ---------- libspbpf C ABI 検証段 (in-process consumer 境界) ----------
  #
  # compile_mlir は生成した schema JSON を **libspbpf の C ABI** (spinel-llvm の
  # 静的 library をリンクした build/tools/spnl_spbpf_schema_check) に通してから
  # spbpf-compile を呼ぶ。以下はその段が経路上に実在することの証明。

  def test_missing_schema_check_is_loud
    old = ENV["SPNL_SPBPF_SCHEMA_CHECK"]
    ENV["SPNL_SPBPF_SCHEMA_CHECK"] = "/nonexistent/spnl_spbpf_schema_check"
    err = assert_raises(SpinelEbpf::MlirShadow::ShadowError) do
      SpinelEbpf::MlirBackend.meaning(ir(XDP), ast(XDP), base(XDP))
    end
    assert_includes err.message, "spnl_spbpf_schema_check"
  ensure
    ENV["SPNL_SPBPF_SCHEMA_CHECK"] = old
  end

  def test_schema_check_rejection_stops_the_mlir_path
    old = ENV["SPNL_SPBPF_SCHEMA_CHECK"]
    ENV["SPNL_SPBPF_SCHEMA_CHECK"] = "/bin/false"   # 常に拒否する検証器
    err = assert_raises(SpinelEbpf::MlirShadow::ShadowError) do
      SpinelEbpf::MlirBackend.meaning(ir(XDP), ast(XDP), base(XDP))
    end
    assert_includes err.message, "schema check",
      "検証段が MLIR 経路の上に無い (拒否されても object が作られている)"
  ensure
    ENV["SPNL_SPBPF_SCHEMA_CHECK"] = old
  end

  # 検証器そのものが**正典 parser として振る舞う**こと: coverage を欠いた schema
  # (E153 で必須化) を in-process の C ABI が拒否する。
  def test_schema_check_binary_rejects_a_schema_without_coverage
    chk = SpinelEbpf::MlirBackend.schema_check_path
    Dir.mktmpdir("spnl-chk") do |dir|
      bad = File.join(dir, "bad.json")
      File.write(bad, JSON.generate({ "version" => 1 }))
      out, err, st = Open3.capture3(chk, bad)
      assert_equal 1, st.exitstatus, "coverage の無い schema を受理した: #{out}"
      assert_includes err, "coverage"
    end
  end

  def test_missing_input_is_loud
    assert_raises(SpinelEbpf::MlirShadow::ShadowError) do
      SpinelEbpf::MlirBackend.meaning("/nonexistent.ir", "/nonexistent.ast", "u_x")
    end
  end

  # ---------- 製品 CLI への配線 ----------
  #
  # **既定経路 / shadow / 採用の 3 つが実際に配線されていること。**
  # 単体で緑でも CLI から到達できなければ、機能は存在しないのと同じ (E423 の形)。

  CLI = File.join(ROOT, "bin", "spinel-ebpf")

  def cli_build(fixture, env, dir)
    rb = File.join(ROOT, "tests", "fixtures", "#{fixture}.rb")
    out, err, st = Open3.capture3(env, CLI, "compile", rb, "-o", dir, "--build")
    [out + err, st]
  end

  def cli_ready?
    File.executable?(CLI) && !SpinelEbpf::MlirBackend.spbpf_path.nil? &&
      File.executable?(SpinelEbpf::MlirBackend.spbpf_path) &&
      system("bpftool version >/dev/null 2>&1")
  end

  # 3 モードを 1 回のビルドずつで見る (--build は重いので 1 テストにまとめる)。
  def test_cli_wires_all_three_modes
    skip "CLI ビルドの前提が無い" unless cli_ready?
    Dir.mktmpdir("spnl-cli") do |dir|
      modes = {
        "plain"  => {},
        "shadow" => { "SPNL_BPF_SHADOW" => "1" },
        "adopt"  => { "SPNL_BPF_BACKEND" => "mlir" },
      }
      objs = {}
      modes.each do |name, env|
        d = File.join(dir, name)
        log, st = cli_build(XDP, env, d)
        assert st.success?, "#{name} のビルドが失敗した:\n#{log}"
        objs[name] = File.join(d, "#{XDP}.bpf.o")
        assert File.exist?(objs[name]), "#{name}: .bpf.o が無い"
      end

      # **既定経路の .bpf.c は 3 モードで byte-identical。**
      plain_c = File.read(File.join(dir, "plain", "#{XDP}.bpf.c"))
      %w[shadow adopt].each do |m|
        assert_equal plain_c, File.read(File.join(dir, m, "#{XDP}.bpf.c")),
          "#{m}: 既定経路の .bpf.c が変わった"
      end

      # 既定経路では manifest も MLIR object も作られない (副作用ゼロ)。
      refute File.exist?(File.join(dir, "plain", "#{XDP}.manifest.json")),
        "フラグ未設定なのに manifest が書かれた"
      refute File.exist?(File.join(dir, "plain", "#{XDP}.mlir.bpf.o")),
        "フラグ未設定なのに MLIR object が作られた"

      # shadow は比較するが **採用しない**。
      assert_equal File.binread(objs["plain"]), File.binread(objs["shadow"]),
        "shadow モードが object を差し替えている (採用は BACKEND=mlir の仕事)"

      # 採用モードは MLIR object を据える。
      refute_equal File.binread(objs["plain"]), File.binread(objs["adopt"]),
        "BACKEND=mlir なのに現行 object のままになっている"
      # 据えたものが本当に MLIR 由来か: spbpf の FILE symbol が居る。
      assert_includes `readelf -sW #{objs["adopt"]} 2>/dev/null`, "spbpf",
        "採用された object が spbpf 由来でない"
    end
  end

  # **範囲外の unit で shadow を頼まれたら黙って通さない。**
  def test_cli_refuses_to_pretend_on_an_out_of_slice_unit
    skip "CLI ビルドの前提が無い" unless cli_ready?
    Dir.mktmpdir("spnl-cli-oos") do |dir|
      log, st = cli_build(EMIT, { "SPNL_BPF_SHADOW" => "1" }, dir)
      refute st.success?, "対象範囲外なのにビルドが成功した (比較できなかったのに緑)"
      assert_includes log, "outside E154's scope"
    end
  end

  # ---------- verdict を命令列から読む規則 ----------

  # 到達しうる verdict が 1 つに定まらないときは :dynamic。**どれかを選ばない。**
  def test_verdict_reader_reports_dynamic_when_exits_disagree
    skip "llvm-objdump が無い" unless system("llvm-objdump --version >/dev/null 2>&1")
    # 2 つの exit がそれぞれ別の定数を返す object を手で組む。
    Dir.mktmpdir("spnl-vd") do |dir|
      src = File.join(dir, "two.bpf.c")
      File.write(src, <<~C)
        #define SEC(N) __attribute__((section(N), used))
        char _license[] SEC("license") = "GPL";
        SEC("xdp") int xdp__main(void *ctx) {
          volatile int x = *(volatile int *)&ctx;
          if (x) return 1;
          return 2;
        }
      C
      obj = File.join(dir, "two.bpf.o")
      _, st = Open3.capture2e(SpinelEbpf::MlirBackend.clang_path, "-O2", "-g", "-target", "bpf",
                              "-mcpu=v1", "-c", src, "-o", obj)
      skip "対照用の object を作れない" unless st.success?
      assert_equal :dynamic, SpinelEbpf::BpfObject.meaning(obj)[:programs][0][:verdict],
        "別の定数を返す exit が 2 つあるなら :dynamic — どちらかを既定値にしない"
    end
  end
end
