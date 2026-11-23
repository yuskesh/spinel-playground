# frozen_string_literal: true
#
# otlp_three_path_check.rb — E156 checkpoint 3: kernel 由来の record bytes を
# checkpoint 2 と同じ 3 経路差動 / 受信 capture 照合に通す runner。
#
# 使い方 (run_otlp_kernel_e2e.sh から):
#   ruby -Isrc -Itests tests/runtime/otlp_three_path_check.rb \
#     --records <records.bin> --wall-offset <ns> [--captured <receiver.out>]
#
#   --captured 無し: 3 経路 (Spinel current probe / Spinel MLIR / Go agent) の
#     正規化 model 一致を検査。env SPNL_OTLP_PROBE / SPNL_OTLP_GO_AGENT 必須。
#   --captured 有り: mock receiver が受けた OTLP/JSON (連結) を model へ写し、
#     同じ bytes からの宣言駆動導出 (MLIR 経路) と一致することを検査 —
#     「正常送信の OTLP data model が checkpoint 2 の正規化 model と一致」の実装。
#     wire bytes の一致は要求しない。
#
# 出力: "MATCH n=<records>" / "MATCH_CAPTURED n=<records>" で exit 0。
# 不一致・空 witness は diff を印字して exit 1 (黙って成功にしない)。

require "json"
require "open3"
require "tmpdir"

require "spinel_ebpf/mlir_backend"
require "spinel_ebpf/spbpf_schema"
require "spinel_ebpf/otlp_semantic_oracle"

O = SpinelEbpf::OtlpSemanticOracle
ROOT = File.expand_path("../..", __dir__)
FIX = "187_xdp_emit_pair"
REC = "u_187_xdp_emit_pair_pair_event"

def die(msg)
  warn "FAIL: three_path_check — #{msg}"
  exit 1
end

args = {}
argv = ARGV.dup
until argv.empty?
  case (k = argv.shift)
  when "--records", "--wall-offset", "--captured" then args[k] = argv.shift
  else die("未知の引数: #{k}")
  end
end
records_path = args["--records"] or die("--records が無い")
wall_off = Integer(args["--wall-offset"] || die("--wall-offset が無い"))
bytes = File.binread(records_path)

manifest = SpinelEbpf::MlirBackend.manifest(
  File.join(ROOT, "tests", "fixtures", "#{FIX}.ir"),
  File.join(ROOT, "tests", "fixtures", "#{FIX}.ast"), "u_#{FIX}")
schema = SpinelEbpf::SpbpfSchema.schema_of(manifest, "three_path_check")

mlir = O.actual_from_record_bytes(schema, record: REC, bytes: bytes,
                                  wall_offset_ns: wall_off)
n = bytes.bytesize / 32

if (cap = args["--captured"])
  # 連結された OTLP/JSON を JSON 境界 (brace 深度、文字列考慮) で分割する。
  text = File.read(cap)
  docs = []
  depth = 0
  start = nil
  in_str = false
  esc = false
  text.each_char.with_index do |c, i|
    if in_str
      if esc then esc = false
      elsif c == "\\" then esc = true
      elsif c == '"' then in_str = false
      end
      next
    end
    case c
    when '"' then in_str = true
    when "{"
      start = i if depth.zero?
      depth += 1
    when "}"
      depth -= 1
      docs << JSON.parse(text[start..i]) if depth.zero?
    end
  end
  die("受信 capture に JSON 文書が #{docs.size} 件 (期待 3)") unless docs.size == 3
  wrapper = {}
  docs.each do |d|
    if d.key?("resourceLogs")
      wrapper["logs"] = d
    else
      m = d.fetch("resourceMetrics")[0].fetch("scopeMetrics")[0].fetch("metrics")[0]
      wrapper[m.key?("sum") ? "sum" : "exphist"] = d
    end
  end
  die("受信 capture の内訳が logs/sum/exphist でない: #{wrapper.keys.sort}") unless wrapper.keys.sort == %w[exphist logs sum]
  captured = O.probe_json_to_model(JSON.generate(wrapper))
  diffs = O.compare!("captured" => captured, "declared" => mlir)
  unless diffs.empty?
    warn "FAIL: three_path_check — 受信した OTLP data model が宣言駆動の導出と食い違う:"
    diffs.each { |d| warn "  #{d}" }
    exit 1
  end
  puts "MATCH_CAPTURED n=#{n}"
  exit 0
end

probe = ENV["SPNL_OTLP_PROBE"] or die("SPNL_OTLP_PROBE が無い")
agent = ENV["SPNL_OTLP_GO_AGENT"] or die("SPNL_OTLP_GO_AGENT が無い")

sigs = schema.dig("telemetry", "signals").select { |s| s["record"] == REC }
sum = sigs.find { |s| s.dig("metric", "kind") == "sum" } or die("sum signal が無い")
eh = sigs.find { |s| s.dig("metric", "kind") == "exponential_histogram" } or die("exphist signal が無い")

out, errout, st = Open3.capture3(probe, records_path, wall_off.to_s,
                                 sum["name"], sum.dig("metric", "unit"),
                                 eh["name"], eh.dig("metric", "unit"))
die("current probe が失敗: #{errout}") unless st.success?
cur = O.probe_json_to_model(out)

go = Dir.mktmpdir("three-path") do |dir|
  sch = File.join(dir, "schema.json")
  File.write(sch, JSON.pretty_generate(schema))
  gout, gerr, gst = Open3.capture3(agent, "-schema", sch, "-records", records_path,
                                   "-record", REC, "-wall-offset-ns", wall_off.to_s)
  die("Go otlp-agent が失敗: #{gerr}") unless gst.success?
  JSON.parse(gout)
end

diffs = O.compare!("spinel_current" => cur, "spinel_mlir" => mlir, "go" => go)
unless diffs.empty?
  warn "FAIL: three_path_check — kernel 由来 bytes で 3 経路が食い違う:"
  diffs.each { |d| warn "  #{d}" }
  exit 1
end
puts "MATCH n=#{n}"
