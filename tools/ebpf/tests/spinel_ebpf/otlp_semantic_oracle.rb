# frozen_string_literal: true
#
# E156 (P013 Task 9) checkpoint 1: **固定 record -> 正規化 OTLP data model の意味オラクル。**
#
# 比較対象は wire bytes ではなく正規化した OTLP data model:
#
#   Spinel current backend ─┐
#   Spinel MLIR backend    ─┼→ 同じ正規化 OTLP 意味
#   Go consumer            ─┘   (log_records / sums / exponential_histograms)
#
# ## 正規化 OTLP data model (このオラクルの比較単位)
#
#   { "log_records" => [ { "time_unix_nano", "severity_number",
#                          "body" => {"int"=>Integer} | {"str"=>String},
#                          "attributes" => {String => Integer|String} } ],
#     "sums" => [ { "name", "unit", "temporality" ("cumulative"|"delta"),
#                   "is_monotonic",
#                   "data_points" => [ { "attributes", "start_time_unix_nano",
#                                        "time_unix_nano", "value" } ] } ],
#     "exponential_histograms" =>
#         [ { "name", "unit", "temporality",
#             "data_points" => [ { "attributes", "scale", "zero_count",
#                                  "count", "sum",
#                                  "positive" => {"offset","bucket_counts"},
#                                  "negative" => {"offset","bucket_counts"} } ] } ] }
#
# 正規化規則:
#   - attributes は key 順。
#   - bucket_counts は前後の 0 を刈り、先頭の 0 は offset へ畳む
#     ([0,0,1]@offset1 と [1]@offset3 は同じ意味)。
#   - metric は name 順、data_points は内容順 (集合の意味)。
#   - **log_records は並べ替えない** — イベント列の順序は意味の一部
#     (run_mlir_event_seq.sh と同じ規律)。
#   - 未知 key / key 不足 / 型違いは黙って無視せず BadModel で停止する。
#
# ## 既定値へ倒さない (E156 の停止条件をこの module が実装する)
#
# expected_from_schema は schema の telemetry 層 **だけ** から期待モデルを導出
# する。導出できない要素 (telemetry 宣言そのもの / clock 帰属 / temporality /
# monotonic / ExponentialHistogram の scale・bucket 規則 / LogRecord body の
# 出所) は Underivable で停止し、C 実装の慣行 (CUMULATIVE 直書き等) へ黙って
# 倒さない。

require "json"

