/*
 * record_span_parity_test.c — E377: 「Ruby が見る値 == span に出る値」の host オラクル
 *
 * 型付き consumer (`on_emit :<ch> do |ev|`) の各プロパティは、egress の span builder と
 * **同じ関数/同じ値の出力**であるべき (E371 の qname / E374 の method・path・status /
 * E375 の peer・direction / E376 の srtt_us がその形)。E376 はそれを conn の srtt について
 * 実カーネル E2E で示したが、**他 channel は棚卸ししていない**と honest boundary に残していた。
 *
 * ここはその棚卸しを機械化する。1 つの合成 record に対して
 *
 *   (1) 型付き consumer が通る道  : 生成 accessor spnl_rec_<ch>_<prop>()  (= Ruby の ev.<prop>)
 *   (2) wire に出る道             : <ch>_fill_span()                      (= 簡潔形 push と明示形 to_span の共通 builder)
 *
 * を **両方**適用し、プロパティごとに突き合わせる。2 つの道は独立に書かれているので、
 * この test が値を再実装することはない (test が自分自身と一致して終わる、が起きない)。
 *
 * 対応の型は 3 つあり、それぞれ別の assert になる:
 *   (a) span 属性に直接対応  : ev.<prop> == attr("<key>")
 *   (b) span の別要素に対応  : ev.duration_ns == end-start / ev.peer == span 名の主語 / ev.status>=500 == is_error
 *   (c) span に出ない        : その値が **どの属性にも現れない** ことを確認する (pid / cgid)
 *
 * なぜ otlp_agent.c を TU ごと include するか: builder (<ch>_fill_span) と drain 済 record の
 * 器 (g_rec_<ch>) はどちらも static — 簡潔形と明示形が同じ builder を通ることを保証するための
 * 内部構造で、production の API ではない。それを test のために公開すると「test のための API」が
 * 増える。include なら **production は 1 行も変わらない**。
 *
 * 実カーネル・実 probe・collector は不要 (record は合成)。libbpf は otlp_agent.c が
 * ringbuf drain に使うのでリンクだけ要る (drain は呼ばない)。
 *
 *   sh tests/runtime/run_record_span_parity.sh
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

/* 被験体そのもの。static な builder / 器に触るための include (上のコメント参照)。 */
#include "otlp_agent.c"

/* ------------------------------------------------------------------ 検査の道具 */

static int  g_fail;
static int  g_checks;
static const char *g_ch;      /* いま検査中の channel (表の左端) */

/* 属性 key -> 値 (無ければ NULL)。 */
static const char *attr_of(const otlp_kv_t *a, int n, const char *key) {
    for (int i = 0; i < n; i++) if (strcmp(a[i].key, key) == 0) return a[i].val;
    return NULL;
}

/* 表の 1 行。verdict は MATCH / ABSENT / DIFF。 */
static void row(const char *prop, const char *counterpart,
                const char *ev, const char *span, int ok) {
    g_checks++;
    if (!ok) g_fail = 1;
    printf("  %-5s %-13s %-28s %-22s %-22s %s\n",
           g_ch, prop, counterpart, ev, span, ok ? "MATCH" : "**DIFF**");
}

static void row_str(const char *prop, const char *counterpart,
                    const char *ev, const char *span) {
    row(prop, counterpart, ev ? ev : "(null)", span ? span : "(absent)",
        ev && span && strcmp(ev, span) == 0);
}

static void row_int(const char *prop, const char *counterpart,
                    long ev, const char *span_str) {
    char e[32]; snprintf(e, sizeof e, "%ld", ev);
    row(prop, counterpart, e, span_str ? span_str : "(absent)",
        span_str && strcmp(e, span_str) == 0);
}

/* (c) span に出ない: その値が **どの属性の値にも、span 名にも** 現れないこと。
 * 値は各 case で他と衝突しない特徴的な数にしてある (pid=424242 等)。 */
static void row_absent(const char *prop, const char *why, long v,
                       const otlp_kv_t *a, int n, const char *name) {
    char s[32]; snprintf(s, sizeof s, "%ld", v);
    int leaked = (name && strstr(name, s) != NULL);
    for (int i = 0; i < n && !leaked; i++)
        if (strcmp(a[i].val, s) == 0) leaked = 1;
    row(prop, why, s, "(no attribute)", !leaked);
}

