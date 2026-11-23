/*
 * otlp_audit_span_test.c — E292: 監査 span (spnl_otlp_audit_file_span) の wire 検証。
 * deny の監査を span 化して endpoint に送り、mock receiver + protoc で属性を復元する:
 *   span 名 "file_open /etc/shadow"、kind=INTERNAL、
 *   process.executable.path / process.parent.executable.path / file.path / verdict、
 *   deny=1 -> Span.status=STATUS_CODE_ERROR。
 * 使い方: otlp_audit_span_test <endpoint>   (mock receiver が decode を assert)
 */
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include "otlp_httpspan.h"

int main(int argc, char **argv) {
    const char *endpoint = (argc > 1) ? argv[1] : "http://127.0.0.1:4318";
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    uint64_t t0 = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;

    int st = spnl_otlp_audit_file_span(
        "" /* new trace */,
        "/bin/cat", "/usr/sbin/nginx", "/etc/shadow", "deny", 1 /* deny */,
        t0, t0 + 8000000ull, endpoint);

    printf("audit span HTTP status = %d\n", st);
    return (st == 200) ? 0 : 1;
}
