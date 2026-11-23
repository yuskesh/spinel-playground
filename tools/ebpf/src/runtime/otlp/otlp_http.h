/*
 * otlp_http.h — OTLP/HTTP+protobuf 転送 (ADR-012 / P003 S1)
 *
 * OTLP/HTTP の最小 HTTP/1.1 クライアント。encode 済 protobuf を
 * `POST <path>` で Collector に送る。TLS / gRPC は対象外 (後段)。
 * 依存は POSIX socket のみ (libbpf / sp_net 非依存、host でもそのまま動く)。
 */
#ifndef SPNL_OTLP_HTTP_H
#define SPNL_OTLP_HTTP_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>   /* E402: otlp_env_kv_list (static inline) */
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * service.instance.id を返す (OBI/semconv v1.41.0 resource 属性、E272)。
 * env OTEL_SERVICE_INSTANCE_ID があればそれ、無ければ "<hostname>-<pid>" を一度だけ
 * 生成してプロセス内でキャッシュ。protobuf (otlp_pbutil.h) と JSON (otlp_json.c) の
 * resource encoder が共有する (POSIX のみ・nanopb 非依存なので両経路から使える)。
 */
static inline const char *otlp_service_instance_id(void) {
    static char cache[160];
    static int done = 0;
    if (!done) {
        const char *env = getenv("OTEL_SERVICE_INSTANCE_ID");
        if (env && env[0]) {
            snprintf(cache, sizeof cache, "%s", env);
        } else {
            char host[96];
            if (gethostname(host, sizeof host) != 0) snprintf(host, sizeof host, "unknown");
            host[sizeof host - 1] = 0;
            snprintf(cache, sizeof cache, "%s-%d", host, (int)getpid());
        }
        done = 1;
    }
    return cache;
}

/*
 * "http://host:port" 形式の endpoint を host / port に分解する (path は無視)。
 * scheme 省略可、port 省略時は "4318"。成功で 0、失敗で -1。
 */
int otlp_http_parse_endpoint(const char *endpoint,
                             char *host, size_t hostlen,
                             char *port, size_t portlen);

/*
 * E290: endpoint URL の path 部分を path に取り出す ("https://h/v2/trace/otlp" -> "/v2/trace/otlp")。
 * path が無ければ空文字。OTel の per-signal endpoint を verbatim で使うため。成功で 0。
 */
int otlp_http_endpoint_path(const char *endpoint, char *path, size_t pathlen);

/*
 * E156: exporter transport の self-metrics (送信失敗 / retry / 拒否)。
 * kernel 側の drop (ringbuf lost / channel balance) とは別勘定 —
 * ここは「送ろうとして何が起きたか」だけを数える。process 内カウンタで、
 * OTLP としては送らない (exporter が壊れているときに exporter で送る形は
 * 自己矛盾する — 出口は report 行と検査コード)。
 */
typedef struct {
    unsigned long long attempts; /* otlp_http_post の呼び出し数 */
    unsigned long long retries;  /* connect の再試行回数 (初回は含まない) */
    unsigned long long failures; /* 転送失敗 (-1 で返った数) */
    unsigned long long rejected; /* HTTP >= 300 で受け取られなかった数 */
} otlp_http_stats_t;

const otlp_http_stats_t *otlp_http_stats(void);

/* "spnl.otlp attempts=.. retries=.. failures=.. rejected=.." を 1 行書く。 */
void otlp_http_stats_report(FILE *out);

/*
 * body を http://host:port<path> に Content-Type 付きで POST する。
 *  - 成功 (HTTP 応答を受信): 0 を返し *status に HTTP ステータスコードを格納
 *  - 転送失敗 (名前解決/接続/送受信): -1 を返し err にメッセージ (err 非 NULL 時)
 * connect は最大 max_retries 回まで指数バックオフで再試行する (0 = 既定 5)。
 */
/* tls != 0 のとき TLS (https://) で送る (mbedTLS、要 OTLP_WITH_TLS ビルド)。0 は平文。 */
int otlp_http_post(const char *host, const char *port, const char *path,
                   const char *content_type,
                   const uint8_t *body, size_t body_len,
                   int tls,
                   int max_retries,
                   int *status, char *err, size_t errlen);

/* --- P003 option (E264): "サクッと直送" 用イネーブラ。env 駆動 (再コンパイル不要)。 --- */