static void hdr(const char *title) {
    printf("\n[e377] %s\n", title);
    printf("  %-5s %-13s %-28s %-22s %-22s %s\n",
           "ch", "ev.<prop>", "span counterpart", "ev value", "span value", "verdict");
}

/* 合成 record の共通 header (ktime は off=0 で unix 時刻としてそのまま出る)。 */
static void put_hdr(struct spnl_event_hdr *h, uint64_t ktime) {
    memset(h, 0, sizeof *h);
    h->type = 0x0100; h->version = 1; h->timestamp = ktime;
}

/* ------------------------------------------------------------------ dns */

static void case_dns(void) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[8]; char name[160];

    memset(g_rec_dns, 0, sizeof g_rec_dns[0]);
    spnl_rec_dns_t *r = &g_rec_dns[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    r->pid = 424242;
    snprintf(r->comm, sizeof r->comm, "%s", "getent");
    r->cgid = 909090;
    r->duration_ns = 51000000ULL;            /* E311 dns_emit の RTT */
    /* raw: DNS query header(12B) + length-prefixed labels "example.com" */
    memcpy(r->raw + 12, "\7example\3com\0", 13);
    g_rec_dns_n = 1;

    int nsp = dns_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    if (!nsp) { printf("  FAIL: dns_fill_span returned 0\n"); g_fail = 1; return; }

    g_ch = "dns";
    row_absent("pid", "(c) 属性にならない", spnl_rec_dns_pid(0), a, s.nattrs, name);
    row_str("comm", "process.executable.name", spnl_rec_dns_comm(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_PROCESS_EXECUTABLE_NAME));
    row_absent("cgid", "(c) enricher 入力 (E304)", spnl_rec_dns_cgid(0), a, s.nattrs, name);
    row_int("duration_ns", "spnl.dns.latency_ns", spnl_rec_dns_duration_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_SPNL_DNS_LATENCY_NS));
    {   /* (b) span の長さそのものでもある */
        char span[32]; snprintf(span, sizeof span, "%" PRIu64, s.end_unix_ns - s.start_unix_ns);
        row_int("duration_ns", "(b) span end-start", spnl_rec_dns_duration_ns(0), span);
    }
    row_str("qname", "dns.question.name", spnl_rec_dns_qname(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_DNS_QUESTION_NAME));
    {   /* (b) span 名の主語 */
        char want[192]; snprintf(want, sizeof want, "resolve %s", spnl_rec_dns_qname(0));
        row_str("qname", "(b) span 名", want, name);
    }

    /* duration_ns == 0 (E295 emit_dns は query-only): 属性は出ない = ev も 0 で整合。 */
    r->duration_ns = 0;
    nsp = dns_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    (void)nsp;
    row("duration_ns", "(条件) 0 なら属性なし", "0",
        attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_SPNL_DNS_LATENCY_NS) ? "(present)" : "(absent)",
        spnl_rec_dns_duration_ns(0) == 0 &&
        attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_SPNL_DNS_LATENCY_NS) == NULL);

    /* 源の幅いっぱいの QNAME (E377/E378: cap は両側とも qname の宣言 cap
     * SPNL_REC_DERIVED_DNS_QNAME_CAP。幅の食い違いが復活したらここが落ちるよう、
     * raw[64] が許す最長で見る)。 */
    r->duration_ns = 51000000ULL;
    memset(r->raw + 12, 0, 52);
    {
        int o = 12;
        while (o < 62) { int l = (62 - o - 1 < 9) ? (62 - o - 1) : 9; if (l <= 0) break;
                         r->raw[o++] = (unsigned char)l;
                         for (int k = 0; k < l; k++) r->raw[o++] = 'a' + (unsigned char)(k % 26); }
    }
    dns_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    row_str("qname", "(最長 QNAME) dns.question.name", spnl_rec_dns_qname(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_DNS_ATTR_DNS_QUESTION_NAME));
    printf("        (最長 QNAME = %zu 文字 — raw[64] が許す上限)\n",
           strlen(spnl_rec_dns_qname(0)));
}

/* ------------------------------------------------------------------ conn */

