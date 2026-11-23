/*
 * otlp_endpoint_test.c — E290: endpoint URL の path 抽出 + scheme 別 default port。
 *
 * per-signal endpoint (OTEL_EXPORTER_OTLP_<SIGNAL>_ENDPOINT) を verbatim で使うため、
 * otlp_http_endpoint_path が path を保持すること、および https:// が 443 を既定にする
 * こと (Splunk 等 SaaS ingest) を検証する。ネットワーク不要のピュア parse test。
 *
 * 使い方: otlp_endpoint_test  (引数なし。全 assert 成功で "PASS" + exit 0)
 */
#include <stdio.h>
#include <string.h>
#include "otlp_http.h"

static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

static void expect_path(const char *ep, const char *want) {
    char path[256];
    int rc = otlp_http_endpoint_path(ep, path, sizeof path);
    CHECK(rc == 0, ep);
    if (rc == 0 && strcmp(path, want) != 0) {
        printf("FAIL: path(%s) = [%s], want [%s]\n", ep, path, want);
        fails++;
    }
}

static void expect_hostport(const char *ep, const char *whost, const char *wport) {
    char host[256], port[16];
    int rc = otlp_http_parse_endpoint(ep, host, sizeof host, port, sizeof port);
    CHECK(rc == 0, ep);
    if (rc == 0 && (strcmp(host, whost) != 0 || strcmp(port, wport) != 0)) {
        printf("FAIL: parse(%s) = %s:%s, want %s:%s\n", ep, host, port, whost, wport);
        fails++;
    }
}

int main(void) {
    /* --- path 抽出 (per-signal endpoint を verbatim で使うため) --- */
    expect_path("https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp",
                "/v2/trace/otlp");
    expect_path("http://127.0.0.1:4318/v1/traces", "/v1/traces");
    expect_path("https://host", "");                 /* path 無し -> 空 */
    expect_path("https://host:8443/", "/");           /* root だけ */
    expect_path("grpc://collector:4317/some/path", "/some/path");

    /* --- scheme 別 default port --- */
    expect_hostport("https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp",
                    "ingest.jp0.observability.splunkcloud.com", "443");  /* E290: https -> 443 */
    expect_hostport("http://127.0.0.1/v1/traces", "127.0.0.1", "4318");  /* plain http は従来どおり 4318 */
    expect_hostport("https://host:9443/x", "host", "9443");              /* 明示 port 優先 */
    expect_hostport("grpc://c", "c", "4317");
    expect_hostport("grpcs://c", "c", "4317");

    if (fails == 0) { printf("PASS (otlp_endpoint_test)\n"); return 0; }
    printf("%d checks FAILED\n", fails);
    return 1;
}