module SpinelEbpf
  module OtlpSemanticOracle
    class Underivable < StandardError; end
    class BadModel    < StandardError; end
    class BadRecord   < StandardError; end

    MODEL_KEYS    = %w[log_records sums exponential_histograms].freeze
    # severity は schema の telemetry 語彙に無いので model にも置かない —
    # 比較単位は「宣言から導出できる意味」だけ (E156 checkpoint 2)。
    LOG_KEYS      = %w[time_unix_nano body attributes].freeze
    SUM_KEYS      = %w[name unit temporality is_monotonic data_points].freeze
    SUM_DP_KEYS   = %w[attributes start_time_unix_nano time_unix_nano value].freeze
    EH_KEYS       = %w[name unit temporality data_points].freeze
    EH_DP_KEYS    = %w[attributes start_time_unix_nano time_unix_nano scale
                       zero_count count sum positive negative].freeze
    BUCKET_KEYS   = %w[offset bucket_counts].freeze
    TEMPORALITIES = %w[cumulative delta].freeze

    # ---- 正規化 -----------------------------------------------------------------

    def self.check_keys(h, allowed, where)
      raise BadModel, "#{where}: Hash でない: #{h.inspect}" unless h.is_a?(Hash)
      extra   = h.keys - allowed
      missing = allowed - h.keys
      raise BadModel, "#{where}: 未知 key #{extra.inspect}" unless extra.empty?
      raise BadModel, "#{where}: key 不足 #{missing.inspect}" unless missing.empty?
      h
    end

    def self.int!(v, where)
      raise BadModel, "#{where}: Integer でない: #{v.inspect}" unless v.is_a?(Integer)
      v
    end

    def self.num!(v, where)
      raise BadModel, "#{where}: 数値でない: #{v.inspect}" unless v.is_a?(Numeric)
      v
    end

    def self.norm_attrs(h, where)
      raise BadModel, "#{where}: Hash でない: #{h.inspect}" unless h.is_a?(Hash)
      h.each do |k, v|
        raise BadModel, "#{where}: key が String でない: #{k.inspect}" unless k.is_a?(String)
        unless v.is_a?(Integer) || v.is_a?(String)
          raise BadModel, "#{where}[#{k}]: 値が Integer/String でない: #{v.inspect}"
        end
      end
      h.sort_by { |k, _| k }.to_h
    end

    def self.norm_log(lr)
      check_keys(lr, LOG_KEYS, "log_record")
      body = lr["body"]
      ok = body.is_a?(Hash) && body.size == 1 &&
           ((body.key?("int") && body["int"].is_a?(Integer)) ||
            (body.key?("str") && body["str"].is_a?(String)))
      unless ok
        raise BadModel,
              "log_record.body が {\"int\"=>Integer} か {\"str\"=>String} でない: #{body.inspect}"
      end
      { "time_unix_nano" => int!(lr["time_unix_nano"], "log_record.time_unix_nano"),
        "body"           => body.dup,
        "attributes"     => norm_attrs(lr["attributes"], "log_record.attributes") }
    end

    def self.norm_sum(s)
      check_keys(s, SUM_KEYS, "sum")
      unless TEMPORALITIES.include?(s["temporality"])
        raise BadModel,
              "sum #{s["name"].inspect}: temporality が #{TEMPORALITIES.join("/")} でない: " \
              "#{s["temporality"].inspect}"
      end
      unless [true, false].include?(s["is_monotonic"])
        raise BadModel, "sum #{s["name"].inspect}: is_monotonic が bool でない: #{s["is_monotonic"].inspect}"
      end
      dps = Array(s["data_points"]).map { |dp|
        check_keys(dp, SUM_DP_KEYS, "sum #{s["name"].inspect} の data_point")
        { "attributes"           => norm_attrs(dp["attributes"], "sum dp.attributes"),
          "start_time_unix_nano" => int!(dp["start_time_unix_nano"], "sum dp.start_time_unix_nano"),
          "time_unix_nano"       => int!(dp["time_unix_nano"], "sum dp.time_unix_nano"),
          "value"                => num!(dp["value"], "sum dp.value") }
      }
      { "name" => s["name"].to_s, "unit" => s["unit"].to_s,
        "temporality" => s["temporality"], "is_monotonic" => s["is_monotonic"],
        "data_points" => dps.sort_by { |dp| JSON.generate(dp) } }
    end

    def self.norm_buckets(b, where)
      check_keys(b, BUCKET_KEYS, where)
      off    = int!(b["offset"], "#{where}.offset")
      counts = Array(b["bucket_counts"]).map.with_index { |c, i| int!(c, "#{where}.bucket_counts[#{i}]") }
      lead = counts.index { |c| c != 0 }
      return { "offset" => 0, "bucket_counts" => [] } if lead.nil?
      tail = counts.rindex { |c| c != 0 }
      { "offset" => off + lead, "bucket_counts" => counts[lead..tail] }
    end

    def self.norm_eh(h)
      check_keys(h, EH_KEYS, "exponential_histogram")
      unless TEMPORALITIES.include?(h["temporality"])
        raise BadModel,
              "exphist #{h["name"].inspect}: temporality が #{TEMPORALITIES.join("/")} でない: " \
              "#{h["temporality"].inspect}"
      end
      dps = Array(h["data_points"]).map { |dp|
        check_keys(dp, EH_DP_KEYS, "exphist #{h["name"].inspect} の data_point")
        { "attributes" => norm_attrs(dp["attributes"], "exphist dp.attributes"),
          "start_time_unix_nano" => int!(dp["start_time_unix_nano"], "exphist dp.start_time_unix_nano"),
          "time_unix_nano" => int!(dp["time_unix_nano"], "exphist dp.time_unix_nano"),
          "scale"      => int!(dp["scale"], "exphist dp.scale"),
          "zero_count" => int!(dp["zero_count"], "exphist dp.zero_count"),
          "count"      => int!(dp["count"], "exphist dp.count"),
          "sum"        => num!(dp["sum"], "exphist dp.sum"),
          "positive"   => norm_buckets(dp["positive"], "exphist dp.positive"),
          "negative"   => norm_buckets(dp["negative"], "exphist dp.negative") }
      }
      { "name" => h["name"].to_s, "unit" => h["unit"].to_s,
        "temporality" => h["temporality"],
        "data_points" => dps.sort_by { |dp| JSON.generate(dp) } }
    end

    def self.normalize(model)
      check_keys(model, MODEL_KEYS, "model")
      {
        "log_records" => Array(model["log_records"]).map { |lr| norm_log(lr) },
        "sums" => Array(model["sums"]).map { |s| norm_sum(s) }.sort_by { |s| s["name"] },
        "exponential_histograms" =>
          Array(model["exponential_histograms"]).map { |h| norm_eh(h) }.sort_by { |h| h["name"] },
      }
    end

    # ---- 差分 -------------------------------------------------------------------

    def self.diff(a, b, path = "model")
      return [] if a == b
      if a.is_a?(Hash) && b.is_a?(Hash)
        (a.keys | b.keys).flat_map { |k|
          if !a.key?(k)    then ["#{path}.#{k}: 左に無い (右=#{b[k].inspect})"]
          elsif !b.key?(k) then ["#{path}.#{k}: 右に無い (左=#{a[k].inspect})"]
          else diff(a[k], b[k], "#{path}.#{k}")
          end
        }
      elsif a.is_a?(Array) && b.is_a?(Array)
        if a.size != b.size
          ["#{path}: 要素数 #{a.size} != #{b.size}"]
        else
          a.zip(b).each_with_index.flat_map { |(x, y), i| diff(x, y, "#{path}[#{i}]") }
        end
      else
        ["#{path}: #{a.inspect} != #{b.inspect}"]
      end
    end

    # ---- 空一致の拒否 (陽性対照) ------------------------------------------------
    #
    # 「3 経路が空を返して一致」を成功と呼ばないための witness。経路ごとに
    # LogRecord >= 1 / Sum data point >= 1 / exphist に非 0 bucket >= 1 を要求する。

    def self.witness_failures(model, who)
      m = normalize(model)
      out = []
      out << "#{who}: log_records が 0 件" if m["log_records"].empty?
      out << "#{who}: sums が 0 件" if m["sums"].empty?
      m["sums"].each do |s|
        out << "#{who}: sum #{s["name"]} の data_points が 0 件" if s["data_points"].empty?
      end
      out << "#{who}: exponential_histograms が 0 件" if m["exponential_histograms"].empty?
      m["exponential_histograms"].each do |h|
        out << "#{who}: exphist #{h["name"]} の data_points が 0 件" if h["data_points"].empty?
        h["data_points"].each_with_index do |dp, i|
          seen = dp["zero_count"] > 0 ||
                 dp["positive"]["bucket_counts"].any? { |c| c > 0 } ||
                 dp["negative"]["bucket_counts"].any? { |c| c > 0 }
          out << "#{who}: exphist #{h["name"]} dp[#{i}] の bucket が全て 0" unless seen
        end
      end
      out
    end

    # 経路名 => model を受けて、witness 検査ののち先頭経路と残りを突き合わせる。
    # 空 witness が 1 つでもあれば一致と呼ばずに停止する。
    def self.compare!(models)
      raise BadModel, "比較対象が 2 経路未満: #{models.keys.inspect}" if models.size < 2
      empties = models.flat_map { |who, m| witness_failures(m, who) }
      unless empties.empty?
        raise BadModel, "空モデルを一致と呼ばない:\n  " + empties.join("\n  ")
      end
      names = models.keys
      ref = normalize(models[names[0]])
      names[1..].flat_map { |who|
        diff(ref, normalize(models[who])).map { |d| "#{names[0]} vs #{who}: #{d}" }
      }
    end

    # ---- record bytes の unpack (schema core 層) --------------------------------
    #
    # ここは今日でも成立する部分。field の offset / 型 / endianness の正典は
    # schema core.records。length mismatch と未知の型は停止する。

    FMT = { [8, true] => "c", [8, false] => "C",
            [16, true] => "s<", [16, false] => "v",
            [32, true] => "l<", [32, false] => "V",
            [64, true] => "q<", [64, false] => "Q<" }.freeze

    def self.records_by_symbol(schema)
      Array(schema.dig("core", "records")).to_h { |r| [r["symbol"], r] }
    end

    def self.unpack_record(schema, record:, bytes:)
      recs = records_by_symbol(schema)
      r = recs[record]
      raise BadRecord, "schema core に record #{record.inspect} が無い" if r.nil?
      if bytes.bytesize != r["size"]
        raise BadRecord, "record #{record}: length mismatch (#{bytes.bytesize} != #{r["size"]})"
      end
      unpack_fields(recs, r, bytes, 0, "")
    end

    def self.unpack_fields(recs, r, bytes, base, prefix)
      out = {}
      Array(r["fields"]).each do |f|
        t = f["type"]
        case t["kind"]
        when "record_ref"
          inner = recs[t["symbol"]]
          raise BadRecord, "record_ref #{t["symbol"].inspect} が schema に無い" if inner.nil?
          out.merge!(unpack_fields(recs, inner, bytes, base + f["offset"], "#{prefix}#{f["name"]}."))
        when "int"
          unless t["endianness"] == "little"
            raise BadRecord,
                  "field #{prefix}#{f["name"]}: endianness #{t["endianness"].inspect} は未対応 — 停止"
          end
          fmt = FMT[[t["bits"], t["signed"]]]
          raise BadRecord, "field #{prefix}#{f["name"]}: #{t["bits"]}bit を unpack できない" if fmt.nil?
          out["#{prefix}#{f["name"]}"] =
            bytes.byteslice(base + f["offset"], t["bits"] / 8).unpack1(fmt)
        else
          raise BadRecord, "field #{prefix}#{f["name"]}: kind #{t["kind"].inspect} は未対応 — 停止"
        end
      end
      out
    end

    # ---- 期待モデルの導出 (schema telemetry 層) ---------------------------------
    #
    # E156 checkpoint 2 で telemetry 語彙 (logs body / metrics value /
    # metric{kind∈{sum,exponential_histogram}, monotonic, scale, zero_threshold,
    # bucket_rule}) が汎用 schema に載った。ここはその宣言 **だけ** から
    # 固定 record 列に対する OTLP data model を導出する。宣言が書けないもの・
    # ここが実装しない語彙は Underivable で停止 — E156 の停止条件
    # (既定値へ倒さない) をこの導出が実装する。

    # timing の帰属。start は "record_ktime:<fieldpath>" のみ、clock は
    # telemetry.clocks に実在すること、end は "start" のみ。
    def self.event_time_ns(tel, timing, event, wall_offset_ns, where)
      clock_id = timing["clock"].to_s
      clock = Array(tel["clocks"]).find { |c| c["id"] == clock_id }
      if clock.nil?
        raise Underivable,
              "#{where}: timestamp の clock 変換を帰属できない " \
              "(clock #{clock_id.inspect} が telemetry.clocks に無い)"
      end
      start = timing["start"].to_s
      unless start.start_with?("record_ktime:")
        raise Underivable, "#{where}: timing.start #{start.inspect} は未対応 (record_ktime:<field> のみ)"
      end
      unless timing["end"].to_s == "start"
        raise Underivable, "#{where}: timing.end #{timing["end"].inspect} は未対応 (start のみ)"
      end
      field = start.delete_prefix("record_ktime:")
      ktime = event[field]
      raise Underivable, "#{where}: timing の field #{field.inspect} が record 値に無い" if ktime.nil?
      Integer(ktime) + Integer(wall_offset_ns)
    end

    def self.source_value(src, event, where)
      case src["kind"]
      when "field"
        v = event[src["name"]]
        raise Underivable, "#{where}: field #{src["name"].inspect} が record 値に無い" if v.nil?
        v
      when "constant"
        Integer(src["name"])
      else
        raise Underivable, "#{where}: source kind #{src["kind"].inspect} は導出未対応"
      end
    end

    def self.derived_attrs(sig, event, where)
      Array(sig["attributes"]).to_h { |a|
        unless a.dig("presence", "op") == "always"
          raise Underivable,
                "#{where}: attribute #{a["key"].inspect} の presence " \
                "#{a.dig("presence", "op").inspect} は導出未対応 (always のみ)"
        end
        [a["key"], source_value(a["source"], event, "#{where} attribute #{a["key"].inspect}")]
      }
    end

    # otlp_lower_exclusive (scale=0): v > zero_threshold は 2^i < v <= 2^(i+1) の
    # index i へ、v <= zero_threshold は zero_count へ。
    def self.bucket_index_scale0(v, where)
      raise Underivable, "#{where}: 負の観測値 #{v} (negative bucket は未対応)" if v < 0
      # i = ceil(log2(v)) - 1 を整数演算で。v=1 -> -1 (bucket (0.5,1]) も正しい。
      (v - 1).bit_length - 1
    end

    def self.expected_from_schema(schema, record:, events:, wall_offset_ns:)
      tel = schema["telemetry"]
      raise Underivable, "schema に telemetry 層が無い" unless tel.is_a?(Hash)
      signals = Array(tel["signals"]).select { |s| s["record"] == record }
      if signals.empty?
        raise Underivable,
              "telemetry 情報が schema から取得できない: record #{record} の signal が 0 件 " \
              "(coverage.telemetry=#{schema.dig("coverage", "telemetry").inspect} なのに " \
              "telemetry.signals は全体で #{Array(tel["signals"]).size} 件)"
      end
      raise Underivable, "record 列が空 — 空入力から意味は導出しない" if events.empty?
      model = { "log_records" => [], "sums" => [], "exponential_histograms" => [] }
      signals.each do |sig|
        where = "signal #{sig["name"].inspect}"
        times = events.map { |ev| event_time_ns(tel, sig["timing"], ev, wall_offset_ns, where) }
        unless sig.dig("drop_when", "op") == "never"
          raise Underivable,
                "#{where}: drop_when #{sig.dig("drop_when", "op").inspect} は導出未対応 (never のみ)"
        end
        case sig["signal"]
        when "logs"
          body = sig["body"]
          raise Underivable, "#{where}: logs signal に body が無い" unless body.is_a?(Hash)
          events.each_with_index do |ev, i|
            v = source_value(body, ev, "#{where} body")
            model["log_records"] << {
              "time_unix_nano" => times[i],
              "body" => { "int" => Integer(v) },
              "attributes" => derived_attrs(sig, ev, where),
            }
          end
        when "metrics"
          metric = sig["metric"]
          raise Underivable, "#{where}: metrics signal に metric が無い" unless metric.is_a?(Hash)
          unless TEMPORALITIES.include?(metric["temporality"])
            raise Underivable, "#{where}: temporality を決められない (#{metric["temporality"].inspect})"
          end
          vals = events.map { |ev| Integer(source_value(sig["value"], ev, "#{where} value")) }
          dp_times = { "start_time_unix_nano" => times.min, "time_unix_nano" => times.max }
          attrs = derived_attrs(sig, events[0], where)
          case metric["kind"]
          when "sum"
            unless [true, false].include?(metric["monotonic"])
              raise Underivable, "#{where}: Sum の monotonic が宣言に無い"
            end
            model["sums"] << {
              "name" => sig["name"], "unit" => metric["unit"].to_s,
              "temporality" => metric["temporality"],
              "is_monotonic" => metric["monotonic"],
              "data_points" => [dp_times.merge("attributes" => attrs, "value" => vals.sum)],
            }
          when "exponential_histogram"
            unless metric["scale"] == 0
              raise Underivable, "#{where}: scale #{metric["scale"].inspect} は導出未対応 (0 のみ)"
            end
            unless metric["bucket_rule"] == "otlp_lower_exclusive"
              raise Underivable, "#{where}: bucket_rule #{metric["bucket_rule"].inspect} は導出未対応"
            end
            zt = metric["zero_threshold"]
            raise Underivable, "#{where}: zero_threshold が宣言に無い" unless zt.is_a?(Numeric)
            zero = 0
            counts = Hash.new(0)
            vals.each do |v|
              if v <= zt
                zero += 1
              else
                counts[bucket_index_scale0(v, where)] += 1
              end
            end
            if counts.empty?
              pos = { "offset" => 0, "bucket_counts" => [] }
            else
              lo, hi = counts.keys.minmax
              pos = { "offset" => lo,
                      "bucket_counts" => (lo..hi).map { |i| counts[i] } }
            end
            model["exponential_histograms"] << {
              "name" => sig["name"], "unit" => metric["unit"].to_s,
              "temporality" => metric["temporality"],
              "data_points" => [dp_times.merge(
                "attributes" => attrs, "scale" => 0, "zero_count" => zero,
                "count" => vals.size, "sum" => vals.sum,
                "positive" => pos,
                "negative" => { "offset" => 0, "bucket_counts" => [] })],
            }
          else
            raise Underivable, "#{where}: metric kind #{metric["kind"].inspect} は導出未対応"
          end
        when "traces"
          # E156 の対象外 (span は E434/E377 の既存ゲートが持つ)。黙って落とすの
          # ではなく「この model の対象外」という宣言 — traces を必要とする比較は
          # このオラクルを使ってはいけない。
          next
        else
          raise Underivable, "#{where}: 未知の signal 種別 #{sig["signal"].inspect}"
        end
      end
      model
    end

    # 実 record bytes (連結) -> OTLP model (MLIR 経路の consumer 側導出)。
    # unpack は schema core、写像は telemetry 宣言 — expected_from_schema と同じ
    # 宣言を通る (実装は Ruby で共有。C の probe / Go の agent が独立実装)。
    def self.actual_from_record_bytes(schema, record:, bytes:, wall_offset_ns:)
      recs = records_by_symbol(schema)
      r = recs[record]
      raise BadRecord, "schema core に record #{record.inspect} が無い" if r.nil?
      size = r["size"]
      if bytes.bytesize == 0 || bytes.bytesize % size != 0
        raise BadRecord,
              "record #{record}: length mismatch (#{bytes.bytesize} は size #{size} の正の倍数でない)"
      end
      events = (bytes.bytesize / size).times.map { |i|
        unpack_record(schema, record: record, bytes: bytes.byteslice(i * size, size))
      }
      expected_from_schema(schema, record: record, events: events,
                           wall_offset_ns: wall_offset_ns)
    end

    # ---- OTLP/JSON -> model (Spinel current backend の probe 出力) --------------
    #
    # tools/spnl_otlp_model_probe.c は既存 otlp_json builder の出力 (proto3 JSON
    # mapping: 64bit は文字列、enum は数値) を {"logs","sum","exphist"} に束ねて
    # 印字する。ここはそれを比較単位の model へ写す。knowns 以外の temporality
    # enum 等は停止 (黙って cumulative に倒さない)。
    TEMPORALITY_ENUM = { 1 => "delta", 2 => "cumulative" }.freeze

    def self.probe_json_to_model(json_text)
      doc = JSON.parse(json_text)
      logs = otlp_scope_of(doc.fetch("logs"), "resourceLogs", "scopeLogs")
      model = {
        "log_records" => Array(logs["logRecords"]).map { |lr|
          { "time_unix_nano" => Integer(lr.fetch("timeUnixNano")),
            "body" => { "int" => Integer(lr.fetch("body").fetch("intValue")) },
            "attributes" => otlp_attrs(lr["attributes"]) }
        },
        "sums" => [], "exponential_histograms" => [],
      }
      sum_m = otlp_scope_of(doc.fetch("sum"), "resourceMetrics", "scopeMetrics").fetch("metrics").fetch(0)
      s = sum_m.fetch("sum")
      model["sums"] << {
        "name" => sum_m.fetch("name"), "unit" => sum_m["unit"].to_s,
        "temporality" => otlp_temporality(s["aggregationTemporality"]),
        "is_monotonic" => s.fetch("isMonotonic"),
        "data_points" => s.fetch("dataPoints").map { |dp|
          { "attributes" => otlp_attrs(dp["attributes"]),
            "start_time_unix_nano" => Integer(dp.fetch("startTimeUnixNano")),
            "time_unix_nano" => Integer(dp.fetch("timeUnixNano")),
            "value" => Integer(dp.fetch("asInt")) }
        },
      }
      eh_m = otlp_scope_of(doc.fetch("exphist"), "resourceMetrics", "scopeMetrics").fetch("metrics").fetch(0)
      h = eh_m.fetch("exponentialHistogram")
      model["exponential_histograms"] << {
        "name" => eh_m.fetch("name"), "unit" => eh_m["unit"].to_s,
        "temporality" => otlp_temporality(h["aggregationTemporality"]),
        "data_points" => h.fetch("dataPoints").map { |dp|
          { "attributes" => otlp_attrs(dp["attributes"]),
            "start_time_unix_nano" => Integer(dp.fetch("startTimeUnixNano")),
            "time_unix_nano" => Integer(dp.fetch("timeUnixNano")),
            "scale" => Integer(dp.fetch("scale")),
            "zero_count" => Integer(dp.fetch("zeroCount")),
            "count" => Integer(dp.fetch("count")),
            "sum" => dp.fetch("sum"),
            "positive" => otlp_buckets(dp["positive"]),
            "negative" => otlp_buckets(dp["negative"]) }
        },
      }
      model
    end

    def self.otlp_scope_of(doc, res_key, scope_key)
      doc.fetch(res_key).fetch(0).fetch(scope_key).fetch(0)
    end

    def self.otlp_temporality(v)
      t = TEMPORALITY_ENUM[v]
      raise BadModel, "未知の aggregationTemporality: #{v.inspect}" if t.nil?
      t
    end

    def self.otlp_attrs(arr)
      Array(arr).to_h { |kv|
        val = kv.fetch("value")
        v = if val.key?("stringValue") then val["stringValue"]
            elsif val.key?("intValue") then Integer(val["intValue"])
            else raise BadModel, "未知の attribute value: #{val.inspect}"
            end
        [kv.fetch("key"), v]
      }
    end

    def self.otlp_buckets(b)
      return { "offset" => 0, "bucket_counts" => [] } if b.nil?
      { "offset" => Integer(b.fetch("offset", 0)),
        "bucket_counts" => Array(b["bucketCounts"]).map { |c| Integer(c) } }
    end
  end
end