static void conn_case(int v6) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[20]; char name[128];

    memset(g_rec_conn, 0, sizeof g_rec_conn[0]);
    spnl_rec_conn_t *r = &g_rec_conn[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    r->pid = 424242;
    snprintf(r->comm, sizeof r->comm, "%s", "curl");
    r->dport = 8443;
    r->srtt_us = 296;          /* kernel の 1/8 us スケール -> 37 us */
    r->cgid = 909090;
    r->oldstate = v6 ? 3 : 2;  /* passive / active */
    if (!v6) { r->family = 2; r->daddr = 0x0100007F; }
    else {
        r->family = 10;
        unsigned char v6a[16] = {0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,0x01};
        memcpy(&r->daddr6_hi, v6a, 8); memcpy(&r->daddr6_lo, v6a + 8, 8);
    }
    g_rec_conn_n = 1;

    if (!conn_fill_span(r, 0, &seed, &s, a, name, sizeof name)) {
        printf("  FAIL: conn_fill_span returned 0\n"); g_fail = 1; return;
    }

    g_ch = v6 ? "conn6" : "conn";
    row_absent("pid", "(c) 属性にならない", spnl_rec_conn_pid(0), a, s.nattrs, name);
    row_str("comm", "process.executable.name", spnl_rec_conn_comm(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_PROCESS_EXECUTABLE_NAME));
    row_int("dport", "network.peer.port", spnl_rec_conn_dport(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_NETWORK_PEER_PORT));
    row_absent("cgid", "(c) enricher 入力 (E304)", spnl_rec_conn_cgid(0), a, s.nattrs, name);
    {   /* (b) ev.peer = "<network.peer.address>:<network.peer.port>" = span 名の主語 */
        const char *addr = attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_NETWORK_PEER_ADDRESS);
        const char *port = attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_NETWORK_PEER_PORT);
        char want[96]; snprintf(want, sizeof want, "%s:%s", addr ? addr : "?", port ? port : "?");
        row_str("peer", "peer.address + \":\" + port", spnl_rec_conn_peer(0), want);
        char wname[128]; snprintf(wname, sizeof wname, "connect %s", spnl_rec_conn_peer(0));
        row_str("peer", "(b) span 名", wname, name);
    }
    row_str("direction", "spnl.conn.direction", spnl_rec_conn_direction(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_SPNL_CONN_DIRECTION));
    /* E397: 同じ 1 バイトの 2 通りの読み。どちらも「同じ関数の出力」規則の下にある。 */
    row_str("tcp_state", "spnl.conn.tcp_state", spnl_rec_conn_tcp_state(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_SPNL_CONN_TCP_STATE));
    {   /* 2 つの読みが互いに整合すること (SYN_SENT <-> active / SYN_RECV <-> passive)。
         * 表が 1 つになったので、この対応は宣言から従う — 別々の switch なら破れうる。 */
        const char *want = v6 ? "passive" : "active";
        const char *st   = v6 ? "SYN_RECV" : "SYN_SENT";
        row("tcp_state", "direction と同じバイトの読み", st, spnl_rec_conn_tcp_state(0),
            strcmp(spnl_rec_conn_tcp_state(0), st) == 0 &&
            strcmp(spnl_rec_conn_direction(0), want) == 0);
    }
    row_int("srtt_us", "net.peer.srtt_us", spnl_rec_conn_srtt_us(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_NET_PEER_SRTT_US));
    {   /* E376 の当の不整合: 生フィールドは 1/8 us。ev は生値ではない。 */
        row("srtt_us", "(E376) 生フィールドではない", "37", "raw=296 (1/8us)",
            spnl_rec_conn_srtt_us(0) == 37 && r->srtt_us == 296);
    }
}

/* E397: 表が名前を持たない値。ここが設計判断の分かれ目で、他の derivation と違って
 * **何を返すか**に選択肢がある:
 *   - 近い名前を返す        -> もっともらしい嘘 (E394-E396 が潰したのと同じ class)
 *   - 空を返す              -> 数まで消える (`direction` が "other" でやっていること)
 *   - 数を残した形で返す    <- これ。span から state 番号が復元できる
 * 対照として direction を並べる: 同じ record で direction は "other" しか言わない。 */