/* 1 ヘッダ (key/value)。HTTP は "key: value"、gRPC は HPACK literal (key は小文字化)。 */
typedef struct { char key[128]; char val[512]; } otlp_kv_t;

/* "k1=v1,k2=v2" 形の env を 1 つの文法としてパースする (E402)。空 key / '=' 無しの
 * ペアは捨て、前後空白は trim。この形の env は 2 つある (E264 の
 * OTEL_EXPORTER_OTLP_HEADERS と E402 の OTEL_RESOURCE_ATTRIBUTES) ので、パーサも
 * 1 つにしてある — 2 つ書くのは「ヘッダは効くのに resource 属性だけ最後のペアを
 * 落とす」の作り方。
 *
 * otlp_service_instance_id と同じ理由で **header の static inline**: protobuf 経路
 * (otlp_pbutil.h) と JSON 経路 (otlp_json.c) の両方が使い、JSON encoder の単体
 * テストは otlp_http.c をリンクしない (実測: .c に置くと undefined reference)。
 * POSIX のみ・nanopb 非依存。 */
static inline int otlp_env_kv_list(const char *envname, otlp_kv_t *out, int max) {
    const char *e = envname ? getenv(envname) : NULL;
    if (!e || !*e || !out || max <= 0) return 0;
    int n = 0;
    const char *p = e;
    while (*p && n < max) {
        while (*p == ',' || *p == ' ') p++;
        if (!*p) break;
        const char *comma = strchr(p, ',');
        const char *segend = comma ? comma : p + strlen(p);
        const char *eq = (const char *)memchr(p, '=', (size_t)(segend - p));
        if (eq) {
            /* [start,end) を空白トリムして固定幅にコピー */
            const char *ks = p, *ke = eq, *vs = eq + 1, *ve = segend;
            while (ks < ke && (*ks == ' ' || *ks == '\t')) ks++;
            while (ke > ks && (ke[-1] == ' ' || ke[-1] == '\t')) ke--;
            while (vs < ve && (*vs == ' ' || *vs == '\t')) vs++;
            while (ve > vs && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
            size_t kn = (size_t)(ke - ks), vn = (size_t)(ve - vs);
            if (kn >= sizeof out[n].key) kn = sizeof out[n].key - 1;
            if (vn >= sizeof out[n].val) vn = sizeof out[n].val - 1;
            memcpy(out[n].key, ks, kn); out[n].key[kn] = '\0';
            memcpy(out[n].val, vs, vn); out[n].val[vn] = '\0';
            if (out[n].key[0]) n++;
        }
        p = comma ? comma + 1 : segend;
    }
    return n;
}

/* OTEL_EXPORTER_OTLP_HEADERS ("k1=v1,k2=v2") をパースして out[] に格納、件数を返す。
 * Splunk の X-SF-Token / Bearer 等の認証ヘッダを直送時に付けるため。 */
int otlp_env_headers(otlp_kv_t *out, int max);

/* E402 (D3): OTEL_RESOURCE_ATTRIBUTES ("k1=v1,k2=v2") — OTel 標準の「この生産者を
 * ラベル付けする」env。E402 以前は未対応 (OTEL_SERVICE_NAME のみ) で、これが
 * Tetragon の `tags` に相当する穴だった。**独自の tags 語彙を作らずに標準の口を
 * 開ける**判断の実体 (E402 D3):
 *   - resource 属性 = ResourceSpans ごとに 1 回 (span ごとでない、E308)
 *   - **probe を走らせた人**の主張。作者のコメント (`# @intent`) を wire に昇格
 *     させると、その場にいない人の未検証の主張が検索可能な証拠になる (E402 D2)
 *   - collector / SIEM / SaaS が既に知っている key
 * 上限は resource 属性 16 個 (実運用のラベル数を超える。溢れは黙って捨てる:
 * これは診断ではなく操作者の宣言で、途中で送信を止める理由にはならない)。 */
#define OTLP_ENV_RESOURCE_ATTRS_MAX 16

/* OTEL_EXPORTER_OTLP_COMPRESSION=gzip のとき in を gzip 圧縮して out に書き、1 を返す。
 * 無効/失敗時は 0 (呼び出し側は非圧縮で送る)。 */
int otlp_gzip_if_enabled(const uint8_t *in, size_t inlen,
                         uint8_t *out, size_t outcap, size_t *outlen);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_HTTP_H */
