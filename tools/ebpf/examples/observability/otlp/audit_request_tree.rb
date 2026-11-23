# マルチ span トレース組み立て: リクエスト処理の内訳を親子の木にして Span Performance を活かす (E312)
#
# E300 (off-CPU 内訳) / E294 (connect) / E295 (DNS) を **1 リクエストの木**に統合する。SERVER 視点
# (1 tid = 1 リクエスト、recv->send の window)。1 つのハンドラがリクエストを処理する間に:
#   - off-CPU で待った時間 (E300 = 同一 record の子)
#   - 下流の DNS 名前解決 (E295 = udp_sendmsg :53)
#   - 下流の TCP connect (E294 = inet_sock_set_state ESTABLISHED)
# を、runtime が **(同 tgid, window 内 ktime)** で親 (request span) に相関し、共通 trace_id +
# parent_span_id の **木**にする。相関しない子は単一 span にフォールバック (誤った親子より安全)。
#
# これで Splunk APM の Span Performance (waterfall + critical path) が「この 300ms のうち DNS Xms +
# connect Yms + off-CPU 待ち Zms」を描く。単一 span (E274 は 1 span 平坦化) では見えなかった内訳。
#
# probe/codegen は E312 で offcpu record に start_ktime (window 実開始) を additive 追加しただけ
# (dns/conn は pid=tgid + hdr.timestamp を既に持つので無変更)。組み立ては全て runtime (層 2)。
#
# ── ビルド & 送信 (Splunk jp0 直送) ───────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_request_tree.rb --build -o build/audit_request_tree
#   OTEL_SERVICE_NAME=spinel-e312-trace \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_request_tree/audit_request_tree
#   # 観測対象は平文 HTTP サーバ (OpenSSL でないもの)。ハンドラが処理中に DNS/connect する
#   # リクエスト (例 /fetch) を叩くと、その span 配下に resolve / connect / off-CPU wait が nest。
#
# 注意 (実測、E300/E312 Edoc):
#   - SERVER 視点・1 tid = 1 リクエスト (同期ハンドラ) が前提。スレッドプール/非同期は best-effort。
#   - 相関は (tgid, window 内 ktime) のヒューリスティック。並行同一プロセスは取り違え得るので
#     相関しない子は単一 span にフォールバック。

module Otlp
  ffi_func :spnl_otlp_request_tree_push, [:str], :int
end

# --- 親 window: off-CPU (E300) ---
def kprobe__tcp_recvmsg(sk, msg)
  offcpu_recv_stash(sk, msg)   # リクエスト受信バッファを stash
  0
end

def kretprobe__tcp_recvmsg(ret)
  offcpu_begin(ret)            # HTTP リクエストなら off-CPU 窓を開く (start_ktime 記録)
  0
end

def tracepoint__sched__sched_switch(prev_pid, prev_state, next_pid)
  offcpu_account(prev_pid, prev_state, next_pid)   # 窓中の voluntary off-CPU を積む
  0
end

def kprobe__tcp_sendmsg(sk, msg)
  offcpu_emit(sk, msg)         # レスポンス送出で窓を閉じ、window record を emit (start_ktime 付き)
  0
end

# --- 子: DNS 名前解決 + RTT (E311、send->recv を txid で相関) ---
def kprobe__udp_sendmsg(sk, msg, len)
  if udp_dport(sk, msg) == 53   # この datagram の宛先 (E428)
    dns_req_start(sk, msg)     # :53 宛 query の txid で開始時刻を記録
  end
  0
end

def kprobe__udp_recvmsg(sk, msg, len, flags, addr_len)
  # 受信側に同じ問いは無い (msg_name はカーネルがこれから書く出力先) ので
  # socket の接続先で絞る = 接続済み resolver のみ、が正しい上限 (E428)
  if sock_dport(sk) == 53
    dns_resp_stash(sk, msg)    # 応答 payload は copy 後にしか無いので stash
  end
  0
end

def kretprobe__udp_recvmsg(ret)
  dns_emit(ret)                # 応答 txid で相関 -> duration_ns 付き dns_event (RTT)
  0
end

# --- 子: TCP connect (E294) ---
def tracepoint__sock__inet_sock_set_state(skaddr, daddr, dport, family, oldstate, newstate, daddr6_hi, daddr6_lo)
  if newstate == 1   # TCP_ESTABLISHED
    emit_connect(skaddr, daddr, dport, family, oldstate, daddr6_hi, daddr6_lo)
  end
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-tree] request window + off-CPU/DNS/connect into 1 tree -> OTLP span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_request_tree_push(ep)
  puts "[audit-tree] request-tree spans pushed -> " + ep + " HTTP " + st.to_s
end