static void conn_case_unnamed(void) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[20]; char name[128];

    memset(g_rec_conn, 0, sizeof g_rec_conn[0]);
    spnl_rec_conn_t *r = &g_rec_conn[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    snprintf(r->comm, sizeof r->comm, "%s", "curl");
    r->family = 2; r->daddr = 0x0100007F; r->dport = 8443;
    r->oldstate = 99;          /* このカーネルの enum に無い state 番号 */
    g_rec_conn_n = 1;

    if (!conn_fill_span(r, 0, &seed, &s, a, name, sizeof name)) {
        printf("  FAIL: conn_fill_span returned 0\n"); g_fail = 1; return;
    }
    g_ch = "conn?";
    row_str("tcp_state", "spnl.conn.tcp_state", spnl_rec_conn_tcp_state(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_CONN_ATTR_SPNL_CONN_TCP_STATE));
    row("tcp_state", "(E397) 名前が無い値は数を残す", "unnamed(99)",
        spnl_rec_conn_tcp_state(0), strcmp(spnl_rec_conn_tcp_state(0), "unnamed(99)") == 0);
    row("direction", "(対照) 同じ record で direction は", "other",
        spnl_rec_conn_direction(0), strcmp(spnl_rec_conn_direction(0), "other") == 0);
}

/* ------------------------------------------------------------------ l7 */

static void case_l7(void) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[10]; char name[128];

    memset(g_rec_l7, 0, sizeof g_rec_l7[0]);
    spnl_rec_l7_t *r = &g_rec_l7[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    r->pid = 424242;
    snprintf(r->comm, sizeof r->comm, "%s", "python3");
    r->daddr = 0x0100007F; r->dport = 6379; r->family = 2;
    r->start_ktime = 1700000000000000000ULL;
    r->duration_ns = 508000000ULL;
    r->cgid = 909090;
    g_rec_l7_n = 1;

    if (!l7_fill_span(r, 0, &seed, &s, a, name, sizeof name)) {
        printf("  FAIL: l7_fill_span returned 0\n"); g_fail = 1; return;
    }

    g_ch = "l7";
    row_absent("pid", "(c) 属性にならない", spnl_rec_l7_pid(0), a, s.nattrs, name);
    row_str("comm", "process.executable.name", spnl_rec_l7_comm(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_L7_ATTR_PROCESS_EXECUTABLE_NAME));
    row_int("dport", "network.peer.port", spnl_rec_l7_dport(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_L7_ATTR_NETWORK_PEER_PORT));
    row_int("duration_ns", "spnl.l7.latency_ns", spnl_rec_l7_duration_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_L7_ATTR_SPNL_L7_LATENCY_NS));
    {
        char span[32]; snprintf(span, sizeof span, "%" PRIu64, s.end_unix_ns - s.start_unix_ns);
        row_int("duration_ns", "(b) span end-start", spnl_rec_l7_duration_ns(0), span);
    }
    row_absent("cgid", "(c) enricher 入力 (E304)", spnl_rec_l7_cgid(0), a, s.nattrs, name);
}

/* ------------------------------------------------------------------ http */

/* req[64] を "<head>" で埋める (残りは 0 = kernel の bounded copy と同じ形)。 */
static void http_put_req(spnl_rec_http_t *r, const char *head) {
    memset(r->req, 0, sizeof r->req);
    size_t n = strlen(head);
    if (n > sizeof r->req) n = sizeof r->req;
    memcpy(r->req, head, n);
}

