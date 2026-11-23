# frozen_string_literal: true
#
# Run: ruby -Isrc -Itests tests/spinel_ebpf/otlp_oracle_test.rb
#
# E156 checkpoint 1 (P013 Task 9): **意味オラクルの比較器そのものの検査。**
#
# ここは緑であること — 比較器が変異を検出できない状態で 3 経路比較を組んでも
# 「何も見ていない一致」が緑に見えるだけなので、比較器の検出力を先に固定する。
#
#   - 正規化 OTLP data model の各 field (timestamp / attribute / metric 値 /
#     bucket / temporality / monotonic / scale ...) を 1 つずつ変異させ、
#     diff が必ず検出すること。
#   - 「3 経路が空を返して一致」を compare! が拒否すること (陽性対照)。
#   - 正規化 (bucket の offset 畳み込み) が意味を失わないこと。
#   - 未知 key / 型違いを黙って通さないこと。
#
# 実 schema (187_xdp_emit_pair) に対する赤い意味オラクル本体は
# tests/spinel_ebpf/test_otlp_semantic_model.rb が持つ (harness:
# tests/runtime/run_otlp_semantic_oracle.sh)。ここの fixture は比較器検査用の
# 合成モデルであって、3 経路が実際に返すべき値の正典ではない。

require "minitest/autorun"
require "spinel_ebpf/otlp_semantic_oracle"

