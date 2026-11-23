# spinel-ebpf L2–L8 横断相関ダッシュボード (Splunk Observability Cloud / 旧 SignalFx)
# ============================================================================
# 対象: OTLP 直送先が Splunk Observability Cloud (SignalFx) の場合。
#       E264 の x-sf-token + ingest.<realm>.signalfx.com が受け手。
#
# 参照している metric / dimension は spinel-ebpf が実際に emit するキーのみ:
#   - metric:    http.server.request.duration  (Float64 explicit-bucket Histogram, unit=s、E272)
#   - dimension: http.route / http.request.method / http.response.status_code (L7)
#   - dimension: tenant (L8)
#   - dimension: net.tcp.established / net.tcp.state_changes (L4、4-tuple keyed、E274)
#   - dimension: client.address / server.address / server.port (L3/L4)
#
# ---------------------------------------------------------------------------
# 【確実性の注記 — 捏造しない】
# * Terraform provider は splunk-terraform/signalfx を想定。リソース名 / 引数 /
#   SignalFlow (program_text) の関数シグネチャは provider・SignalFlow バージョンで
#   変わり得る。特に以下は「provider version により要調整」:
#     - histogram メトリクスからの percentile 取得関数 (histogram(...).percentile(...) /
#       .count() 等)。OTLP explicit-bucket histogram が SignalFx MTS へどう変換されるか
#       (native histogram か、.count/.sum/.bucket の派生 MTS か) は取込経路依存。
#     - dashboard variable (filter) のブロック名 (variable {} / filter {})。
# * このファイルは terraform validate を通していない (実 provider / org / token が要る)。
#   構文は目視整形にとどめ、実適用前に `terraform plan` で確認すること。
# ---------------------------------------------------------------------------

terraform {
  required_providers {
    signalfx = {
      source = "splunk-terraform/signalfx"
      # version = "~> 9.0"  # 実際に使う version に合わせる
    }
  }
}

# 認証: SFX_AUTH_TOKEN (org token) / SFX_API_URL (= https://api.<realm>.signalfx.com)
# を env か variables で渡す。ここでは env 前提。
provider "signalfx" {
  # auth_token = var.sfx_auth_token
  # api_url    = "https://api.us1.signalfx.com"   # <realm> に合わせる
}

# ---------------------------------------------------------------------------
# ダッシュボードグループ
# ---------------------------------------------------------------------------
resource "signalfx_dashboard_group" "spinel_ebpf" {
  name        = "spinel-ebpf L2–L8 xlayer"
  description = "L3/L4 + L7 + L8 cross-layer correlation emitted by a single spinel-ebpf binary (E274/E275)"
}

# ---------------------------------------------------------------------------
# チャート 1: リクエスト遅延 p50 / p90 / p99 (http.route で splitBy)
#   metric: http.server.request.duration (explicit-bucket Histogram)
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "req_duration_pct" {
  name        = "HTTP request duration p50/p90/p99 by route"
  description = "quantiles of http.server.request.duration split by http.route (L7)"

  # NOTE: histogram(...).percentile(...) の正確な SignalFlow 表現は取込・version 依存。
  #       ダッシュボード variable のトークン $route / $tenant を filter に流し込む。
  program_text = <<-EOF
    P50 = histogram('http.server.request.duration', filter=filter('http.route', '$route*') and filter('tenant', '$tenant*')).percentile(50, by=['http.route']).publish(label='p50')
    P90 = histogram('http.server.request.duration', filter=filter('http.route', '$route*') and filter('tenant', '$tenant*')).percentile(90, by=['http.route']).publish(label='p90')
    P99 = histogram('http.server.request.duration', filter=filter('http.route', '$route*') and filter('tenant', '$tenant*')).percentile(99, by=['http.route']).publish(label='p99')
  EOF

  plot_type         = "LineChart"
  unit_prefix       = "Metric"
  axis_left {
    label     = "seconds"
    min_value = 0
  }
}

# ---------------------------------------------------------------------------
# チャート 2: リクエスト数を route / status で splitBy
#   同 histogram の count 系列を使う (request rate)
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "req_count" {
  name        = "HTTP request count by route & status"
  description = "count of http.server.request.duration split by http.route / http.response.status_code (L7)"

  # NOTE: histogram の count 取得表現 (.count() 等) は version 依存。
  program_text = <<-EOF
    C = histogram('http.server.request.duration', filter=filter('tenant', '$tenant*')).count(by=['http.route', 'http.response.status_code']).publish(label='requests')
  EOF

  plot_type   = "ColumnChart"
  unit_prefix = "Metric"
}

# ---------------------------------------------------------------------------
# チャート 3 (本デモの肝): 横断相関パネル
#   L4 の net.tcp.state_changes / net.tcp.established を tenant / http.route で splitBy。
#   → L4 メトリクスと L7/L8 のディメンションが「同一データセット」で並ぶ。
#   これらは semconv 外の spinel-ebpf 独自ディメンション (E274)。
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "xlayer_tcp" {
  name        = "xlayer: TCP state_changes / established by tenant & route"
  description = "L4 (net.tcp.*) split along the L8 (tenant) / L7 (http.route) axes = layers side by side with no join (E274)"

  # net.tcp.* は span 属性としても metric としても運用できる。ここでは
  # gauge/counter metric として取り込んだ前提で書く。metric 化しない場合は
  # traces 側 (下の Dashboard Studio / SPL、または O11y Cloud の APM) で拾う。
  program_text = <<-EOF
    SC = data('net.tcp.state_changes', filter=filter('tenant', '$tenant*') and filter('http.route', '$route*')).sum(by=['tenant', 'http.route']).publish(label='state_changes')
    ES = data('net.tcp.established',   filter=filter('tenant', '$tenant*') and filter('http.route', '$route*')).sum(by=['tenant', 'http.route']).publish(label='established')
  EOF

  plot_type   = "ColumnChart"
  unit_prefix = "Metric"
}