static void case_http(void) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[14]; char name[96];   /* E378: latency 属性ぶん 13 -> 14 */

    memset(g_rec_http, 0, sizeof g_rec_http[0]);
    spnl_rec_http_t *r = &g_rec_http[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    r->pid = 424242;
    snprintf(r->comm, sizeof r->comm, "%s", "curl");
    r->daddr = 0x0100007F; r->dport = 8080; r->family = 2;
    r->start_ktime = 1700000000000000000ULL;
    r->duration_ns = 305000000ULL;
    r->cgid = 909090;
    http_put_req(r, "GET /health HTTP/1.1\r\n");
    memcpy(r->resp, "HTTP/1.1 503 S", 14);
    g_rec_http_n = 1;

    if (!http_fill_span(r, 0, &seed, &s, a, name, sizeof name)) {
        printf("  FAIL: http_fill_span returned 0\n"); g_fail = 1; return;
    }

    g_ch = "http";
    row_absent("pid", "(c) 属性にならない", spnl_rec_http_pid(0), a, s.nattrs, name);
    row_str("comm", "process.executable.name", spnl_rec_http_comm(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_PROCESS_EXECUTABLE_NAME));
    row_int("dport", "network.peer.port", spnl_rec_http_dport(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_NETWORK_PEER_PORT));
    row_absent("cgid", "(c) enricher 入力 (E304)", spnl_rec_http_cgid(0), a, s.nattrs, name);
    {   /* E378: l7 と同じく latency 属性を持つ (E377 はここで「http には無い」を記録していた)。
         * span の長さ (end-start) と属性の両方が ev.duration_ns と同値であること。 */
        char span[32]; snprintf(span, sizeof span, "%" PRIu64, s.end_unix_ns - s.start_unix_ns);
        row_int("duration_ns", "(b) span end-start", spnl_rec_http_duration_ns(0), span);
        row_int("duration_ns", "spnl.http.latency_ns", spnl_rec_http_duration_ns(0),
                attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_SPNL_HTTP_LATENCY_NS));
    }
    row_str("method", "http.request.method", spnl_rec_http_method(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_HTTP_REQUEST_METHOD));
    row_str("path", "url.path", spnl_rec_http_path(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_URL_PATH));
    row_int("status", "http.response.status_code", spnl_rec_http_status(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_HTTP_RESPONSE_STATUS_CODE));
    {   /* (b) status>=500 が Span.status=ERROR (RED の error 軸) */
        row("status", "(b) >=500 -> Span ERROR", "503", s.is_error ? "ERROR" : "OK",
            (spnl_rec_http_status(0) >= 500) == (s.is_error != 0));
    }
    {   /* (b) span 名 = "<method> <path>" */
        char want[128];
        snprintf(want, sizeof want, "%s %s", spnl_rec_http_method(0), spnl_rec_http_path(0));
        row_str("method+path", "(b) span 名", want, name);
    }

    /* E299 TLS path (daddr==0 && dport==0): peer 属性は出ない。ev.dport も 0 で整合。 */
    r->daddr = 0; r->dport = 0;
    http_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    row("dport", "(E299 TLS) 属性なし + ev=0", "0",
        attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_NETWORK_PEER_PORT) ? "(present)" : "(absent)",
        spnl_rec_http_dport(0) == 0 &&
        attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_NETWORK_PEER_PORT) == NULL);
    r->daddr = 0x0100007F; r->dport = 8080;

    /* 源の幅いっぱいの path (req[64] が許す最長)。builder は path[64] を渡す。 */
    http_put_req(r, "GET /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1");
    http_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    row_str("path", "(最長 path) url.path", spnl_rec_http_path(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_URL_PATH));
    printf("        (最長 path = %zu 文字 — req[64] が許す上限)\n", strlen(spnl_rec_http_path(0)));

    /* 空白の無いリクエスト head。kernel 側 filter (spnl_is_http_req) は先頭 4 byte しか
     * 見ないので "DELE" で通る = **到達可能**。このとき method トークンは req[64] 全部になる。 */
    http_put_req(r, "DELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELE");
    http_fill_span(r, 0, &seed, &s, a, name, sizeof name);
    row_str("method", "(空白なし head) http.request.method", spnl_rec_http_method(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_HTTP_REQUEST_METHOD));
    printf("        (ev.method = %zu 文字 / span = %zu 文字)\n",
           strlen(spnl_rec_http_method(0)),
           strlen(attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_HTTP_REQUEST_METHOD) ?
                  attr_of(a, s.nattrs, SPNL_EGRESS_HTTP_ATTR_HTTP_REQUEST_METHOD) : ""));
}

/* ------------------------------------------------------------------ offcpu (E379)
 *
 * この channel が typed 化の最後になったのは、egress 属性 3 つが**フィールドそのものでない**
 * から (clamp / 差 / record 外の kallsyms 分類)。表で見るのはまさにそこ:
 *   - ev.offcpu_ns は **clamp 後** (min(offcpu_ns, duration_ns)) で、属性と同値
 *   - ev.oncpu_ns  は **計算値** (duration - clamp) で、属性と同値
 *   - ev.wait_kind は属性 spnl.wait.kind と同じ関数の出力
 * builder は now_unix を受ける (E300: この record は経過時間を運ぶので anchor は "now - dur")。 */

static void offcpu_put_req(spnl_rec_offcpu_t *r, const char *head) {
    memset(r->req, 0, sizeof r->req);
    size_t n = strlen(head);
    if (n > sizeof r->req) n = sizeof r->req;
    memcpy(r->req, head, n);
}

/* 合成 record 1 本を用意して builder を回す (呼び手が値を細工してから使う)。 */
static const uint64_t OC_NOW = 1700000000000000000ULL;