class OtlpOracleTest < Minitest::Test
  O = SpinelEbpf::OtlpSemanticOracle

  # 固定入力: pair record (a=7, b=9)、ktime は固定値、wall 変換 offset も固定。
  # 実行時の時計は読まない (比較の決定性のため)。
  WALL_OFF = 1_700_000_000_000_000_000
  KTIME    = 111_222_333
  T        = WALL_OFF + KTIME

  def model
    {
      "log_records" => [
        { "time_unix_nano" => T,
          "body" => { "int" => 7 },
          "attributes" => { "spnl.pair.b" => 9, "spnl.channel" => "pair" } },
      ],
      "sums" => [
        { "name" => "spnl.pair.a.total", "unit" => "1",
          "temporality" => "cumulative", "is_monotonic" => true,
          "data_points" => [
            { "attributes" => {}, "start_time_unix_nano" => WALL_OFF,
              "time_unix_nano" => T, "value" => 7 },
          ] },
      ],
      "exponential_histograms" => [
        { "name" => "spnl.pair.b.hist", "unit" => "1", "temporality" => "cumulative",
          "data_points" => [
            # b=9 は scale=0 で (8,16] = positive bucket index 3。
            { "attributes" => {}, "start_time_unix_nano" => WALL_OFF,
              "time_unix_nano" => T, "scale" => 0, "zero_count" => 0,
              "count" => 1, "sum" => 9,
              "positive" => { "offset" => 3, "bucket_counts" => [1] },
              "negative" => { "offset" => 0, "bucket_counts" => [] } },
          ] },
      ],
    }
  end

  def deep(m) = Marshal.load(Marshal.dump(m))

  # ---- 一致と変異検出 ---------------------------------------------------------

  def test_identical_models_compare_equal
    out = O.compare!("spinel_current" => model, "spinel_mlir" => model, "go" => model)
    assert_empty out
  end

  # 各 field を 1 つずつ変異させ、diff が必ず検出すること。
  # [label, 期待する diff 断片, 変異]
  MUTATIONS = [
    ["log timestamp",     "time_unix_nano",
     ->(m) { m["log_records"][0]["time_unix_nano"] += 1 }],
    ["log body (主要値)", "body",
     ->(m) { m["log_records"][0]["body"]["int"] = 8 }],
    ["attribute 値",      "spnl.pair.b",
     ->(m) { m["log_records"][0]["attributes"]["spnl.pair.b"] = 10 }],
    ["attribute key",     "spnl.pair.b",
     ->(m) {
       a = m["log_records"][0]["attributes"]
       a["spnl.pair.bb"] = a.delete("spnl.pair.b")
     }],
    ["log 件数 (イベント列)", "要素数",
     ->(m) { m["log_records"] << m["log_records"][0] }],
    ["sum 値",            "value",
     ->(m) { m["sums"][0]["data_points"][0]["value"] = 8 }],
    ["sum temporality",   "temporality",
     ->(m) { m["sums"][0]["temporality"] = "delta" }],
    ["sum monotonic",     "is_monotonic",
     ->(m) { m["sums"][0]["is_monotonic"] = false }],
    ["sum dp timestamp",  "time_unix_nano",
     ->(m) { m["sums"][0]["data_points"][0]["time_unix_nano"] += 1 }],
    ["exphist scale",     "scale",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["scale"] = 1 }],
    ["exphist zero_count", "zero_count",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["zero_count"] = 1 }],
    ["exphist count",     "count",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["count"] = 2 }],
    ["exphist sum",       "sum",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["sum"] = 18 }],
    ["bucket offset",     "offset",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["positive"]["offset"] = 4 }],
    ["bucket count",      "bucket_counts",
     ->(m) { m["exponential_histograms"][0]["data_points"][0]["positive"]["bucket_counts"] = [2] }],
    ["negative bucket",   "negative",
     ->(m) {
       m["exponential_histograms"][0]["data_points"][0]["negative"] =
         { "offset" => 0, "bucket_counts" => [1] }
     }],
  ].freeze

  def test_each_field_mutation_is_detected
    MUTATIONS.each do |label, fragment, mutate|
      mutated = deep(model)
      mutate.call(mutated)
      d = O.diff(O.normalize(model), O.normalize(mutated))
      refute_empty d, "#{label} の変異を検出できていない"
      assert d.any? { |line| line.include?(fragment) },
             "#{label} の diff が帰属を持たない (期待断片 #{fragment.inspect}):\n  #{d.join("\n  ")}"
    end
  end

  # ---- 空一致の拒否 (陽性対照) ------------------------------------------------

  EMPTY = { "log_records" => [], "sums" => [], "exponential_histograms" => [] }.freeze

  def test_three_empty_paths_do_not_pass
    e = assert_raises(O::BadModel) {
      O.compare!("spinel_current" => EMPTY, "spinel_mlir" => EMPTY, "go" => EMPTY)
    }
    assert_includes e.message, "空モデルを一致と呼ばない"
    assert_includes e.message, "go: log_records が 0 件"
  end

  def test_one_empty_path_does_not_pass
    e = assert_raises(O::BadModel) {
      O.compare!("spinel_current" => model, "go" => EMPTY)
    }
    assert_includes e.message, "go: sums が 0 件"
  end

  def test_all_zero_buckets_are_not_a_witness
    m = deep(model)
    m["exponential_histograms"][0]["data_points"][0]["positive"] =
      { "offset" => 3, "bucket_counts" => [0] }
    failures = O.witness_failures(m, "x")
    assert failures.any? { |f| f.include?("bucket が全て 0") }, failures.inspect
  end

  # ---- 正規化 -----------------------------------------------------------------

  def test_bucket_offset_folding_preserves_meaning
    a = deep(model)
    a["exponential_histograms"][0]["data_points"][0]["positive"] =
      { "offset" => 1, "bucket_counts" => [0, 0, 1, 0] }
    b = deep(model) # offset 3, [1]
    assert_empty O.diff(O.normalize(a), O.normalize(b)),
                 "同じ意味の bucket 表現が正規化で一致しない"
    c = deep(model)
    c["exponential_histograms"][0]["data_points"][0]["positive"] =
      { "offset" => 2, "bucket_counts" => [0, 0, 1, 0] } # 実質 offset 4 — 別の意味
    refute_empty O.diff(O.normalize(b), O.normalize(c)),
                 "違う意味の bucket 表現が正規化で同一視された"
  end

  def test_attribute_order_is_canonical
    a = deep(model)
    a["log_records"][0]["attributes"] = { "spnl.channel" => "pair", "spnl.pair.b" => 9 }
    assert_empty O.diff(O.normalize(a), O.normalize(model))
  end

  # ---- 未知 key / 型違いの拒否 ------------------------------------------------

  def test_unknown_model_keys_are_refused
    m = deep(model)
    m["metrics"] = []
    assert_raises(O::BadModel) { O.normalize(m) }
  end

  def test_missing_temporality_is_refused
    m = deep(model)
    m["sums"][0].delete("temporality")
    assert_raises(O::BadModel) { O.normalize(m) }
  end

  def test_unknown_temporality_is_refused
    m = deep(model)
    m["sums"][0]["temporality"] = "CUMULATIVE" # protobuf enum の綴りをここでは受けない
    assert_raises(O::BadModel) { O.normalize(m) }
  end

  # ---- record bytes の unpack (schema core 層の機構) --------------------------
  #
  # ここの schema は unpack 機構の検査用最小 fixture。実 schema (manifest 由来)
  # に対する unpack は test_otlp_semantic_model.rb が持つ。

  UNPACK_SCHEMA = {
    "core" => { "records" => [
      { "symbol" => "spnl_event_hdr", "size" => 16, "fields" => [
        { "name" => "type",      "offset" => 0,
          "type" => { "kind" => "int", "bits" => 16, "signed" => false, "endianness" => "little" } },
        { "name" => "version",   "offset" => 2,
          "type" => { "kind" => "int", "bits" => 16, "signed" => false, "endianness" => "little" } },
        { "name" => "reserved",  "offset" => 4,
          "type" => { "kind" => "int", "bits" => 32, "signed" => false, "endianness" => "little" } },
        { "name" => "timestamp", "offset" => 8,
          "type" => { "kind" => "int", "bits" => 64, "signed" => false, "endianness" => "little" } },
      ] },
      { "symbol" => "pair_event", "size" => 32, "fields" => [
        { "name" => "hdr", "offset" => 0,
          "type" => { "kind" => "record_ref", "symbol" => "spnl_event_hdr" } },
        { "name" => "a", "offset" => 16,
          "type" => { "kind" => "int", "bits" => 64, "signed" => true, "endianness" => "little" } },
        { "name" => "b", "offset" => 24,
          "type" => { "kind" => "int", "bits" => 64, "signed" => true, "endianness" => "little" } },
      ] },
    ] },
  }.freeze

  def pair_bytes(a: 7, b: 9, type: 0x0102)
    [type, 1, 0, KTIME, a, b].pack("vvVQ<q<q<")
  end

  def test_unpack_pair_record
    f = O.unpack_record(UNPACK_SCHEMA, record: "pair_event", bytes: pair_bytes)
    assert_equal({ "hdr.type" => 0x0102, "hdr.version" => 1, "hdr.reserved" => 0,
                   "hdr.timestamp" => KTIME, "a" => 7, "b" => 9 }, f)
  end

  def test_unpack_sees_byte_mutation
    f = O.unpack_record(UNPACK_SCHEMA, record: "pair_event", bytes: pair_bytes(a: -8))
    assert_equal(-8, f["a"], "負値の __s64 が符号つきで読めること")
  end

  def test_unpack_refuses_length_mismatch
    e = assert_raises(O::BadRecord) {
      O.unpack_record(UNPACK_SCHEMA, record: "pair_event", bytes: pair_bytes + "\0")
    }
    assert_includes e.message, "length mismatch"
  end

  def test_unpack_refuses_unknown_record
    assert_raises(O::BadRecord) {
      O.unpack_record(UNPACK_SCHEMA, record: "nope", bytes: pair_bytes)
    }
  end
end
