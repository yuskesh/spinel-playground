# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/test_mlir_typed_consumer.rb
#
# E155 (P013 Task 8): **型付き Ruby I/O と MLIR backend の境界。**
#
# 型付き consumer (on_emit / ev.<prop>) の変換は codegen backend の選択より
# 前段で走る。ここで固定するのは:
#
#   1. 変換が backend 選択 (SPNL_BPF_BACKEND / SPNL_BPF_SHADOW) に依存しないこと
#      — 依存したら「shadow を立てただけで Ruby 面が変わる」ことになる。
#   2. 型付き record を持つ unit は MLIR object の対象外として **loud に停止**
#      すること — record を落とした MLIR object を黙って採用しない。
#   3. E155 で足した map 値の読み返し面 (spnl_top_ivar_i64) が loader contract
#      の綴り (SUFFIX_TOP_IVAR) で glue に居ること。
#
# 実 kernel での読み返しと両 backend の実行差動は tests/runtime/
# run_mlir_ivar_readback.sh / run_mlir_embedded_object.sh が持つ。
# record の length mismatch 拒否は record_mirror_test.c が恒久で持つ
# (short record rejected — conn/l7/http/offcpu/dns)。

require "minitest/autorun"

require "spinel_ebpf/consumer"
require "spinel_ebpf/loader_contract_gen"
require "spinel_ebpf/mlir_backend"

class MlirTypedConsumerTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  TYPED_SRC = <<~RUBY
    on_emit :dns do |ev|
      puts ev.pid
    end
    consume_records(200)
  RUBY

  BACKEND_ENVS = [
    {},
    { "SPNL_BPF_BACKEND" => "mlir" },
    { "SPNL_BPF_SHADOW" => "1" },
  ].freeze

  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  # ---- 1. 変換は backend 選択に依存しない --------------------------------------
  def test_typed_consumer_transform_is_independent_of_backend_env
    outs = BACKEND_ENVS.map { |env| with_env(env) { SpinelEbpf::Consumer.transform(TYPED_SRC) } }
    assert_equal outs[0], outs[1],
      "SPNL_BPF_BACKEND=mlir で typed consumer の変換が変わった — Ruby 面は backend 非依存であること"
    assert_equal outs[0], outs[2],
      "SPNL_BPF_SHADOW=1 で typed consumer の変換が変わった"
    # 空同士の一致でないことの対照。
    assert_includes outs[0], "def __spnl_consume_rec_dns(ev)"
  end

  # ---- 2. 型付き record unit は MLIR object の対象外として停止 -----------------
  #
  # 105_emit_dns は dns record channel を持つ。record は spbpf dialect が表現
  # できないので、MLIR object 経路は Unsupported で止まらなければならない —
  # 「record を持たない外形だけの MLIR object」を黙って作る経路が生えたら
  # ここが落ちる。
  def test_typed_record_unit_is_refused_by_the_mlir_object_path
    cc = SpinelEbpf::MlirBackend.codegen_path
    skip "codegen が無い (make -C src/codegen_c)" unless File.executable?(cc)
    fixture = %w[ir ast].to_h { |x| [x, File.join(ROOT, "tests", "fixtures", "105_emit_dns.#{x}")] }
    skip "105_emit_dns fixture が無い" unless fixture.values.all? { |f| File.file?(f) }

    m = SpinelEbpf::MlirBackend.manifest(fixture["ir"], fixture["ast"], "u_105_emit_dns")
    err = assert_raises(SpinelEbpf::MlirShadow::Unsupported) do
      Dir.mktmpdir("spnl-typed") do |dir|
        SpinelEbpf::MlirBackend.compile_mlir(m, "u_105_emit_dns", dir)
      end
    end
    assert_match(/record|cannot handle/, err.message,
      "停止理由が record / 対象範囲を名指ししていない: #{err.message}")
  end

  # ---- 3. map 値の読み返し面が contract の綴りで glue に居る --------------------
  def test_glue_exposes_top_ivar_readback_via_the_loader_contract
    assert_equal "_top_", SpinelEbpf::LoaderContract::SUFFIX_TOP_IVAR,
      "SUFFIX_TOP_IVAR が codegen の cc_ivar_map の綴りと食い違う"
    glue = File.read(File.join(ROOT, "bin", "spinel-ebpf"))
    assert_includes glue, "long long spnl_top_ivar_i64(const char *bare)",
      "glue に spnl_top_ivar_i64 が無い (E155 の map 値読み返し面)"
    assert_includes glue, '#{skel_name}#{lc::SUFFIX_TOP_IVAR}',
      "map 名が contract の定数から組まれていない (raw literal は loader gate が拒否する)"
  end
end