static void case_offcpu(void) {
    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[14]; char name[96];   /* E402: +1 for spnl.wait.stack */

    memset(g_rec_offcpu, 0, sizeof g_rec_offcpu[0]);
    spnl_rec_offcpu_t *r = &g_rec_offcpu[0];
    put_hdr(&r->hdr, OC_NOW);
    r->pid = 424242;
    snprintf(r->comm, sizeof r->comm, "%s", "gunicorn");
    r->duration_ns = 310000000ULL;      /* window (recv -> send) */
    r->offcpu_ns   =  90000000ULL;      /* そのうち待っていた分 */
    r->wait_stack  = -1;                /* stack map が無い環境なので "none" 経路 */
    r->cgid = 909090;
    offcpu_put_req(r, "GET /slow HTTP/1.1\r\n");
    memcpy(r->resp, "HTTP/1.1 503 S", 14);
    g_rec_offcpu_n = 1;

    if (!offcpu_fill_span(r, OC_NOW, &seed, &s, a, name, sizeof name)) {
        printf("  FAIL: offcpu_fill_span returned 0\n"); g_fail = 1; return;
    }

    g_ch = "offcp";
    row_absent("pid", "(c) 属性にならない", spnl_rec_offcpu_pid(0), a, s.nattrs, name);
    row_str("comm", "process.executable.name", spnl_rec_offcpu_comm(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_PROCESS_EXECUTABLE_NAME));
    row_absent("cgid", "(c) enricher 入力 (E304)", spnl_rec_offcpu_cgid(0), a, s.nattrs, name);
    {   /* (b) window の長さ = span の長さ。offcpu には latency 属性が無い (span の長さが正) */
        char span[32]; snprintf(span, sizeof span, "%" PRIu64, s.end_unix_ns - s.start_unix_ns);
        row_int("duration_ns", "(b) span end-start", spnl_rec_offcpu_duration_ns(0), span);
    }
    row_str("method", "http.request.method", spnl_rec_offcpu_method(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_HTTP_REQUEST_METHOD));
    row_str("path", "url.path", spnl_rec_offcpu_path(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_URL_PATH));
    row_int("status", "http.response.status_code", spnl_rec_offcpu_status(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_HTTP_RESPONSE_STATUS_CODE));
    row("status", "(b) >=500 -> Span ERROR", "503", s.is_error ? "ERROR" : "OK",
        (spnl_rec_offcpu_status(0) >= 500) == (s.is_error != 0));
    {   /* (b) span 名 = "<method> <path>" (http と同じ形) */
        char want[192];
        snprintf(want, sizeof want, "%s %s", spnl_rec_offcpu_method(0), spnl_rec_offcpu_path(0));
        row_str("method+path", "(b) span 名", want, name);
    }
    row_int("offcpu_ns", "spnl.offcpu_ns", spnl_rec_offcpu_offcpu_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_OFFCPU_NS));
    row_int("oncpu_ns", "spnl.oncpu_ns", spnl_rec_offcpu_oncpu_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_ONCPU_NS));
    {   /* (b) 3 つは構造的に閉じている: on + off == window */
        char sum[32];
        snprintf(sum, sizeof sum, "%ld", spnl_rec_offcpu_oncpu_ns(0) + spnl_rec_offcpu_offcpu_ns(0));
        row_int("oncpu+offcpu", "(b) == ev.duration_ns", spnl_rec_offcpu_duration_ns(0), sum);
    }
    row_str("wait_kind", "spnl.wait.kind", spnl_rec_offcpu_wait_kind(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_WAIT_KIND));
    row("wait_kind", "(値) wait_stack<0 -> \"none\"", spnl_rec_offcpu_wait_kind(0), "none",
        strcmp(spnl_rec_offcpu_wait_kind(0), "none") == 0);

    /* wait_stack >= 0 だが stack map が無い (host オラクル): 両側とも同じ関数を通るので
     * 同じ "unknown" になる。分類そのものは実 map が要る (honest boundary) が、
     * **2 つの道が一致する**という不変条件はここでも見られる。 */
    r->wait_stack = 4711;
    offcpu_fill_span(r, OC_NOW, &seed, &s, a, name, sizeof name);
    row_str("wait_kind", "(stack map 無し) spnl.wait.kind", spnl_rec_offcpu_wait_kind(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_WAIT_KIND));

    /* E402: 場所 (frames) も、種類 (kind) と同じ 1 回の fetch の別の読み方。ここは
     * stack map の無い host オラクルなので **どちらの道も空** — 「読めなかった」を
     * 属性を出さないことで表し、ev も空文字を返す (= 一致)。frames が実際に取れる
     * 経路は実カーネルが要るので E2E (results/E402) で見る。
     *
     * 実測できる不変条件はもう 1 つあって、こちらはここで pin できる: **opt-in が
     * 片側だけに効いてはならない**。SPNL_STACK_FRAMES を立てても stack map が無い
     * 限り両側とも空のまま (深さの指定は「読めた frames を何本出すか」であって、
     * 読めないものを作り出さない)。 */
    row("wait_stack_trace", "(stack map 無し) spnl.wait.stack", "(empty)",
        attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_WAIT_STACK) ? "(attribute present)" : "(no attribute)",
        spnl_rec_offcpu_wait_stack_trace(0)[0] == '\0' &&
        attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_WAIT_STACK) == NULL);
    row("wait_stack_trace", "(E402) frames と kind は同じ 1 fetch", "same _oc_frames()",
        "same _oc_frames()",
        /* 同じ source を持つ 2 つの読み: 片方が「読めなかった」と言うとき、もう片方も
         * 読めていない。分類が unknown なのに frames が出ている状態は表現できない。 */
        (strcmp(spnl_rec_offcpu_wait_kind(0), "unknown") != 0) ||
        (spnl_rec_offcpu_wait_stack_trace(0)[0] == '\0'));
    r->wait_stack = -1;

    /* **clamp が効く record** (E379 の肝): offcpu_ns > duration_ns は表現可能
     * (待ちは sched_switch の合計、窓は recv/send の対 = 別の測り方)。ev は生値ではなく
     * clamp 後 = 属性と同値、oncpu は 0。生フィールドを expose していたらここだけ食い違う。 */
    r->offcpu_ns = 500000000ULL;   /* window 310ms を超える待ち */
    offcpu_fill_span(r, OC_NOW, &seed, &s, a, name, sizeof name);
    row_int("offcpu_ns", "(clamp) spnl.offcpu_ns", spnl_rec_offcpu_offcpu_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_OFFCPU_NS));
    row("offcpu_ns", "(E379) 生フィールドではない", "310000000", "raw=500000000",
        spnl_rec_offcpu_offcpu_ns(0) == 310000000L && r->offcpu_ns == 500000000ULL);
    row_int("oncpu_ns", "(clamp) spnl.oncpu_ns", spnl_rec_offcpu_oncpu_ns(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_SPNL_ONCPU_NS));
    r->offcpu_ns = 90000000ULL;

    /* 源の幅いっぱいの head (E377/E378 と同じ最長入力)。offcpu は http の derivation を
     * 共有するので、切り詰め位置も http span と同じでなければならない。 */
    offcpu_put_req(r, "DELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELE");
    offcpu_fill_span(r, OC_NOW, &seed, &s, a, name, sizeof name);
    row_str("method", "(空白なし head) http.request.method", spnl_rec_offcpu_method(0),
            attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_HTTP_REQUEST_METHOD));
    printf("        (ev.method = %zu 文字 / span = %zu 文字 — http channel と同じ derivation/cap)\n",
           strlen(spnl_rec_offcpu_method(0)),
           strlen(attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_HTTP_REQUEST_METHOD) ?
                  attr_of(a, s.nattrs, SPNL_EGRESS_OFFCPU_ATTR_HTTP_REQUEST_METHOD) : ""));
    {   /* 同じ head を http record に入れると同じ値になる (2 channel・1 derivation) */
        memset(g_rec_http, 0, sizeof g_rec_http[0]);
        spnl_rec_http_t *h = &g_rec_http[0];
        put_hdr(&h->hdr, OC_NOW);
        h->daddr = 0x0100007F; h->dport = 8080; h->family = 2;
        http_put_req(h, "DELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELETEDELE");
        g_rec_http_n = 1;
        row_str("method", "(2 channel) http の ev.method", spnl_rec_offcpu_method(0),
                spnl_rec_http_method(0));
    }
}

