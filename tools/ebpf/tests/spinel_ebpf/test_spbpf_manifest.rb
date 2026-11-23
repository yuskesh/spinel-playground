# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/test_spbpf_manifest.rb
#
# E154 (P013 Task 7): **宣言 manifest そのもの**の検査。
#
# manifest は「1 回の codegen 呼び出しの間だけ生きる宣言の記録」であって、
# 新しい正典ではない。ここで見るのは:
#   - 既定経路の .bpf.c が manifest の有無で byte-identical であること
#   - 連続生成で前回の宣言が混入しないこと
#   - 重複 symbol を登録時に拒否すること
#   - XDP / emit fixture の manifest 内容が宣言どおりであること
#   - 登録できなかった宣言カテゴリを黙って欠落させないこと

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

class SpbpfManifestTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CC   = File.join(ROOT, "build", "codegen_c", "spinel_ebpf_cc")
  XDP  = "24_xdp_counter"
  EMIT = "22_emit_pair"

  def setup
    return if File.executable?(CC)
    flunk "gate モードなのに codegen が建っていない: #{CC}" if ENV["SPNL_SHADOW_GATE"] == "1"
    skip "codegen が建っていない (make -C src/codegen_c)"
  end

  def run_cc(fixture, env = {})
    ir  = File.join(ROOT, "tests", "fixtures", "#{fixture}.ir")
    ast = File.join(ROOT, "tests", "fixtures", "#{fixture}.ast")
    out, err, st = Open3.capture3(env, CC, ir, ast, "u_#{fixture}")
    [out, err, st]
  end

  def manifest_for(fixture, dir)
    path = File.join(dir, "#{fixture}.json")
    out, err, st = run_cc(fixture, { "SPNL_BPF_SHADOW" => "1", "SPNL_BPF_MANIFEST" => path })
    assert st.success?, "codegen が失敗した: #{err}"
    assert File.exist?(path), "manifest が書かれていない (stderr: #{err})"
    [JSON.parse(File.read(path)), out]
  end

  # ---------- 既定経路が変わらないこと ----------

  # **manifest の有無で .bpf.c が 1 バイトも変わらない。**
  def test_default_output_is_byte_identical
    Dir.mktmpdir do |dir|
      [XDP, EMIT].each do |f|
        plain, _, st = run_cc(f)
        assert st.success?
        with, = manifest_for(f, dir)
        _ = with
        shadowed, _, st2 = run_cc(f, { "SPNL_BPF_SHADOW" => "1",
                                       "SPNL_BPF_MANIFEST" => File.join(dir, "x.json") })
        assert st2.success?
        assert_equal plain, shadowed, "#{f}: manifest を出すと .bpf.c が変わった"
      end
    end
  end

  # フラグ未設定なら manifest は書かれない (既定経路に副作用を作らない)。
  def test_manifest_is_not_written_without_the_flag
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nope.json")
      _, _, st = run_cc(XDP, { "SPNL_BPF_MANIFEST" => path })
      assert st.success?
      refute File.exist?(path), "フラグ未設定なのに manifest が書かれた"
    end
  end

  # ---------- 宣言が混入しないこと ----------

  # **別プロセスで**別 fixture を生成したとき、宣言が混ざらないこと。
  #
  # 注: これは **プロセスを跨いだ**確認であって、in-process の static 状態の
  # 混入は検査できない (Mac 検収の指摘)。同一プロセス内の寿命は
  # tests/codegen_c/manifest_lifecycle.c が見る (`make -C src/codegen_c
  # manifest-lifecycle`)。
  def test_no_declaration_leaks_between_units_across_processes
    Dir.mktmpdir do |dir|
      a, = manifest_for(XDP, dir)
      b, = manifest_for(EMIT, dir)
      a_syms = a["maps"].map { |m| m["symbol"] } + a["records"].map { |r| r["symbol"] }
      b_syms = b["maps"].map { |m| m["symbol"] } + b["records"].map { |r| r["symbol"] }
      assert_empty(a_syms & b_syms, "2 つの unit の宣言が混ざっている")
      assert a_syms.all? { |s| s.start_with?("u_#{XDP}") }, "XDP 側に他 unit の宣言: #{a_syms}"
      assert b_syms.all? { |s| s.start_with?("u_#{EMIT}") }, "emit 側に他 unit の宣言: #{b_syms}"
    end
  end

  # ---------- manifest の中身 ----------

  def test_xdp_manifest_contents
    Dir.mktmpdir do |dir|
      m, = manifest_for(XDP, dir)
      assert_equal "u_#{XDP}", m["unit"]
      assert_equal 1, m["programs"].size
      p = m["programs"][0]
      assert_equal "xdp__main", p["name"]
      assert_equal "xdp", p["sec"]
      assert_equal "xdp", p["kind"]
      assert_equal true, p["has_verdict"], "XDP は enforcement 型"
      assert_equal 1, m["maps"].size
      mp = m["maps"][0]
      assert_equal "u_#{XDP}_top_rx_pkts", mp["symbol"]
      assert_equal "hash", mp["kind"]
      assert_equal "__u32", mp["key"]
      assert_equal "__s64", mp["value"]
      assert_equal 1, mp["max_entries"]
      assert_empty m["records"]
    end
  end

  def test_emit_manifest_contents
    Dir.mktmpdir do |dir|
      m, = manifest_for(EMIT, dir)
      p = m["programs"][0]
      assert_equal "tracepoint__sched__sched_switch", p["name"]
      assert_equal "tracepoint/sched/sched_switch", p["sec"]
      assert_equal false, p["has_verdict"], "tracepoint は観測型 — verdict を持たない"
      assert_nil p["verdict"]

      syms = m["maps"].to_h { |x| [x["symbol"], x] }
      lost = syms["u_#{EMIT}_lost"]
      refute_nil lost, "テンプレート由来の lost map が登録されていない: #{syms.keys}"
      assert_equal "percpu_array", lost["kind"]

      rb = syms["u_#{EMIT}_pair_events"]
      refute_nil rb, "テンプレート由来の ring buffer が登録されていない"
      assert_equal "ringbuf", rb["kind"]
      assert_equal 256 * 1024, rb["max_entries"]
      assert_equal "u_#{EMIT}_pair_event", rb["record"], "ring buffer が運ぶ record が結ばれていない"

      rec = m["records"].find { |r| r["symbol"] == "u_#{EMIT}_pair_event" }
      refute_nil rec, "record が登録されていない"
      assert_equal %w[hdr a b], rec["fields"].map { |f| f["name"] }
      assert_equal ["struct spnl_event_hdr", "__s64", "__s64"], rec["fields"].map { |f| f["ctype"] }
    end
  end

  # ---------- enforcement verdict ----------
  #
  # 「分からない」を既定値へ倒さない。4 状態を明示する:
  #   none (観測型) / known (末尾が既知定数) / dynamic (非定数) / unknown (解釈不能)

  def verdict_of(fixture, dir, program = nil)
    m, = manifest_for(fixture, dir)
    p = program ? m["programs"].find { |x| x["name"] == program } : m["programs"][0]
    refute_nil p, "program が manifest に無い: #{m["programs"].map { |x| x["name"] }}"
    p
  end

  # XDP の直接定数 (XDP_PASS = 2)
  def test_verdict_xdp_direct_constant
    Dir.mktmpdir do |dir|
      p = verdict_of(XDP, dir)
      assert_equal true, p["has_verdict"]
      assert_equal 2, p["verdict"], "XDP_PASS は 2"
    end
  end

  # ConstantPath 形式 (XDP::PASS) — parent 鎖を辿って解決すること
  def test_verdict_xdp_constant_path
    ir = File.join(ROOT, "tests", "fixtures", "173_user_cmd_reactor.ir")
    skip "ConstantPath fixture が無い" unless File.exist?(ir)
    Dir.mktmpdir do |dir|
      p = verdict_of("173_user_cmd_reactor", dir, "xdp__main")
      assert_equal 2, p["verdict"], "XDP::PASS も 2 に解決されること"
    end
  end

  # 観測型は verdict を持たない
  def test_verdict_tracepoint_is_none
    Dir.mktmpdir do |dir|
      p = verdict_of(EMIT, dir)
      assert_equal false, p["has_verdict"]
      assert_nil p["verdict"]
    end
  end

  # enforcement の非定数末尾 -> dynamic
  def test_verdict_dynamic
    ir = File.join(ROOT, "tests", "fixtures", "64_xsk_dev_redirect.ir")
    skip "dynamic fixture が無い" unless File.exist?(ir)
    Dir.mktmpdir do |dir|
      p = verdict_of("64_xsk_dev_redirect", dir, "xdp__redir")
      assert_equal true, p["has_verdict"]
      assert_equal "dynamic", p["verdict"]
    end
  end

  # **monitor 対象では body ではなく wrapper が実際に返す allow 値が入る。**
  def test_verdict_monitor_uses_the_wrapper_value
    ir = File.join(ROOT, "tests", "fixtures", "58_lsm_fmod.ir")
    skip "lsm fixture が無い" unless File.exist?(ir)
    Dir.mktmpdir do |dir|
      normal = File.join(dir, "n.json")
      _, err, st = run_cc("58_lsm_fmod", { "SPNL_BPF_SHADOW" => "1", "SPNL_BPF_MANIFEST" => normal })
      assert st.success?, err
      n = JSON.parse(File.read(normal))["programs"].find { |x| x["name"] == "fmod_ret__security_file_open" }
      assert_equal "dynamic", n["verdict"], "通常ビルドでは body 由来 (非定数)"

      mon = File.join(dir, "m.json")
      _, err2, st2 = run_cc("58_lsm_fmod", { "SPNL_ENFORCEMENT" => "monitor",
                                             "SPNL_BPF_SHADOW" => "1",
                                             "SPNL_BPF_MANIFEST" => mon })
      assert st2.success?, err2
      m = JSON.parse(File.read(mon))["programs"].find { |x| x["name"] == "fmod_ret__security_file_open" }
      assert_equal 0, m["verdict"],
        "monitor では wrapper が返す allow 定数 (0) が入ること — body 末尾ではない"
    end
  end

  # ---------- 欠落した整数 field を既定値へ倒さない ----------
  #
  # nt_int() は field が無いと既定値を返す。IntegerNode.value をそれで読むと、
  # 壊れた AST が「0 を返す program」= XDP_ABORTED に見えてしまう
  # (Mac の指摘 2026-08-25)。cc_int_field() は存在を確かめ、欠落なら unknown。
  #
  # 24_xdp_counter の末尾は ConstantReadNode なので、IntegerNode 経路を通すために
  # 末尾ノードだけ差し替えた AST を作る。**値あり / 値なしの対**で見るのは、
  # 「常に unknown を返す実装」でも片方だけなら緑に見えるため。
  def tail_integer_ast(dir, with_value:)
    src = File.read(File.join(ROOT, "tests", "fixtures", "#{XDP}.ast"))
    out = src.lines.filter_map do |ln|
      case ln
      when /\AN 21 ConstantReadNode$/ then "N 21 IntegerNode\n"
      when /\AS 21 name XDP_PASS$/    then with_value ? "I 21 value 2\n" : nil
      else ln
      end
    end.join
    path = File.join(dir, "tail_#{with_value ? "val" : "noval"}.ast")
    File.write(path, out)
    path
  end

  def program_for_ast(ast_path, dir, tag)
    ir   = File.join(ROOT, "tests", "fixtures", "#{XDP}.ir")
    json = File.join(dir, "#{tag}.json")
    _, err, st = Open3.capture3({ "SPNL_BPF_SHADOW" => "1", "SPNL_BPF_MANIFEST" => json },
                                CC, ir, ast_path, "u_#{XDP}")
    assert st.success?, "codegen が失敗した: #{err}"
    JSON.parse(File.read(json))["programs"][0]
  end

  def test_integer_tail_with_a_value_is_known
    Dir.mktmpdir do |dir|
      p = program_for_ast(tail_integer_ast(dir, with_value: true), dir, "val")
      assert_equal true, p["has_verdict"]
      assert_equal 2, p["verdict"], "value がある IntegerNode は known"
    end
  end

  # **本命**: value を落としたら unknown。**0 (XDP_ABORTED) にしない。**
  def test_integer_tail_without_a_value_is_unknown_not_zero
    Dir.mktmpdir do |dir|
      p = program_for_ast(tail_integer_ast(dir, with_value: false), dir, "noval")
      assert_equal true, p["has_verdict"]
      refute_equal 0, p["verdict"],
        "value が欠けた IntegerNode を 0 (XDP_ABORTED) として採用してはいけない"
      assert_equal "unknown", p["verdict"]
    end
  end

  # 解析できない末尾は unknown。**既定値へ倒さない。**
  def test_unknown_verdict_stops_the_shadow
    manifest = {
      "programs" => [{ "name" => "p", "has_verdict" => true, "verdict" => "unknown" }],
      "unsupported" => [],
    }
    require "spinel_ebpf/mlir_shadow"
    a = { programs: [{ name: "p", section_kind: "xdp", attach: "xdp", verdict: :unknown }],
          maps: [], records: [], ringbufs: [] }
    b = Marshal.load(Marshal.dump(a))
    assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirShadow.diff(a, b)
    end
    _ = manifest
  end

  # **最終状態**: 対象内 XDP の manifest に暫定 unsupported が残っていないこと。
  def test_in_slice_xdp_manifest_is_fully_registered
    Dir.mktmpdir do |dir|
      m, = manifest_for(XDP, dir)
      assert_empty m["unsupported"],
        "対象内 XDP なのに unsupported が残っている: #{m["unsupported"].inspect}"
      p = m["programs"][0]
      assert_equal true, p["has_verdict"]
      assert_equal 2, p["verdict"]
    end
  end

  # ---------- 黙って欠落させないこと ----------

  # ---------- 監査表: .maps を出す地点が supported か unsupported か ----------
  #
  # unsupported 配列が「在る」だけでは欠落検出にならない。**実際に対象外の宣言を
  # 出す fixture で、具体名つきの理由が入ること**を見る。
  MAP_SITES = {
    # 決定地点で登録している (E154 の垂直スライス)
    "top-level ivar HASH map"            => :supported,
    "record_schema.h 由来の ring buffer" => :supported,
    "emit N-tuple (3/4) の ring buffer"  => :supported,
    "テンプレート ringbuf_lost"          => :supported,
    "テンプレート emit_str / emit_pair"  => :supported,
    # 対象外。出たら具体名で unsupported に積まれる
    "arena"                              => :unsupported,
    "go_recv_stash"                      => :unsupported,
    "at_ (class ivar) map"               => :unsupported,
    "spnl_flow_ map"                     => :unsupported,
    "その他テンプレート由来 map (~39)"   => :unsupported,
  }.freeze

  # attach の emit 経路。登録を挿したのは主経路だけで、残り 3 つは出たら
  # unsupported に具体名で積まれる。
  PROGRAM_SITES = {
    "attach 主経路 (SEC + ctx wrapper)" => :supported,
    "kprobe_multi 展開"                => :unsupported,
    "kprobe index 展開"                => :unsupported,
    "SEC 無しの wrapper"               => :unsupported,
  }.freeze

  def test_program_site_audit_table_is_stated
    assert_equal 1, PROGRAM_SITES.count { |_, v| v == :supported }
    assert_equal 3, PROGRAM_SITES.count { |_, v| v == :unsupported }
  end

  def test_map_site_audit_table_is_stated
    assert_equal 5, MAP_SITES.count { |_, v| v == :supported }
    assert MAP_SITES.any? { |_, v| v == :unsupported },
      "対象外の宣言経路が 1 つも無い表は監査になっていない"
  end

  # **対象外の宣言が実際に出た入力では、具体名が unsupported に入る。**
  def test_arena_declaration_lands_in_unsupported
    ir = File.join(ROOT, "tests", "fixtures", "84_arena.ir")
    skip "arena fixture が無い" unless File.exist?(ir)
    Dir.mktmpdir do |dir|
      m, = manifest_for("84_arena", dir)
      syms = m["maps"].map { |x| x["symbol"] }
      refute_includes syms, "u_84_arena_arena", "arena を登録済みに見せてはいけない"
      hit = m["unsupported"].find { |u| u.include?("u_84_arena_arena") }
      refute_nil hit,
        "arena を出したのに unsupported に具体名が入っていない: #{m["unsupported"].inspect}"
      assert_includes hit, "unregistered map declaration"
    end
  end

  # **program も同じ方針で監査する。** attach の emit 経路は 4 つあり、
  # E154 が登録を挿したのは主経路だけ。kprobe_multi 展開などが走る入力では
  # program が manifest から漏れるので、それが具体名で残ること。
  def test_kprobe_multi_program_lands_in_unsupported
    ir = File.join(ROOT, "tests", "fixtures", "161_attach_multi_params.ir")
    skip "kprobe_multi fixture が無い" unless File.exist?(ir)
    Dir.mktmpdir do |dir|
      m, = manifest_for("161_attach_multi_params", dir)
      hit = m["unsupported"].find { |u| u.include?("unregistered program declaration") }
      refute_nil hit,
        "kprobe_multi の program が漏れているのに unsupported に入っていない: #{m["unsupported"].inspect}"
      assert_includes hit, "kprobe.multi"
    end
  end

  # 対象内では program の未登録がゼロ。
  def test_in_slice_input_has_no_unregistered_program
    Dir.mktmpdir do |dir|
      [XDP, EMIT].each do |f|
        m, = manifest_for(f, dir)
        stray = m["unsupported"].select { |u| u.include?("unregistered program declaration") }
        assert_empty stray, "#{f}: 対象内なのに未登録 program が出た: #{stray.inspect}"
        assert_equal 1, m["programs"].size
      end
    end
  end

  # 逆に、対象内だけの入力では map の unsupported が出ないこと
  # (何でも unsupported に積む実装だと欠落検出の意味が無い)。
  def test_in_slice_input_has_no_unregistered_map
    Dir.mktmpdir do |dir|
      [XDP, EMIT].each do |f|
        m, = manifest_for(f, dir)
        stray = m["unsupported"].select { |u| u.include?("unregistered map declaration") }
        assert_empty stray, "#{f}: 対象内なのに未登録 map が出た: #{stray.inspect}"
      end
    end
  end

  def test_unsupported_is_present_and_explicit
    Dir.mktmpdir do |dir|
      m, = manifest_for(XDP, dir)
      assert m.key?("unsupported"),
        "登録できなかった宣言カテゴリを残す場所が無い — 黙って欠落する形になっている"
      assert_kind_of Array, m["unsupported"]
    end
  end
end
