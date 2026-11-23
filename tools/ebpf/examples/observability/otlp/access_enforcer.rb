# E277: 受信トラフィックを XDP で「その場」分類し、あるクラスを **その場で遮断 (XDP_DROP)** しつつ、
#        pass/drop の両方をクラス別レートとして OTLP metrics で送る (Splunk 直送 or Collector 経由)。
#
# spinel-ebpf の芯 = **観測と enforce を 1 バイナリで**。E276 (XDP 分類 → OTLP) に E032 (XDP_DROP で
# skb 化前にパケットを葬る) を統合し、「分類 → 対処 → 報告」を kernel 受信フックだけで完結させる。
# パケットをコピー/ミラーせず、エージェント常駐もなしに、生パケットを見て即座に落とし、かつ
# 落とした数と通した数を外部 (Splunk 等) から区別して観測できる。
#
# 機構（すべて既存 builtin、codegen 無改変。E276 + E032 の合成）:
#   - XDP (E029/E030/E031)      … `SPNL_XDP_IFACE=lo` で受信フックに attach。
#   - pkt_l4_proto (E030)       … L4 プロトコル (ICMP/TCP/UDP/other)。
#   - pkt_tcp_flags (E050)      … TCP の SYN/ACK ビットで「接続開始 (SYN)」と「確立/データ」を弁別。
#   - XDP_DROP (E032)           … skb (sk_buff) 生成前に frame を解放 = IP stack を一切呼ばない最速 drop。
#   - hist_observe_by(key, 1)   … クラス = series key。値 1 で log2 hist の bucket0 に加算 →
#                                  count がそのクラスの発生数 (= rate 元、E085 keyed-hist、overflow 免疫)。
#   - spnl_otlp_series_label / spnl_otlp_metric_push (E271) … 各 series key に固定ラベル (proto/tcp_state/
#                                  **action=pass|drop**) を付け、bpf_hist_keyed を読んで OTLP metrics として push。
#
# ---- ポリシー (v1・静的) ----------------------------------------------------------------------
# **ICMP を XDP_DROP、それ以外 (TCP/UDP/other) は XDP_PASS**。分類カウントは全クラスを
# hist_observe_by で計上し、series ラベルに `action` (pass/drop) を付けるので、OTLP 上で
# **pass 数と drop 数が action 次元で区別して見える** (drop 数 = icmp = ping 発行数と整合)。
#
# ---- 絶対制約 (安全) --------------------------------------------------------------------------
# **TCP と UDP は決して DROP しない。落としてよいのは ICMP のみ。**
# 理由: この分類器自身の OTLP 直送は TCP (HTTP/gRPC) で出ていく。TCP を落とすと自分の telemetry が
# 死んで自滅する。UDP を落とすと DNS 等の巻き添えが出る。ICMP echo は demo 上無害で完全に可逆
# (enforcer を止めれば destructor が XDP を detach し ping はすぐ復活、E032 と同じ) なので、
# drop 対象を ICMP に限定する。この制約は Edoc にも明記。
#
# ---- カーディナリティ規律 (E276 と同じ) ------------------------------------------------------
# クラスは proto × tcp_state = 有限の固定集合なので metrics dimension に安全。**送信元 (src_ip)**
# のような高カード次元は metrics キーにしない (map/MTS 爆発)。src を見たいなら CIDR/top-N か logs へ。
#
# クラス集合 (series key → ラベル):
#   key 1 = ICMP            (action=drop)  ← 唯一の遮断対象
#   key 2 = UDP             (action=pass)
#   key 3 = TCP SYN-only    (action=pass)  SYN 立ち・ACK 無し = 新規接続の開始 = SYN サージの指標
#   key 4 = TCP established  (action=pass)  TCP でそれ以外 = 確立済セッション/データ/ACK/FIN/RST
#   key 5 = other           (action=pass)  非 IPv4 / 非 ICMP/TCP/UDP
#
# build: SPINEL_C_BIN=third_party/spinel/bin/spinel \
#        ruby bin/spinel-ebpf compile examples/observability/otlp/access_enforcer.rb --build -o build_e277
# run:   SPNL_XDP_IFACE=lo OTLP_ENDPOINT=http://127.0.0.1:4318 PROBE_SECONDS=3 ./build_e277/access_enforcer
module Otlp
  ffi_func :spnl_otlp_series_label, [:int, :str, :str], :int
  ffi_func :spnl_otlp_metric_push,  [:str, :str],       :int
end

# ---- XDP: 受信パケットを固定クラスへ分類し、ICMP のみ遮断 ----
def xdp__enforce
  proto = pkt_l4_proto
  if proto == IPPROTO_ICMP
    # ICMP のみ DROP (無害・可逆)。TCP/UDP は絶対に落とさない (自分の telemetry を守る)。
    hist_observe_by(1, 1)
    XDP_DROP
  elsif proto == IPPROTO_UDP
    hist_observe_by(2, 1)
    XDP_PASS
  elsif proto == IPPROTO_TCP
    flags = pkt_tcp_flags
    if (flags & TCP_FLAG_SYN) != 0 && (flags & TCP_FLAG_ACK) == 0
      hist_observe_by(3, 1)   # SYN-only = 接続開始
    else
      hist_observe_by(4, 1)   # 確立/データ
    end
    XDP_PASS
  else
    hist_observe_by(5, 1)
    XDP_PASS
  end
end

ep   = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs = (ENV["PROBE_SECONDS"] || "3").to_i

# 固定の低カードクラス集合を series label として pre-register（userspace が全キーを知っている）。
# `action` 次元で pass/drop を区別する（drop されたのは ICMP のみ）。
Otlp.spnl_otlp_series_label(1, "proto", "icmp")
Otlp.spnl_otlp_series_label(1, "action", "drop")
Otlp.spnl_otlp_series_label(2, "proto", "udp")
Otlp.spnl_otlp_series_label(2, "action", "pass")
Otlp.spnl_otlp_series_label(3, "proto", "tcp")
Otlp.spnl_otlp_series_label(3, "tcp_state", "syn")
Otlp.spnl_otlp_series_label(3, "action", "pass")
Otlp.spnl_otlp_series_label(4, "proto", "tcp")
Otlp.spnl_otlp_series_label(4, "tcp_state", "established")
Otlp.spnl_otlp_series_label(4, "action", "pass")
Otlp.spnl_otlp_series_label(5, "proto", "other")
Otlp.spnl_otlp_series_label(5, "action", "pass")

puts "[access-enforce] XDP classify+drop on " + (ENV["SPNL_XDP_IFACE"] || "lo") +
     " (policy: DROP icmp / PASS tcp,udp,other) -> OTLP " + ep + " every " + secs.to_s + "s"

loop do
  sleep secs
  st = Otlp.spnl_otlp_metric_push("access_class", ep)
  puts "[access-enforce] access_class (pass+drop) pushed -> " + ep + " HTTP " + st.to_s
end