/* ------------------------------------------------------------------ cgid の間接対応物
 *
 * pid / cgid は span 属性にならない (上の表の (c))。ただし cgid は「無関係」ではなく
 * **層 2 enricher (E304) の入力**で、有効にすると同じ record から k8s.* が生える。
 * enricher の有効判定は lazy one-shot (プロセス内で 1 度) なので、素の表とは
 * **別プロセス** (このモード) で見る。fake kubepods 階層の inode を cgid にするので
 * 実 k8s 不要。 */
static int mode_cgid_enricher(void) {
    char cgroot[] = "/tmp/e377_cg_XXXXXX";
    char uidmap[] = "/tmp/e377_uid_XXXXXX";
    const char *uid = "1d0ff866-8ef5-41f5-a2ee-0c1ddcd4c280";
    const char *ctr = "9b763adf6f512b686d81705fe1267700c1de5ab427f527a84ca949b6d7eec866";
    char p[4][512]; struct stat st;

    if (!mkdtemp(cgroot)) { perror("mkdtemp"); return 2; }
    snprintf(p[0], sizeof p[0], "%s/kubepods", cgroot);      mkdir(p[0], 0755);
    snprintf(p[1], sizeof p[1], "%s/burstable", p[0]);       mkdir(p[1], 0755);
    snprintf(p[2], sizeof p[2], "%s/pod%s", p[1], uid);      mkdir(p[2], 0755);
    snprintf(p[3], sizeof p[3], "%s/%s", p[2], ctr);         mkdir(p[3], 0755);
    if (stat(p[3], &st) != 0) { perror("stat"); return 2; }
    { int fd = mkstemp(uidmap); FILE *f = fdopen(fd, "w");
      fprintf(f, "%s kube-system/coredns-ccb96694c-5kpb7\n", uid); fclose(f); }
    setenv("SPNL_K8S_CGROUP_ROOT", cgroot, 1);
    setenv("SPNL_K8S_UIDMAP", uidmap, 1);

    memset(g_rec_dns, 0, sizeof g_rec_dns[0]);
    spnl_rec_dns_t *r = &g_rec_dns[0];
    put_hdr(&r->hdr, 1700000000000000000ULL);
    snprintf(r->comm, sizeof r->comm, "%s", "getent");
    r->cgid = (uint64_t)st.st_ino;         /* = kernel が載せる cgroup id */
    memcpy(r->raw + 12, "\7example\3com\0", 13);
    g_rec_dns_n = 1;

    uint64_t seed = 1;
    otlp_generic_span_t s; otlp_kv_t a[8]; char name[160];
    if (!dns_fill_span(r, 0, &seed, &s, a, name, sizeof name)) return 2;

    printf("[e377] cgid の間接対応物 (層 2 enricher、E304)\n");
    printf("  ev.cgid = %ld (fake kubepods container の inode)\n", spnl_rec_dns_cgid(0));
    for (int i = 0; i < s.nattrs; i++) printf("    attr %-24s = %s\n", a[i].key, a[i].val);
    const char *pod = attr_of(a, s.nattrs, "k8s.pod.name");
    int ok = pod && strcmp(pod, "coredns-ccb96694c-5kpb7") == 0;
    printf("  VERDICT: %s (cgid は属性にならないが、同じ値から k8s.* が解決される)\n",
           ok ? "MATCH" : "**FAIL**");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    /* 層 2 enricher は env 駆動。棚卸しは素の span を見るので明示的に外す
     * (k8s.* が乗ると (c) の「値が漏れていない」検査の意味が変わる)。 */
    unsetenv("SPNL_K8S_CGROUP_ROOT"); unsetenv("SPNL_K8S_UIDMAP");
    unsetenv("SPNL_K8S_IPMAP"); unsetenv("SPNL_K8S_CRIMAP");

    if (argc > 1 && strcmp(argv[1], "--cgid-enricher") == 0) return mode_cgid_enricher();

    printf("[e377] typed consumer accessor  vs  egress span builder (同一 record)\n");
    hdr("dns");   case_dns();
    hdr("conn (IPv4 / active)"); conn_case(0);
    hdr("conn (IPv6 / passive)"); conn_case(1);
    hdr("conn (E397: state the map does not name)"); conn_case_unnamed();
    hdr("l7");    case_l7();
    hdr("http");  case_http();
    hdr("offcpu (E379: clamp / 計算値 / kallsyms 分類)"); case_offcpu();

    printf("\n[e377] %d checks, %s\n", g_checks, g_fail ? "FAIL" : "all MATCH");
    return g_fail ? 1 : 0;
}
