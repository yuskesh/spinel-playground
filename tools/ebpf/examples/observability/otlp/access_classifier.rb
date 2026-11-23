# E276: アクセス集中中のサーバへの受信トラフィックを XDP で「その場」分類し、
#        クラス別レート (rate) を OTLP metrics で送る（Splunk 直送 or Collector 経由）。
#
# 「今来ている集中トラフィックを分類したい」— 障害・攻撃・スパイク時に、生パケットを
# コピー/ミラーせずに **kernel の受信フックで直接**、低カードの固定クラスへ振り分けて
# 数える。src_ip のような高カード次元は metrics に載せない（MTS 爆発を避ける、下記規律）。
#
# 機構（すべて既存 builtin、codegen 無改変）:
#   - XDP (E029/E030/E031)      … `SPNL_XDP_IFACE=lo` で受信フックに attach。
#   - pkt_l4_proto (E030)       … L4 プロトコル (ICMP/TCP/UDP/other)。
#   - pkt_tcp_flags (E050)      … TCP の SYN/ACK ビットで「接続開始 (SYN)」と「確立/データ」を弁別。
#   - hist_observe_by(key, 1)   … クラス = series key。値 1 で log2 hist の bucket0 に加算 →
#                                  count がそのクラスの発生数 (= rate 元) になる (E085 keyed-hist、
#                                  overflow 免疫、XDP でも HASH lookup+atomic add で成立)。
#   - spnl_otlp_series_label / spnl_otlp_metric_push (E271) … 各 series key に固定ラベルを付け、
#                                  bpf_hist_keyed を読んでラベル付き OTLP metrics として push。
#
# クラス集合（低カード・固定。userspace が全キーを pre-register できるので E271 経路が使える）:
#   key 1 = ICMP
#   key 2 = UDP
#   key 3 = TCP SYN-only        (SYN 立ち・ACK 無し = 新規接続の開始 = 集中/SYN サージの指標)
#   key 4 = TCP established     (TCP でそれ以外 = 確立済セッション/データ/ACK/FIN/RST)
#   key 5 = other               (非 IPv4 / 非 ICMP/TCP/UDP)
#
# カーディナリティ規律（重要、docs/research/spinel_ebpf_value_proposition.md と一致）:
#   本デモのクラスは有限・固定なので metrics dimension に安全に載る。**送信元 (src_ip)** のような
#   高カード次元は metrics キーにしない（map/MTS が爆発する）。本番で送信元を見たいなら
#   CIDR バケット/top-N に畳むか、events (logs) へ回す。ここでは L3/L4 の proto/tcp_state だけを扱う。
#
# build: SPINEL_C_BIN=third_party/spinel/bin/spinel \
#        ruby bin/spinel-ebpf compile examples/observability/otlp/access_classifier.rb --build -o build
# run:   SPNL_XDP_IFACE=lo OTLP_ENDPOINT=http://127.0.0.1:4318 PROBE_SECONDS=3 ./build/access_classifier
module Otlp
  ffi_func :spnl_otlp_series_label, [:int, :str, :str], :int
  ffi_func :spnl_otlp_metric_push,  [:str, :str],       :int
end

# ---- XDP: 受信パケットを固定クラスへ分類してカウント ----
def xdp__classify
  proto = pkt_l4_proto
  if proto == IPPROTO_ICMP
    hist_observe_by(1, 1)
  elsif proto == IPPROTO_UDP
    hist_observe_by(2, 1)
  elsif proto == IPPROTO_TCP
    flags = pkt_tcp_flags
    if (flags & TCP_FLAG_SYN) != 0 && (flags & TCP_FLAG_ACK) == 0
      hist_observe_by(3, 1)   # SYN-only = 接続開始
    else
      hist_observe_by(4, 1)   # 確立/データ
    end
  else
    hist_observe_by(5, 1)
  end
  XDP_PASS
end

ep   = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs = (ENV["PROBE_SECONDS"] || "3").to_i

# 固定の低カードクラス集合を series label として pre-register（userspace が全キーを知っている）。
Otlp.spnl_otlp_series_label(1, "proto", "icmp")
Otlp.spnl_otlp_series_label(2, "proto", "udp")
Otlp.spnl_otlp_series_label(3, "proto", "tcp")
Otlp.spnl_otlp_series_label(3, "tcp_state", "syn")
Otlp.spnl_otlp_series_label(4, "proto", "tcp")
Otlp.spnl_otlp_series_label(4, "tcp_state", "established")
Otlp.spnl_otlp_series_label(5, "proto", "other")

puts "[access-class] XDP classifier on " + (ENV["SPNL_XDP_IFACE"] || "lo") +
     " -> OTLP " + ep + " every " + secs.to_s + "s"

loop do
  sleep secs
  st = Otlp.spnl_otlp_metric_push("access_class", ep)
  puts "[access-class] access_class pushed -> " + ep + " HTTP " + st.to_s
end
