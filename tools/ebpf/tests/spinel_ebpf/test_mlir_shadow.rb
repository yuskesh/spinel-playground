# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/test_mlir_shadow.rb
#
# E154 (P013 Task 7): **現行 C backend と MLIR backend の意味を突き合わせる比較器。**
#
# ELF のバイト一致は要求しない。比較するのは宣言された意味である:
#
#   program 名 / program kind / attach 情報
#   map symbol / map kind / key 型 / value 型 / max_entries
#   record symbol / record size / field offset
#   ring buffer 名
#   enforcement verdict
#
# **shadow 側だけ失敗したときに現行成果物へ黙って fallback しない。**
# mismatch は mismatch として loud に落とす — 「片側が動かないので成功扱い」は
# このテストが存在する理由そのものを壊す。
#
# 既定 (フラグ未設定) の経路はここでは触らない。既定出力の byte-identical は
# golden gate が見る。

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

require "spinel_ebpf/mlir_shadow"

class MlirShadowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CC   = File.join(ROOT, "build", "codegen_c", "spinel_ebpf_cc")

  # fixture は 2 つ。
  #   XDP     — map だけ。verdict が既知定数 (XDP_PASS)
  #   emit    — **record / field offset / ring buffer** を持つ
  # 1 つ目だけだと record と ring buffer を比較器が無視しても緑になる。
  XDP  = "24_xdp_counter"
  EMIT = "22_emit_pair"

  # **正式 gate では codegen 不在を skip にしない。** 開発中は skip でよいが、
  # SPNL_SHADOW_GATE=1 のときは前提不足として落とす — 「動かなかったから
  # 通った」を作らないため。
  def setup
    return if File.executable?(CC)
    if ENV["SPNL_SHADOW_GATE"] == "1"
      flunk "gate モードなのに codegen が建っていない: #{CC} (make -C src/codegen_c)"
    end
    skip "codegen が建っていない (make -C src/codegen_c)"
  end

  def current_meaning(fixture = XDP)
    ir  = File.join(ROOT, "tests", "fixtures", "#{fixture}.ir")
    ast = File.join(ROOT, "tests", "fixtures", "#{fixture}.ast")
    out, err, st = Open3.capture3(CC, ir, ast, "u_#{fixture}")
    assert st.success?, "現行 backend が失敗した: #{err}"
    SpinelEbpf::MlirShadow.meaning_of_bpf_c(out)
  end

  def mlir_meaning(fixture = XDP)
    ir  = File.join(ROOT, "tests", "fixtures", "#{fixture}.ir")
    ast = File.join(ROOT, "tests", "fixtures", "#{fixture}.ast")
    SpinelEbpf::MlirShadow.meaning_of_mlir(ir, ast, "u_#{fixture}")
  end

  # 1 項目を壊した複製を作って、比較器がそれを帰属できるか見る。
  def assert_detects(fixture, what_fragment)
    a = current_meaning(fixture)
    b = Marshal.load(Marshal.dump(a))
    yield b
    diff = SpinelEbpf::MlirShadow.diff(a, b)
    refute_empty diff, "#{what_fragment} を壊したのに比較器が気づかない"
    assert diff.any? { |d| d[:what].include?(what_fragment) },
      "壊した項目が帰属されていない (期待 #{what_fragment.inspect}): #{diff.map { |d| d[:what] }.inspect}"
  end

  # ---------- 比較器そのもの ----------

  def test_shadow_agrees_on_declared_meaning_xdp
    a = current_meaning(XDP)
    b = mlir_meaning(XDP)
    diff = SpinelEbpf::MlirShadow.diff(a, b)
    assert_empty diff,
      "現行 backend と MLIR backend の意味が食い違う (#{XDP}):\n" +
      diff.map { |d| "  #{d[:what]}: current=#{d[:current].inspect} mlir=#{d[:mlir].inspect}" }.join("\n")
  end

  def test_shadow_agrees_on_declared_meaning_emit
    a = current_meaning(EMIT)
    b = mlir_meaning(EMIT)
    diff = SpinelEbpf::MlirShadow.diff(a, b)
    assert_empty diff,
      "現行 backend と MLIR backend の意味が食い違う (#{EMIT}):\n" +
      diff.map { |d| "  #{d[:what]}: current=#{d[:current].inspect} mlir=#{d[:mlir].inspect}" }.join("\n")
  end

  # ---------- 比較器そのものの陽性対照 ----------
  #
  # **列挙されている項目が本当に比較されている証明**。コメントに書いてあるだけでは
  # 契約の証明にならない (比較器が何も見ていない状態は緑に見える — Z-7 の形)。

  def test_detects_program_name
    assert_detects(XDP, "program") { |b| b[:programs][0][:name] = "xdp__other" }
  end

  def test_detects_program_section_kind
    assert_detects(XDP, "section_kind") { |b| b[:programs][0][:section_kind] = "tracepoint" }
  end

  def test_detects_attach
    assert_detects(EMIT, "attach") { |b| b[:programs][0][:attach] = "tracepoint/sched/sched_wakeup" }
  end

  # verdict は **enforcement 型 program にだけ**ある。
  def test_detects_verdict
    assert_detects(XDP, "verdict") { |b| b[:programs][0][:verdict] = 1 }
  end

  # 観測型 (tracepoint) に verdict を生やしたら、それ自体が差である。
  def test_detects_verdict_appearing_on_an_observation_program
    assert_detects(EMIT, "verdict") { |b| b[:programs][0][:verdict] = 0 }
  end

  def test_detects_map_symbol
    assert_detects(XDP, "map") { |b| b[:maps][0][:symbol] = "renamed" }
  end

  def test_detects_map_kind
    assert_detects(XDP, "kind") { |b| b[:maps][0][:kind] = "array" }
  end

  def test_detects_map_key_type
    assert_detects(XDP, "key") { |b| b[:maps][0][:key] = "__u64" }
  end

  def test_detects_map_value_type
    assert_detects(XDP, "value") { |b| b[:maps][0][:value] = "__s32" }
  end

  def test_detects_max_entries
    assert_detects(XDP, "max_entries") { |b| b[:maps][0][:max_entries] += 1 }
  end

  def test_detects_missing_map
    assert_detects(XDP, "presence of") { |b| b[:maps] = [] }
  end

  # --- record / ring buffer (第 2 fixture が無いと素通りする項目) ---

  def test_detects_record_size
    assert_detects(EMIT, "size") { |b| b[:records][0][:size] += 8 }
  end

  def test_detects_record_field_offset
    assert_detects(EMIT, "offset") { |b| b[:records][0][:fields][1][:offset] += 8 }
  end

  def test_detects_missing_record
    assert_detects(EMIT, "presence of") { |b| b[:records] = [] }
  end

  def test_detects_ringbuf_name
    assert_detects(EMIT, "ringbufs") { |b| b[:ringbufs] = ["renamed_events"] }
  end

  # ---------- SEC -> 宣言表の引き方 (Mac の指示 2026-08-25) ----------
  #
  # **先頭勝ちで 1 行に決めない。** 同じ sec を持つ行は実在するので、
  # `rows.find` で先頭を採ると将来 verdict の違う行が足されたとき黙って誤分類する。

  def test_duplicate_sec_rows_really_exist
    rows = SpinelEbpf::MlirShadow.attach_rows
    dup = rows.group_by { |r| r["sec"] }.select { |sec, v| sec && v.size > 1 }
    refute_empty dup, "同じ sec を持つ行が無いなら、この規則の対照が成立しない"
    assert_equal 3, SpinelEbpf::MlirShadow.rows_for_sec("xdp").size,
      "xdp は xdp / xdp_tail / xdp_tcp_slice の 3 行"
  end

  # 複数候補でも必要な属性が全一致していれば使える。
  def test_ambiguous_sec_is_usable_when_the_attribute_agrees
    assert_equal true, SpinelEbpf::MlirShadow.sec_has_verdict?("xdp"),
      "xdp の候補 3 行は verdict=true で一致するので使える"
    assert_equal false, SpinelEbpf::MlirShadow.sec_has_verdict?("struct_ops/x"),
      "struct_ops の候補 3 行は verdict=false で一致する"
  end

  # 属性が食い違う候補は **停止**。宣言表に矛盾する行を足して確かめる。
  def test_ambiguous_sec_with_a_disagreeing_attribute_stops
    rows = SpinelEbpf::MlirShadow.attach_rows
    injected = rows + [{ "kind" => "xdp_fake", "sec" => "xdp", "verdict" => false }]
    SpinelEbpf::MlirShadow.instance_variable_set(:@attach_rows, injected)
    SpinelEbpf::MlirShadow.instance_variable_set(:@verdict_kinds, nil)
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirShadow.sec_has_verdict?("xdp")
    end
    assert_includes err.message, "ambiguous"
  ensure
    SpinelEbpf::MlirShadow.instance_variable_set(:@attach_rows, nil)
    SpinelEbpf::MlirShadow.instance_variable_set(:@verdict_kinds, nil)
  end

  # 宣言表に無い SEC は既定値へ倒さず停止。
  def test_unknown_sec_stops
    assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirShadow.sec_has_verdict?("no_such_attach_kind/x")
    end
  end

  # [decl_kind, attach] の組が宣言表に在ること。
  def test_decl_kind_pair_is_validated_against_the_table
    assert SpinelEbpf::MlirShadow.decl_kind_pair_exists?("xdp", "xdp")
    assert SpinelEbpf::MlirShadow.decl_kind_pair_exists?("xdp_tail", "xdp"),
      "同じ sec を持つ別 kname の組も実在する"
    assert SpinelEbpf::MlirShadow.decl_kind_pair_exists?("tc_ingress", "tcx/ingress"),
      "kname != SEC 頭 の組"
    refute SpinelEbpf::MlirShadow.decl_kind_pair_exists?("tc_ingress", "xdp"),
      "存在しない組は弾く"
  end

  # 比較器が「組が無い」を差として報告すること。
  def test_comparator_reports_a_decl_kind_that_does_not_pair_with_the_attach
    a = { programs: [{ name: "p", section_kind: "xdp", attach: "xdp", verdict: 2 }],
          maps: [], records: [], ringbufs: [] }
    b = { programs: [{ name: "p", section_kind: "xdp", decl_kind: "tc_ingress",
                       attach: "xdp", verdict: 2 }],
          maps: [], records: [], ringbufs: [] }
    diff = SpinelEbpf::MlirShadow.diff(a, b)
    assert diff.any? { |d| d[:what].include?("decl_kind") }, diff.inspect
  end

  # ---------- verdict 4 状態の突き合わせ規則 (Mac の判断 2026-08-25) ----------
  #
  #   known 同士       -> 値を比較
  #   none 同士        -> 比較不要
  #   unknown が片側   -> 停止
  #   dynamic が片側   -> 停止
  #   none と それ以外 -> attach 意味の差として報告

  def pair(va, vb)
    a = { programs: [{ name: "p", section_kind: "xdp", attach: "xdp", verdict: va }],
          maps: [], records: [], ringbufs: [] }
    b = { programs: [{ name: "p", section_kind: "xdp", attach: "xdp", verdict: vb }],
          maps: [], records: [], ringbufs: [] }
    [a, b]
  end

  def test_known_verdicts_are_compared_by_value
    a, b = pair(2, 2)
    assert_empty SpinelEbpf::MlirShadow.diff(a, b)
    a, b = pair(2, 1)
    assert SpinelEbpf::MlirShadow.diff(a, b).any? { |d| d[:what].include?("verdict") }
  end

  def test_none_verdicts_need_no_comparison
    a, b = pair(nil, nil)
    assert_empty SpinelEbpf::MlirShadow.diff(a, b)
  end

  # **dynamic 同士を一致扱いにしない。** 両方が「非定数」というだけでは、
  # 同じ条件・同じ到達可能 verdict 集合を持つ証明にならない。
  def test_dynamic_on_both_sides_stops_instead_of_matching
    a, b = pair(:dynamic, :dynamic)
    assert_raises(SpinelEbpf::MlirShadow::Unsupported) { SpinelEbpf::MlirShadow.diff(a, b) }
  end

  def test_dynamic_on_one_side_stops
    [[:dynamic, 2], [2, :dynamic]].each do |va, vb|
      a, b = pair(va, vb)
      assert_raises(SpinelEbpf::MlirShadow::Unsupported) { SpinelEbpf::MlirShadow.diff(a, b) }
    end
  end

  def test_unknown_on_one_side_stops
    [[:unknown, 2], [2, :unknown], [:unknown, :unknown]].each do |va, vb|
      a, b = pair(va, vb)
      assert_raises(SpinelEbpf::MlirShadow::Unsupported) { SpinelEbpf::MlirShadow.diff(a, b) }
    end
  end

  # none と それ以外は **停止ではなく差**。attach 種別の意味が食い違っている。
  def test_none_versus_anything_is_reported_as_a_difference
    [[nil, 2], [nil, :dynamic], [nil, :unknown], [2, nil]].each do |va, vb|
      a, b = pair(va, vb)
      diff = SpinelEbpf::MlirShadow.diff(a, b)
      assert diff.any? { |d| d[:what].include?("verdict") },
        "none vs #{vb.inspect} が差として報告されない: #{diff.inspect}"
    end
  end

  # ---------- MLIR 側が manifest から組まれていること ----------
  #
  # **現行側の .bpf.c 読み取りを流用していないことの証明。** meaning_of_mlir が
  # meaning_of_bpf_c を呼ぶだけの実装でも上の 2 本は緑になるので、manifest ->
  # 意味の写像そのものをここで固定する。

  def test_meaning_is_built_from_the_manifest_not_from_bpf_c
    require "spinel_ebpf/mlir_backend"
    m = {
      "unit" => "u_x",
      "programs" => [{ "name" => "xdp__main", "sec" => "xdp", "kind" => "xdp",
                       "has_verdict" => true, "verdict" => 2 }],
      "maps" => [{ "symbol" => "u_x_rb", "kind" => "ringbuf", "key" => nil,
                   "value" => nil, "max_entries" => 262_144, "record" => "u_x_ev" },
                 { "symbol" => "u_x_h", "kind" => "hash", "key" => "__u32",
                   "value" => "__s64", "max_entries" => 1, "record" => nil }],
      "records" => [{ "symbol" => "u_x_ev", "fields" => [
        { "name" => "hdr", "ctype" => "struct spnl_event_hdr", "count" => 0 },
        { "name" => "a", "ctype" => "__s64", "count" => 0 },
      ] }],
      "unsupported" => [],
    }
    got = SpinelEbpf::MlirBackend.from_manifest(m, "test")
    assert_equal [{ name: "xdp__main", section_kind: "xdp", decl_kind: "xdp",
                    attach: "xdp", verdict: 2 }], got[:programs]
    assert_equal %w[u_x_h u_x_rb], got[:maps].map { |x| x[:symbol] }, "symbol 順に並ぶ"
    assert_equal ["u_x_rb"], got[:ringbufs]
    # layout は現行側と同じモデルを通ること (hdr=16 の直後に __s64)。
    rec = got[:records][0]
    assert_equal 24, rec[:size]
    assert_equal({ "hdr" => 0, "a" => 16 }, rec[:fields].to_h { |f| [f[:name], f[:offset]] })
  end

  # **unsupported が残る manifest を緑にしない。**
  def test_manifest_with_unsupported_stops
    require "spinel_ebpf/mlir_backend"
    m = { "programs" => [], "maps" => [], "records" => [],
          "unsupported" => ["unregistered map declaration: u_x_arena"] }
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirBackend.from_manifest(m, "test")
    end
    assert_includes err.message, "u_x_arena"
  end

  # enforcement なのに verdict が欠落 -> 停止。**既定値へ倒さない。**
  def test_missing_verdict_on_an_enforcement_program_stops
    require "spinel_ebpf/mlir_backend"
    m = { "programs" => [{ "name" => "xdp__main", "sec" => "xdp", "kind" => "xdp",
                           "has_verdict" => true, "verdict" => nil }],
          "maps" => [], "records" => [], "unsupported" => [] }
    assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirBackend.from_manifest(m, "test")
    end
  end

  # 配列 field は現行側の reader が読めない -> 片側だけ読める形は停止。
  def test_array_field_stops
    require "spinel_ebpf/mlir_backend"
    m = { "programs" => [], "maps" => [],
          "records" => [{ "symbol" => "u_x_ev", "fields" => [
            { "name" => "hdr", "ctype" => "struct spnl_event_hdr", "count" => 0 },
            { "name" => "buf", "ctype" => "char", "count" => 64 },
          ] }],
          "unsupported" => [] }
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      SpinelEbpf::MlirBackend.from_manifest(m, "test")
    end
    assert_includes err.message, "buf"
  end

  # ---------- shadow 側が失敗したときの扱い ----------

  # **shadow が動かないことを成功扱いにしない。**
  def test_shadow_failure_is_loud
    err = assert_raises(SpinelEbpf::MlirShadow::ShadowError) do
      SpinelEbpf::MlirShadow.meaning_of_mlir("/nonexistent.ir", "/nonexistent.ast", "u_x")
    end
    refute_nil err.message
    refute_empty err.message
  end

  # ---------- 現行側の読み取りが本当に効いているか ----------

  def test_current_meaning_is_read_from_the_real_backend
    m = current_meaning(XDP)
    assert_equal "xdp__main", m[:programs][0][:name]
    assert_equal "xdp", m[:programs][0][:section_kind]
    assert_equal 2, m[:programs][0][:verdict],
      "XDP は enforcement 型なので verdict を持つ (XDP_PASS = 2)"
    assert_equal 1, m[:maps].size
    map = m[:maps][0]
    assert_equal "u_24_xdp_counter_top_rx_pkts", map[:symbol]
    assert_equal "hash", map[:kind]
    assert_equal "__u32", map[:key]
    assert_equal "__s64", map[:value]
    assert_equal 1, map[:max_entries]
    assert_empty m[:records], "この fixture は ring buffer record を持たない"
    assert_empty m[:ringbufs]
  end

  # 第 2 fixture の読み取り: record / field offset / ring buffer が実際に取れること。
  # verdict を持つ種別の一覧は **codegen 自身の宣言表**から来ていること。
  # (我々が別表を持つと、宣言表が変わったときに黙ってずれる)
  def test_verdict_kinds_come_from_the_codegen_declaration_table
    kinds = SpinelEbpf::MlirShadow.verdict_kinds
    assert_includes kinds, "xdp"
    assert_includes kinds, "lsm"
    assert_includes kinds, "fmod_ret"
    refute_includes kinds, "tracepoint"
    refute_includes kinds, "kprobe"
  end

  def test_current_meaning_reads_records_and_ringbuf
    m = current_meaning(EMIT)
    assert_equal "tracepoint__sched__sched_switch", m[:programs][0][:name]
    assert_equal "tracepoint/sched/sched_switch", m[:programs][0][:attach]
    # **tracepoint の `return 0` は enforcement verdict ではない。**
    # XDP_PASS と同じ意味カテゴリに入れない (codegen 自身の宣言表が正典)。
    assert_nil m[:programs][0][:verdict],
      "観測型 program に verdict を記録してはいけない"
    assert_equal ["u_22_emit_pair_pair_events"], m[:ringbufs]
    rb = m[:maps].find { |x| x[:kind] == "ringbuf" }
    assert_equal 256 * 1024, rb[:max_entries], "`256 * 1024` を数にできること"
    rec = m[:records][0]
    assert_equal "u_22_emit_pair_pair_event", rec[:symbol]
    assert_equal 32, rec[:size]
    assert_equal({ "hdr" => 0, "a" => 16, "b" => 24 },
                 rec[:fields].to_h { |f| [f[:name], f[:offset]] })
  end

  # **layout モデルの較正**: offset は自分のモデルで計算しているので、
  # 実物の compiler (clang -target bpf) が同じ layout を出すことを確かめる。
  # 両側とも自分のモデルだと「揃っているが両方間違い」が緑に見える。
  def test_record_layout_matches_clang
    clang = ENV["CLANG"] || "/usr/lib/llvm-22/bin/clang"
    bpftool = ENV["BPFTOOL"] || "bpftool"
    unless File.executable?(clang) && system("#{bpftool} version >/dev/null 2>&1")
      if ENV["SPNL_SHADOW_GATE"] == "1"
        flunk "gate モードなのに clang/bpftool が無い (layout の較正ができない)"
      end
      skip "clang/bpftool が無いので layout を較正できない"
    end
    rec = current_meaning(EMIT)[:records][0]
    Dir.mktmpdir do |dir|
      src = File.join(dir, "layout.c")
      File.write(src, <<~C)
        typedef unsigned short __u16; typedef unsigned int __u32;
        typedef unsigned long long __u64; typedef long long __s64;
        struct spnl_event_hdr { __u16 type; __u16 version; __u32 reserved; __u64 timestamp; };
        struct #{rec[:symbol]} { struct spnl_event_hdr hdr; __s64 a; __s64 b; };
        const struct #{rec[:symbol]} *w __attribute__((section(".w"))) = 0;
        int f(void) { return 0; }
      C
      obj = File.join(dir, "layout.o")
      out, st = Open3.capture2e(clang, "-O2", "-g", "-target", "bpf", "-c", src, "-o", obj)
      assert st.success?, "較正用の compile が通らない: #{out}"
      btf, st2 = Open3.capture2e(bpftool, "btf", "dump", "file", obj, "format", "raw")
      assert st2.success?, "BTF を読めない: #{btf}"
      block = btf[/STRUCT '#{Regexp.escape(rec[:symbol])}' size=(\d+) vlen=\d+\n((?:\t.*\n)*)/]
      refute_nil block, "clang の BTF に record が出ていない:\n#{btf}"
      assert_equal rec[:size], Regexp.last_match(1).to_i,
        "record の size が clang と食い違う"
      got = Regexp.last_match(2).scan(/'([^']+)' type_id=\d+ bits_offset=(\d+)/)
                  .to_h { |n, o| [n, o.to_i / 8] }
      want = rec[:fields].to_h { |f| [f[:name], f[:offset]] }
      assert_equal want, got, "field の offset が clang と食い違う (layout モデルの誤り)"
    end
  end
end
