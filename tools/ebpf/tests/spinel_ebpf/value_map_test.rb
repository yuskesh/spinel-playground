# frozen_string_literal: true
#
# E397 — 型駆動 derived (value map) の契約テスト。
#
# 守っているのは 1 つの性質: **閉じた集合の値に付ける名前は、どこかで照合できる**。
# 名前の写像が間違っていても下流には分からない (`error=2` を "EPERM" と出しても、
# `oldstate=2` を "SYN_RECV" と出しても、どちらも「もっともらしい名前」になる) ので、
# 検出はここでしか起きない。E394/E395/E396 が kernel 側で潰した沈黙する誤りの、
# record -> span 側の姿。
#
# 3 段構え:
#   (1) 宣言と生成物の整合 (host で回る)
#   (2) **権威との照合** — 走っている kernel の BTF enum と突き合わせる (BTF がある環境のみ)
#   (3) 生成器の拒否 (negative control) — 壊した宣言でビルドすると die するか
require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../../src/spinel_ebpf/capabilities"

class ValueMapTest < Minitest::Test
  ROOT       = File.expand_path("../..", __dir__)
  SCHEMA_H   = File.join(ROOT, "src/codegen_c/record_schema.h")
  GEN_C      = File.join(ROOT, "tools/gen_record_mirror.c")
  MIRROR_H   = File.join(ROOT, "src/runtime/otlp/record_mirror_gen.h")
  AGENT_C    = File.join(ROOT, "src/runtime/otlp/otlp_agent.c")

  def maps = SpinelEbpf::Capabilities.record_value_maps

  # ---------------------------------------------------------------- (1) 宣言

  def test_every_declared_map_is_named_by_a_property
    used = SpinelEbpf::Capabilities.record_channels.flat_map { |c|
      Array(c.dig(:consumer, :properties)).map { |p| p[:value_map] }
    }.compact.uniq
    assert_equal maps.map { |m| m[:id] }.sort, used.sort,
                 "宣言された値マップと、実際に使われている値マップが一致しない " \
                 "(消費者の無い型は死んだ表 = このレイヤが置き換えようとしているものそのもの)"
  end

  def test_every_map_declares_where_its_names_come_from
    refute_empty maps, "値マップが 1 つも宣言されていない"
    maps.each do |m|
      refute_empty m[:authority].to_s, "#{m[:id]}: authority (名前の出どころ) が空"
      refute_empty m[:unknown].to_s,   "#{m[:id]}: unknown (名前の無い値の見え方) が空"
      assert_equal true, m[:arch_invariant],
                   "#{m[:id]}: arch 非依存でない表は生成物に焼けない (E397 m01)"
      refute_empty Array(m[:values]), "#{m[:id]}: 値が空"
    end
  end

  # `unknown` は「名前」に見えてはいけない。数を残す形 (%ld を 1 個持つ) か、
  # それ自体が文書化された答え (conn の "other") のどちらかだけ。
  def test_unknown_rendering_is_either_a_documented_literal_or_keeps_the_number
    maps.each do |m|
      u = m[:unknown].to_s
      convs = u.scan(/%[^%]/).map { |c| c }
      assert_operator u.scan("%ld").length, :<=, 1, "#{m[:id]}: unknown が %ld を 2 つ以上持つ"
      assert_empty (convs - ["%l"]), "#{m[:id]}: unknown が %ld 以外の変換を使っている (#{u})"
    end
    tcp = maps.find { |m| m[:id] == "tcp_state" }
    assert_includes tcp[:unknown], "%ld",
                    "kernel enum の未知値は**数を残す**べき (名前を借りたら嘘になる)"
  end

  def test_values_are_unique_in_both_directions
    maps.each do |m|
      vs = Array(m[:values])
      assert_equal vs.map { |v| v[:value] }.uniq.length, vs.length, "#{m[:id]}: 同じ値に 2 つの名前"
      assert_equal vs.map { |v| v[:name] }.uniq.length,  vs.length, "#{m[:id]}: 同じ名前が 2 つの値に"
    end
  end

  # ------------------------------------------------- (1b) 宣言 -> 生成物 -> runtime

  # 型駆動 derived の実装は**生成物**であって runtime の手書きではない。
  # ここが崩れると「宣言された表」と「実際に引かれる表」が 2 つになる。
  def test_lookup_is_generated_not_hand_written
    gen = File.read(MIRROR_H)
    agent = File.read(AGENT_C)
    maps.each do |m|
      assert_includes gen, "static inline void spnl_valmap_#{m[:id]}(long v, char *out, int cap)",
                      "#{m[:id]}: lookup が生成ヘッダに無い"
      Array(m[:values]).each do |v|
        assert_includes gen, "case #{v[:value]}L: name = \"#{v[:name]}\"; break;",
                        "#{m[:id]}: 宣言 #{v[:value]}=#{v[:name]} が生成 switch に無い"
      end
      refute_match(/^\s*(static\s+)?\w[\w \*]*\bspnl_valmap_#{Regexp.escape(m[:id])}\s*\(/, agent,
                   "#{m[:id]}: runtime が lookup を手書きで持っている (表が 2 つある)")
    end
  end

  # E376 の不変条件を型駆動 derived にも: **Ruby が見る値と span に出る値は同じ関数の出力**。
  # accessor と span builder が同じ spnl_valmap_* を呼んでいることを両側で pin する。
  def test_accessor_and_span_builder_call_the_same_map
    gen     = File.read(MIRROR_H)
    builder = File.read(AGENT_C)[/static int conn_fill_span\(.*?\n\}\n/m]
    refute_nil builder, "conn_fill_span() が読めない"
    props = SpinelEbpf::Capabilities.record_properties("conn").select { |p| p[:value_map] }
    refute_empty props, "conn に型駆動プロパティが無い"
    props.each do |p|
      acc = gen[/const char \*spnl_rec_conn_#{Regexp.escape(p[:name])}\(int i\) \{.*?\n\}\n/m]
      refute_nil acc, "accessor spnl_rec_conn_#{p[:name]}() が生成されていない"
      assert_includes acc, "spnl_valmap_#{p[:value_map]}(",
                      "accessor が宣言された値マップを通っていない"
      assert_includes builder, "spnl_valmap_#{p[:value_map]}(",
                      "span builder が ev.#{p[:name]} と同じ値マップを通っていない"
    end
  end

  # E378 の cap 規則は型駆動 derived では**計算できる** (閉じた集合には実際に最長の要素が
  # あり、名前の無い値の描画にも実際の最大幅がある)。宣言が実際にその上限以上かを見る。
  def test_declared_cap_covers_the_closed_set_and_the_unnamed_rendering
    widths = { "__u8" => 3, "__u16" => 5, "__u32" => 10, "__u64" => 20,
               "__s8" => 4, "__s16" => 6, "__s32" => 11, "__s64" => 20 }
    SpinelEbpf::Capabilities.record_channels.each do |c|
      Array(c.dig(:consumer, :properties)).each do |p|
        next unless p[:value_map]
        m     = SpinelEbpf::Capabilities.record_value_map(p[:value_map])
        field = p[:source].to_s.sub(/\s*->.*\z/, "")
        f     = c[:fields].find { |x| x[:name] == field }
        refute_nil f, "#{c[:id]}.#{p[:name]}: source フィールド #{field} が record に無い"
        assert_equal 0, f[:count], "#{c[:id]}.#{p[:name]}: code は 1 つの整数であるべき"
        dec  = widths[f[:ctype]]
        refute_nil dec, "#{c[:id]}.#{p[:name]}: #{f[:ctype]} は整数型でない"
        need = m[:unknown].to_s.sub("%ld", "9" * dec).length + 1
        Array(m[:values]).each { |v| need = [need, v[:name].to_s.length + 1].max }
        assert_operator p[:cap], :>=, need,
                        "#{c[:id]}.#{p[:name]}: cap #{p[:cap]} は自分の閉じた集合 (必要 #{need}) に足りない"
      end
    end
  end

  # ------------------------------------------------------ (2) 権威との照合 (BTF)

  BTF_PATH = "/sys/kernel/btf/vmlinux"

  # bpftool の raw dump から、`anchor` を含む ENUM ブロックの enumerator を集める。
  # 同じ anchor を持つブロックが複数あれば **一致していること**を要求する
  # (「最初のを採る」は測定器が嘘をつく形)。
  def btf_enum_containing(anchor)
    out, st = Open3.capture2e("bpftool", "btf", "dump", "file", BTF_PATH, "format", "raw")
    return nil unless st.success?
    blocks = []
    cur = nil
    out.each_line do |line|
      if line =~ /\A\[\d+\] ENUM /
        blocks << cur if cur
        cur = {}
      elsif cur && line =~ /\A\t'([A-Za-z_][A-Za-z0-9_]*)' val=(-?\d+)/
        cur[$1] = $2.to_i
      elsif line =~ /\A\[\d+\] /
        blocks << cur if cur
        cur = nil
      end
    end
    blocks << cur if cur
    hits = blocks.compact.select { |b| b.key?(anchor) }
    return nil if hits.empty?
    hits.each { |h| assert_equal hits.first, h, "同じ anchor を持つ BTF enum が食い違っている" }
    hits.first
  end

  def skip_without_btf
    skip "BTF authority check needs a running kernel with #{BTF_PATH} + bpftool " \
         "(host macOS では回らない — container spnl715 で実行、結果は " \
         "docs/experiments/results/E397/)" unless File.exist?(BTF_PATH)
  end

  # 本テストの中心。宣言した名前が、走っている kernel が使っている名前かを見る。
  #   btf_mode "names" — 表は enum そのもの: 全 enumerator (btf_omit を除く) が
  #                      同じ値・同じ名前 (prefix を剥がしたもの) で宣言されていること
  #   btf_mode "keys"  — 名前はこの project のものだが、**キーは kernel のもの**:
  #                      宣言した値がすべて enum の実在値であること
  def test_declared_names_match_the_kernel_enum
    skip_without_btf
    checked = 0
    maps.each do |m|
      next if m[:btf_mode].to_s.empty?
      enum = btf_enum_containing(m[:btf_anchor])
      refute_nil enum, "#{m[:id]}: BTF に #{m[:btf_anchor]} を含む enum が無い"
      prefix = m[:btf_prefix].to_s
      omit   = m[:btf_omit].to_s.split
      declared = Array(m[:values]).to_h { |v| [v[:name], v[:value]] }
      case m[:btf_mode]
      when "names"
        want = enum.reject { |k, _| omit.include?(k) }
                   .to_h { |k, v| [k.sub(/\A#{Regexp.escape(prefix)}/, ""), v] }
        assert_equal want, declared,
                     "#{m[:id]}: 宣言が走っている kernel の enum と食い違う " \
                     "(kernel = #{want.inspect})"
      when "keys"
        vals = enum.values.uniq
        declared.each do |name, v|
          assert_includes vals, v,
                          "#{m[:id]}: #{name}=#{v} は kernel の #{m[:btf_anchor]} enum に無い値"
        end
      else
        flunk "#{m[:id]}: unknown btf_mode #{m[:btf_mode].inspect}"
      end
      checked += 1
    end
    assert_operator checked, :>, 0, "BTF 照合した値マップが 0 個 (テストが何も見ていない)"
  end

  # 照合器そのものが差を検出できるか (測定器の自己診断)。実在する enum に対して
  # **わざと 1 つ間違えた**宣言を突き合わせ、不一致になることを確かめる。
  # これが通らないなら上のテストの green は「一致した」ではなく「見ていない」。
  def test_the_authority_check_detects_a_wrong_name
    skip_without_btf
    enum = btf_enum_containing("TCP_ESTABLISHED")
    refute_nil enum
    want = enum.reject { |k, _| k == "TCP_MAX_STATES" }.to_h { |k, v| [k.sub(/\ATCP_/, ""), v] }
    swapped = want.merge("SYN_SENT" => want["SYN_RECV"], "SYN_RECV" => want["SYN_SENT"])
    refute_equal want, swapped, "取り違えた表が正しい表と等しいと判定された (照合器が壊れている)"
    truncated = want.reject { |k, _| k == "BOUND_INACTIVE" }
    refute_equal want, truncated, "1 つ足りない表が正しいと判定された"
  end

  # ------------------------------------------------- (3) 生成器の拒否 (negative)

  # 壊した record_schema.h で生成器をビルドし、**die するか**を見る。
  # 返り値は [ok(bool), 出力]。
  def build_with_mutated_schema(&mutate)
    Dir.mktmpdir("e397") do |dir|
      FileUtils.mkdir_p(File.join(dir, "tools"))
      FileUtils.mkdir_p(File.join(dir, "src/codegen_c"))
      FileUtils.cp(GEN_C, File.join(dir, "tools/gen_record_mirror.c"))
      File.write(File.join(dir, "src/codegen_c/record_schema.h"), mutate.call(File.read(SCHEMA_H)))
      bin = File.join(dir, "gen")
      out, st = Open3.capture2e(ENV["CC"] || "cc", "-O2", "-o", bin, File.join(dir, "tools/gen_record_mirror.c"))
      return [false, "compile failed:\n#{out}"] unless st.success?
      # stdout と stderr を分けて捕まえる: die() は stderr に書くが、そこに至るまでに
      # 生成物が数百行 stdout に出ている。混ぜると assertion 失敗の diff が生成物で
      # 埋まり、「何を拒否したか」が読めなくなる (測定器の可読性も測定器のうち)。
      sout, serr, st2 = Open3.capture3(bin)
      [st2.success?, st2.success? ? sout : serr]
    end
  end

  # 測定器の自己診断: 無改変ならビルドも実行も通る。これが通らないなら
  # 下の refusal は「拒否した」ではなく「そもそも動いていない」。
  def test_unmutated_schema_builds_and_runs
    ok, out = build_with_mutated_schema { |s| s }
    assert ok, "無改変の宣言で生成器が失敗した:\n#{out}"
    assert_includes out, "spnl_valmap_tcp_state", "生成物に値マップが出ていない"
  end

  # D1 の本体。arch ごとに違う表は生成物に焼けない — 焼くと別 arch で
  # **もっともらしい違う名前**が出る (E397 m01: syscall 2 = io_submit / open / fork)。
  def test_generator_refuses_a_map_that_is_not_architecture_invariant
    ok, out = build_with_mutated_schema { |s|
      s.sub('.arch_invariant = 1,
  .btf_mode       = "names",', '.arch_invariant = 0,
  .btf_mode       = "names",')
    }
    refute ok, "arch 非依存でない値マップが通ってしまった"
    assert_includes out, "architecture-invariant"
    assert_includes out, "E397 m01", "拒否の理由に実測の出典が無い"
  end

  def test_generator_refuses_an_undeclared_map
    ok, out = build_with_mutated_schema { |s| s.sub('"tcp_state", "code_to_name"', '"tcp_stat", "code_to_name"') }
    refute ok, "存在しない値マップを名指しても通ってしまった"
    assert_includes out, "names an undeclared value map"
  end

  def test_generator_refuses_a_cap_that_the_closed_set_does_not_fit
    ok, out = build_with_mutated_schema { |s| s.sub('"tcp_state", "code_to_name", "declared", 24,', '"tcp_state", "code_to_name", "declared", 8,') }
    refute ok, "閉じた集合に足りない cap が通ってしまった"
    assert_includes out, "cap smaller than its own closed set"
  end

  def test_generator_refuses_a_code_read_from_an_array_field
    ok, out = build_with_mutated_schema { |s| s.sub('{ "tcp_state", "str", "oldstate", "tcp_state"', '{ "tcp_state", "str", "comm", "tcp_state"') }
    refute ok, "配列フィールドを code として読んでも通ってしまった"
    assert_includes out, "reads an array field"
  end

  def test_generator_refuses_a_map_nobody_uses
    ok, out = build_with_mutated_schema { |s|
      s.sub(/\{ "tcp_state", "str", "oldstate", "tcp_state", "code_to_name", "declared", 24,.*?\},\n/m, "")
    }
    refute ok, "誰も使わない値マップが通ってしまった"
    assert_includes out, "named by no derivation"
  end

  def test_generator_refuses_an_unknown_rendering_that_is_not_a_number
    ok, out = build_with_mutated_schema { |s| s.sub('.unknown        = "unnamed(%ld)",', '.unknown        = "unnamed(%s)",') }
    refute ok, "%ld 以外の変換を持つ unknown が通ってしまった"
    assert_includes out, "may only use %ld"
  end

  def test_generator_refuses_two_names_for_one_value
    ok, out = build_with_mutated_schema { |s| s.sub('{  2, "SYN_SENT"    }', '{  1, "SYN_SENT"    }') }
    refute ok, "同じ値に 2 つの名前を付けても通ってしまった"
    assert_includes out, "two names"
  end
end
