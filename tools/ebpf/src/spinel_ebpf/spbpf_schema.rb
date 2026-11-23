# frozen_string_literal: true
#
# E154 (P013 Task 7): 宣言 manifest -> **P013 schema JSON + spbpf MLIR**。
#
# spbpf-compile の入力を組む。正典は codegen の宣言 (manifest) であって、
# SPINEL-IR text でも生成された .bpf.c でもない。
#
# ## 対象範囲 (垂直スライス)
#
# spbpf dialect が今受け付ける program 種別は **xdp だけ** (SpBPFDialect.cpp の
# `kProgramKinds[]`)。map は hash / array / percpu_array + ringbuf、record は
# E155 で載った (pair channel の emit まで)。object 差動の対象は
# 24_xdp_counter / 187_xdp_emit_pair の垂直スライス。
#
# **範囲外は黙って落とさず Unsupported で停止する。** 「変換できなかったので
# 比較しなかった」を緑にすると、差動が何も見ていない状態が緑に見える。

require "json"

module SpinelEbpf
  module SpbpfSchema
    class Unsupported < StandardError; end

    # spbpf dialect が受け付ける範囲。ここを広げるときは実際に
    # spbpf-compile が通ることを確かめてから広げる。
    PROGRAM_KINDS = %w[xdp].freeze
    # lookup 系 (key/value を持つ) と ringbuf。E155 で percpu_array / ringbuf を追加。
    MAP_KINDS     = %w[hash array percpu_array].freeze

    # XDP の判定 (include/uapi/linux/bpf.h の xdp_action)。
    XDP_VERDICTS = { 0 => "aborted", 1 => "drop", 2 => "pass", 3 => "tx", 4 => "redirect" }.freeze

    # C の綴り -> schema の int 型。**綴りを知らないものは停止**する。
    SCALARS = {
      "__u8"  => [8,  false], "__s8" => [8,  true], "char" => [8, true],
      "__u16" => [16, false], "__s16" => [16, true],
      "__u32" => [32, false], "__s32" => [32, true], "int" => [32, true],
      "__u64" => [64, false], "__s64" => [64, true], "long long" => [64, true],
    }.freeze

    def self.int_type(ctype, where)
      bits, signed = SCALARS[ctype]
      unless bits
        raise Unsupported, "#{where}: C type that cannot be mapped to the schema: #{ctype.inspect}"
      end
      { "kind" => "int", "bits" => bits, "signed" => signed,
        "endianness" => "little", "alignment" => bits / 8 }
    end

    # --- record ID (SPNL_EVT_*) ------------------------------------------------------
    #
    # 数値の単一ソースは include/spnl/types.h。manifest は macro 名 (綴り) だけを
    # 運び、ここで数値へ解決する。**知らない綴りは停止** — 既定値へ倒さない。
    TYPES_H = File.expand_path("../../include/spnl/types.h", __dir__)

    def self.evt_tags
      @evt_tags ||= File.read(TYPES_H)
                        .scan(/^#define\s+(SPNL_EVT_\w+)\s+(0x[0-9a-fA-F]+|\d+)/)
                        .to_h { |name, v| [name, Integer(v)] }
    end

    def self.evt_value(tag, where)
      v = evt_tags[tag]
      if v.nil?
        raise Unsupported,
              "#{where}: record ID #{tag.inspect} is not in include/spnl/types.h."
      end
      v
    end

    # spnl_event_hdr (ADR-002 の 16B 共通ヘッダ)。field の並びの正典は types.h の
    # struct — ここはその綴りを layout (clang 較正済みの MlirShadow.layout_record)
    # へ渡して offset を得る。
    HDR_SYMBOL = "spnl_event_hdr"
    HDR_FIELDS = [
      { name: "type",      ctype: "__u16" },
      { name: "version",   ctype: "__u16" },
      { name: "reserved",  ctype: "__u32" },
      { name: "timestamp", ctype: "__u64" },
    ].freeze

    # --- record の layout ------------------------------------------------------------
    #
    # manifest record (綴りの field 列) -> {symbol, size, align, fields(+offset)}。
    # hdr を参照する record があれば hdr 自身も 1 record として先に足す。
    def self.layouts_of(recs, where)
      known = {}
      out = {}
      needs_hdr = recs.any? { |r|
        Array(r["fields"]).any? { |f| f["ctype"] == "struct #{HDR_SYMBOL}" }
      }
      if needs_hdr
        out[HDR_SYMBOL] = MlirShadow.layout_record(HDR_SYMBOL, HDR_FIELDS, known)
      end
      recs.each do |r|
        fields = Array(r["fields"]).map { |f|
          ctype = f["count"].to_i > 0 ? "#{f["ctype"]} [#{f["count"]}]" : f["ctype"]
          { name: f["name"], ctype: ctype }
        }
        out[r["symbol"]] = MlirShadow.layout_record(r["symbol"], fields, known)
      rescue MlirShadow::Unsupported => e
        raise Unsupported, "#{where}: #{e.message}"
      end
      out
    end

    def self.field_type_json(ctype, where)
      if ctype == "struct #{HDR_SYMBOL}"
        return { "kind" => "record_ref", "symbol" => HDR_SYMBOL }
      end
      if (m = ctype.match(/\A(.+?)\s*\[(\d+)\]\z/))
        return { "kind" => "array", "count" => m[2].to_i,
                 "element" => int_type(m[1].strip, where) }
      end
      int_type(ctype, where)
    end

    def self.record_json(symbol, evt_tag, layout, where)
      {
        "symbol" => symbol,
        "id" => evt_tag ? evt_value(evt_tag, where) : 0,
        "size" => layout[:size], "min_size" => layout[:size],
        "alignment" => layout[:align], "required_through" => "",
        "note" => "",
        "fields" => layout[:fields].map { |f|
          { "name" => f[:name], "offset" => f[:offset], "expose" => "", "note" => "",
            "type" => field_type_json(f[:ctype], "#{where}: #{f[:name]} of record #{symbol}") }
        },
      }
    end

    # --- schema JSON ---------------------------------------------------------------
    def self.schema_of(manifest, where)
      progs = Array(manifest["programs"])
      maps  = Array(manifest["maps"])
      recs  = Array(manifest["records"])

      progs.each do |p|
        unless PROGRAM_KINDS.include?(p["kind"])
          raise Unsupported,
                "#{where}: program kind the spbpf dialect cannot handle: #{p["kind"].inspect} " \
                "(#{p["name"]}). Only #{PROGRAM_KINDS.join(", ")} are accepted."
        end
      end
      maps.each do |m|
        next if m["kind"] == "ringbuf"
        unless MAP_KINDS.include?(m["kind"])
          raise Unsupported,
                "#{where}: map kind the spbpf dialect cannot handle: #{m["kind"].inspect} " \
                "(#{m["symbol"]}). Only #{MAP_KINDS.join(", ")} and ringbuf are accepted."
        end
      end

      layouts = layouts_of(recs, where)
      records_json = []
      records_json << record_json(HDR_SYMBOL, nil, layouts[HDR_SYMBOL], where) if layouts[HDR_SYMBOL]
      recs.each do |r|
        records_json << record_json(r["symbol"], r["evt_tag"], layouts[r["symbol"]], where)
      end

      {
        "version" => 1,
        "coverage" => {
          "programs" => "complete", "maps" => "complete",
          "records" => "complete", "telemetry" => "complete",
        },
        "core" => {
          "records" => records_json,
          "maps" => maps.map { |m|
            if m["kind"] == "ringbuf"
              if m["record"].to_s.empty?
                raise Unsupported,
                      "#{where}: ringbuf #{m["symbol"]} declares no record."
              end
              { "symbol" => m["symbol"], "kind" => "ringbuf",
                "max_entries" => m["max_entries"], "flags" => 0,
                "record" => m["record"], "note" => "" }
            else
              { "symbol" => m["symbol"], "kind" => m["kind"],
                "key"   => int_type(m["key"],   "#{where}: key of map #{m["symbol"]}"),
                "value" => int_type(m["value"], "#{where}: value of map #{m["symbol"]}"),
                "max_entries" => m["max_entries"], "flags" => 0,
                "record" => "", "note" => "" }
            end
          },
          "programs" => progs.map { |p|
            { "name" => p["name"], "kind" => p["kind"], "attach_target" => "",
              "maps" => maps.map { |m| m["symbol"] }, "note" => "" }
          },
        },
        "telemetry" => telemetry_of(recs, where),
        "extensions" => {},
      }
    end

    # --- telemetry (E156 checkpoint 2) ---------------------------------------------
    #
    # pair channel の垂直スライスへ OTel 意味論を宣言する。宣言は汎用語彙
    # (Source / metric{kind,unit,temporality,monotonic,scale,zero_threshold,
    # bucket_rule}) だけで書く — Spinel 固有の関数名・配線は入れない
    # (必要になったら extensions.spinel.ebpf 側)。
    #
    # clock の正典は record_schema.h (生成物 record_schema_gen.json の clocks)。
    # ここで重複定義しない — 綴りを写して schema の語彙 (kernel_source) へ
    # 改名するだけ。
    RECORD_SCHEMA_GEN = File.expand_path("record_schema_gen.json", __dir__)

    def self.canonical_clock(where)
      data = JSON.parse(File.read(RECORD_SCHEMA_GEN))
      c = Array(data["clocks"]).find { |k| k["id"] == "monotonic" }
      if c.nil?
        raise Unsupported,
              "#{where}: record_schema_gen.json has no monotonic clock " \
              "(the canonical file, regenerated by make -C src/codegen_c mirror)."
      end
      { "id" => c["id"], "kernel_source" => c.fetch("kernel_src"),
        "posix_clock" => c.fetch("posix_clock"), "to_wall" => c.fetch("to_wall"),
        "note" => c["note"].to_s }
    end

    PAIR_TIMING = {
      "start" => "record_ktime:hdr.timestamp",
      "clock" => "monotonic",
      "end" => "start",
    }.freeze

    def self.field_source(name)
      { "kind" => "field", "name" => name, "from" => "", "detail" => "" }
    end

    # pair record 1 つに対する 3 signal (LogRecord / Sum / ExponentialHistogram)。
    # temporality/monotonic は現行 C runtime の実挙動 (CUMULATIVE / monotonic) を
    # 宣言へ写した値 — 宣言が実配管を記述する側で、既定値へ倒したのではない。
    def self.pair_signals(sym, where)
      [
        { "name" => "spnl.pair.log", "signal" => "logs", "record" => sym,
          "span_name" => "", "span_kind" => "", "note" => "",
          "timing" => PAIR_TIMING.dup, "drop_when" => { "op" => "never" },
          "body" => field_source("a"),
          "attributes" => [] },
        { "name" => "spnl.pair.a.total", "signal" => "metrics", "record" => sym,
          "span_name" => "", "span_kind" => "", "note" => "",
          "timing" => PAIR_TIMING.dup, "drop_when" => { "op" => "never" },
          "value" => field_source("a"),
          "metric" => { "kind" => "sum", "unit" => "1",
                        "temporality" => "cumulative", "monotonic" => true },
          "attributes" => [] },
        { "name" => "spnl.pair.b.hist", "signal" => "metrics", "record" => sym,
          "span_name" => "", "span_kind" => "", "note" => "",
          "timing" => PAIR_TIMING.dup, "drop_when" => { "op" => "never" },
          "value" => field_source("b"),
          "metric" => { "kind" => "exponential_histogram", "unit" => "1",
                        "temporality" => "cumulative", "scale" => 0,
                        "zero_threshold" => 0,
                        "bucket_rule" => "otlp_lower_exclusive" },
          "attributes" => [] },
      ]
    end

    def self.telemetry_of(recs, where)
      pair = recs.select { |r| r["evt_tag"] == "SPNL_EVT_EMIT_PAIR" }
      if pair.empty?
        # record を持たない unit に OTLP 意味論は無い — 空 + complete は正直。
        return { "clocks" => [], "value_maps" => [], "bounds_sets" => [],
                 "signals" => [] }
      end
      if pair.size > 1
        # signal 名が record ごとに要る。垂直スライスは 1 record — 増えたら
        # 名前の規則を決めてから広げる (黙って 1 つ目だけ宣言しない)。
        raise Unsupported,
              "#{where}: there are #{pair.size} pair records. A telemetry declaration covers " \
              "only the vertical slice of 1 pair record per unit."
      end
      { "clocks" => [canonical_clock(where)],
        "value_maps" => [], "bounds_sets" => [],
        "signals" => pair_signals(pair[0]["symbol"], where) }
    end

    # --- spbpf MLIR ----------------------------------------------------------------
    #
    # MLIR の型は schema と一致していなければ spbpf-compile の schema 照合で落ちる
    # (それが狙い — 片方だけ直しても通らない)。
    def self.mlir_int(ctype, where)
      t = int_type(ctype, where)
      "i#{t["bits"]}"
    end

    def self.verdict_literal(p, where)
      v = p["verdict"]
      case v
      when Integer
        name = XDP_VERDICTS[v]
        unless name
          raise Unsupported,
                "#{where}: no spelling for the XDP verdict value: #{v} (#{p["name"]})"
        end
        name
      when "dynamic", "unknown", nil
        # E154 の対象は定数 verdict の垂直スライス。非定数は object を作らない。
        raise Unsupported,
              "#{where}: the verdict of program #{p["name"]} is not constant (#{v.inspect}). " \
              "E154's object differential is limited to constant verdicts."
      else
        raise Unsupported, "#{where}: unknown verdict form: #{v.inspect}"
      end
    end

    # --- program body ---------------------------------------------------------------
    #
    # manifest の body steps -> spbpf op 列。**body が known でない program から
    # object は作らない** — verdict だけ合っていて map を触らない stub を
    # 「同じ意味の program」と呼ばないため (Mac の指摘 2026-08-25: 宣言と verdict
    # の外形だけ揃えた program は 24_xdp_counter の shadow codegen ではない)。
    # emit_pair step の MLIR。tpl_emit_pair の C と同じ意味:
    #   reserve -> hdr(type/version/reserved/timestamp) + a + b -> submit
    #   reserve 失敗 -> lost (percpu_array) の key=0 slot += 1
    def self.emit_pair_ops(i, s_, ctx, where)
      rb = ctx[:maps_by_symbol][s_["map"]]
      if rb.nil? || rb["kind"] != "ringbuf"
        raise Unsupported, "#{where}: emit_pair step does not point at a ringbuf: #{s_["map"].inspect}"
      end
      rec_sym = rb["record"]
      rec = ctx[:records_by_symbol][rec_sym]
      layout = ctx[:layouts][rec_sym]
      if rec.nil? || layout.nil?
        raise Unsupported, "#{where}: record #{rec_sym.inspect} of ringbuf #{rb["symbol"]} is not declared."
      end
      tag = evt_value(rec["evt_tag"] || raise(Unsupported, "#{where}: record #{rec_sym} has no evt_tag."), where)
      offs = layout[:fields].to_h { |f| [f[:name], f[:offset]] }
      %w[hdr a b].each do |fn|
        raise Unsupported, "#{where}: record #{rec_sym} has no field #{fn}." unless offs.key?(fn)
      end
      hdr = offs["hdr"]
      # lost counter は unit 名からではなく **同じ unit の pair map の綴り**から
      # 導く (manifest の unit 欄は CLI 経路では sanitize 前の綴りで入ることが
      # ある — map symbol は常に codegen の g_unit で組まれているので、そちらが
      # 信頼できる)。ずれていれば下の宣言検査で停止する。
      lost_sym = "#{rb["symbol"].sub(/_pair_events\z/, "")}_lost"
      lost = ctx[:maps_by_symbol][lost_sym]
      if lost.nil? || lost["kind"] != "percpu_array"
        raise Unsupported, "#{where}: lost counter #{lost_sym.inspect} (percpu_array) is not declared."
      end
      lkey = mlir_int(lost["key"],   "#{where}: key of map #{lost_sym}")
      lval = mlir_int(lost["value"], "#{where}: value of map #{lost_sym}")
      lmt  = "!spbpf.map<\"percpu_array\", #{lkey}, #{lval}>"
      rt   = "!spbpf.record<\"#{rec_sym}\", #{layout[:size]}>"
      <<~OPS.chomp
          %e#{i}r = spbpf.ringbuf.reserve "#{rb["symbol"]}" : !spbpf.maybe_reservation<#{rt}>
          spbpf.ringbuf.if_reserved %e#{i}r : !spbpf.maybe_reservation<#{rt}> present {
          ^present(%e#{i}p: !spbpf.reservation<#{rt}>):
            %e#{i}t = arith.constant #{tag} : i16
            spbpf.ringbuf.store_field %e#{i}p[#{hdr + 0}], %e#{i}t : !spbpf.reservation<#{rt}>, i16
            %e#{i}v = arith.constant 1 : i16
            spbpf.ringbuf.store_field %e#{i}p[#{hdr + 2}], %e#{i}v : !spbpf.reservation<#{rt}>, i16
            %e#{i}z = arith.constant 0 : i32
            spbpf.ringbuf.store_field %e#{i}p[#{hdr + 4}], %e#{i}z : !spbpf.reservation<#{rt}>, i32
            %e#{i}ts = spbpf.ktime.ns : i64
            spbpf.ringbuf.store_field %e#{i}p[#{hdr + 8}], %e#{i}ts : !spbpf.reservation<#{rt}>, i64
            %e#{i}a = arith.constant #{s_["a"]} : i64
            spbpf.ringbuf.store_field %e#{i}p[#{offs["a"]}], %e#{i}a : !spbpf.reservation<#{rt}>, i64
            %e#{i}b = arith.constant #{s_["b"]} : i64
            spbpf.ringbuf.store_field %e#{i}p[#{offs["b"]}], %e#{i}b : !spbpf.reservation<#{rt}>, i64
            spbpf.ringbuf.submit %e#{i}p : !spbpf.reservation<#{rt}>
            spbpf.yield
          } absent {
            %e#{i}lk = arith.constant 0 : #{lkey}
            %e#{i}lp = spbpf.map.lookup %#{lost_sym}[%e#{i}lk]
                : #{lmt}, #{lkey} -> !spbpf.maybe_ref<#{lval}>
            spbpf.ref.check %e#{i}lp : !spbpf.maybe_ref<#{lval}> present {
            ^present(%e#{i}lr: !spbpf.borrowed<#{lval}>):
              %e#{i}lc = spbpf.ref.load %e#{i}lr : !spbpf.borrowed<#{lval}> -> #{lval}
              %e#{i}l1 = arith.constant 1 : #{lval}
              %e#{i}ln = arith.addi %e#{i}lc, %e#{i}l1 : #{lval}
              spbpf.ref.store %e#{i}lr, %e#{i}ln : !spbpf.borrowed<#{lval}>, #{lval}
              spbpf.yield
            } absent {
              spbpf.yield
            }
            spbpf.yield
          }
      OPS
    end

    def self.body_ops(p, ctx, where)
      maps_by_symbol = ctx[:maps_by_symbol]
      body = p["body"]
      unless body.is_a?(Hash) && body["state"] == "known"
        raise Unsupported,
              "#{where}: the body of program #{p["name"]} is not classified " \
              "(state=#{body.is_a?(Hash) ? body["state"].inspect : body.inspect}). " \
              "No MLIR object is made from a body that cannot be classified."
      end
      Array(body["steps"]).each_with_index.map { |s, i|
        next emit_pair_ops(i, s, ctx, where) if s["op"] == "emit_pair"
        unless s["op"] == "map_rmw_add"
          raise Unsupported, "#{where}: unknown body step: #{s["op"].inspect} (#{p["name"]})"
        end
        m = maps_by_symbol[s["map"]]
        if m.nil?
          raise Unsupported,
                "#{where}: body step points at an undeclared map: #{s["map"].inspect}"
        end
        key = mlir_int(m["key"],   "#{where}: key of map #{m["symbol"]}")
        val = mlir_int(m["value"], "#{where}: value of map #{m["symbol"]}")
        mt  = "!spbpf.map<\"#{m["kind"]}\", #{key}, #{val}>"
        sym = "%#{m["symbol"]}"
        # cc_emit_ivar_rmw の C (lookup -> miss は 0 -> 加算 -> update) と同じ意味。
        # atomic_add にしないのは現行 backend が非 atomic の RMW だから — 意味を
        # 揃える側が正で、強い方へ黙って倒さない。
        <<~OPS.chomp
            %k#{i} = arith.constant 0 : #{key}
            %maybe#{i} = spbpf.map.lookup #{sym}[%k#{i}]
                : #{mt}, #{key} -> !spbpf.maybe_ref<#{val}>
            %z#{i} = arith.constant 0 : #{val}
            %cur#{i} = spbpf.ref.check %maybe#{i} : !spbpf.maybe_ref<#{val}> -> #{val} present {
            ^present(%ref#{i}: !spbpf.borrowed<#{val}>):
              %v#{i} = spbpf.ref.load %ref#{i} : !spbpf.borrowed<#{val}> -> #{val}
              spbpf.yield %v#{i} : #{val}
            } absent {
              spbpf.yield %z#{i} : #{val}
            }
            %d#{i} = arith.constant #{s["delta"]} : #{val}
            %n#{i} = arith.addi %cur#{i}, %d#{i} : #{val}
            spbpf.map.update #{sym}[%k#{i}], %n#{i} : #{mt}, #{key}, #{val}
        OPS
      }
    end

    def self.mlir_of(manifest, where)
      maps = Array(manifest["maps"])
      recs = Array(manifest["records"])
      ctx = {
        unit: manifest["unit"],
        maps_by_symbol: maps.to_h { |m| [m["symbol"], m] },
        records_by_symbol: recs.to_h { |r| [r["symbol"], r] },
        layouts: layouts_of(recs, where),
      }
      # ringbuf は reserve が名前で参照する — block 引数 (lookup 系 map の handle)
      # にはならない (key/value を持たないので map 型が書けない)。
      argmaps = maps.reject { |m| m["kind"] == "ringbuf" }
      Array(manifest["programs"]).map { |p|
        syms = argmaps.map { |m| "@#{m["symbol"]}" }
        args = argmaps.map { |m|
          key = mlir_int(m["key"],   "#{where}: key of map #{m["symbol"]}")
          val = mlir_int(m["value"], "#{where}: value of map #{m["symbol"]}")
          "%#{m["symbol"]}: !spbpf.map<\"#{m["kind"]}\", #{key}, #{val}>"
        }
        head = "spbpf.program @#{p["name"]} \"#{p["sec"]}\""
        head += " maps [#{syms.join(", ")}]" unless syms.empty?
        blockargs = ["%ctx: !spbpf.ctx<\"#{p["kind"]}\">"] + args
        ops = body_ops(p, ctx, where)
        <<~MLIR
          #{head} {
          ^bb0(#{blockargs.join(", ")}):
          #{ops.map { |o| o + "\n" }.join}  spbpf.verdict "#{verdict_literal(p, where)}"
          }
        MLIR
      }.join("\n")
    end
  end
end