# ---------------------------------------------------------------------------
# チャート 5 (E276): アクセス集中の分類 — access_class rate を proto / tcp_state で splitBy
#   metric:    access_class (Sum=rate、E276)  ← XDP が受信パケットを低カード固定クラスへ分類
#   dimension: proto (icmp/udp/tcp/other) / tcp_state (syn/established)
#   これで「今来ている集中トラフィック」を SYN サージ (proto=tcp,tcp_state=syn) と
#   確立済セッション (established) と ICMP/UDP に一目で分解できる。
#   ※ 送信元 (src_ip) のような高カード次元は載せない (MTS 爆発回避、下記/README の規律)。
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "access_class" {
  name        = "Access-surge classification (rate by proto / tcp_state)"
  description = "access_class split by proto / tcp_state = per-class rate of incoming traffic (L3/L4, E276)"

  program_text = <<-EOF
    A = data('access_class', filter=filter('proto', '*')).sum(by=['proto', 'tcp_state']).publish(label='by_class')
  EOF

  plot_type   = "ColumnChart"
  unit_prefix = "Metric"
}

# ---------------------------------------------------------------------------
# チャート 5b (E277): enforce の可視化 — pass 対 drop レート
#   metric:    access_class (Sum、E277)  ← XDP が分類し ICMP のみ XDP_DROP、他は XDP_PASS
#   dimension: action (pass/drop) / proto (icmp/udp/tcp/other)
#   `access_class` を **action で splitBy** すると「今どれだけ落として (drop)、どれだけ通したか
#   (pass)」が 1 チャートで読める。drop 側 (= ICMP) が閾値を超えたら攻撃/誤設定のサイン。
#   ※ v1 は静的ポリシー (ICMP のみ drop)。動的トグルは拡張候補 (E277 結論参照)。
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "access_action" {
  name        = "Access enforce (pass vs drop rate by proto)"
  description = "access_class split by action (pass/drop) / proto = blocked and passed volume told apart (L3/L4, E277)"

  program_text = <<-EOF
    A = data('access_class', filter=filter('action', 'drop')).sum(by=['proto']).publish(label='dropped')
    B = data('access_class', filter=filter('action', 'pass')).sum(by=['proto']).publish(label='passed')
  EOF

  plot_type   = "ColumnChart"
  unit_prefix = "Metric"
}

# ---------------------------------------------------------------------------
# チャート 4: 現在の遅い route を一覧 (list chart)
# ---------------------------------------------------------------------------
resource "signalfx_list_chart" "slow_routes" {
  name        = "Top routes by p99 latency"
  description = "http.route values with a high p99 (L7)"

  program_text = <<-EOF
    P99 = histogram('http.server.request.duration').percentile(99, by=['http.route']).publish(label='p99')
  EOF

  sort_by                 = "-value"
  max_delay               = 0
  refresh_interval        = 30
}

# ---------------------------------------------------------------------------
# ダッシュボード本体 + variable (filter) = tenant / http.route
# ---------------------------------------------------------------------------
resource "signalfx_dashboard" "xlayer" {
  name            = "L2–L8 xlayer correlation"
  dashboard_group = signalfx_dashboard_group.spinel_ebpf.id
  description     = "one record holds L3/L4 + L7 + L8 together, so any axis can be used for splitBy/filter (E274/E275)"

  # ---- dashboard variable (filter) --------------------------------------
  # NOTE: variable {} ブロック名 / 引数は provider version で異なることがある。
  variable {
    property          = "tenant"
    alias             = "tenant"
    description       = "L8: the application's tenant (from X-Tenant or the route)"
    values            = []          # 空 = 全 tenant。UI で選択
    value_required    = false
  }
  variable {
    property          = "http.route"
    alias             = "route"
    description       = "L7: HTTP route"
    values            = []
    value_required    = false
  }

  # ---- レイアウト --------------------------------------------------------
  chart {
    chart_id = signalfx_time_chart.req_duration_pct.id
    width    = 6
    height   = 2
    row      = 0
    column   = 0
  }
  chart {
    chart_id = signalfx_time_chart.req_count.id
    width    = 6
    height   = 2
    row      = 0
    column   = 6
  }
  chart {
    chart_id = signalfx_time_chart.xlayer_tcp.id
    width    = 8
    height   = 2
    row      = 2
    column   = 0
  }
  chart {
    chart_id = signalfx_list_chart.slow_routes.id
    width    = 4
    height   = 2
    row      = 2
    column   = 8
  }
  chart {
    chart_id = signalfx_time_chart.access_class.id
    width    = 12
    height   = 2
    row      = 4
    column   = 0
  }
  chart {
    chart_id = signalfx_time_chart.access_action.id
    width    = 12
    height   = 2
    row      = 6
    column   = 0
  }
}
