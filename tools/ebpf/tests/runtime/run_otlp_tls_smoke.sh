#!/usr/bin/env bash
#
# run_otlp_tls_smoke.sh — ADR-013 T0: vendored mbedTLS のビルド + TLS クライアント handshake 検証。
#   1) 検証ON + 自己署名 CA (OTEL_EXPORTER_OTLP_CERTIFICATE) -> handshake 成功
#   2) INSECURE_SKIP_VERIFY=1                                  -> handshake 成功
#   3) 検証ON + CA 無し (system CA は自己署名を信頼しない)     -> handshake 失敗 (検証が効いている証拠)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
RUBY="${RUBY:-ruby}"
MBED="${MBEDTLS_DIR:-$REPO_ROOT/third_party/mbedtls}"   # Spinel Extended: MBEDTLS_DIR, as scripts/build-mbedtls.sh
OTLP="$REPO_ROOT/src/runtime/otlp"
PORT="${OTLP_TLS_PORT:-18443}"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# mbedTLS static lib をビルド (arch スタンプで host/container 間の取り違えを回避)
sh "$REPO_ROOT/scripts/build-mbedtls.sh" >/dev/null

echo "[t0] generating self-signed cert (CN=localhost)"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1
cat "$TMP/cert.pem" "$TMP/key.pem" > "$TMP/srv.pem"

echo "[t0] compiling otlp_tls smoke (link mbedTLS .a)"
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$OTLP" -I "$MBED/include" \
  tests/runtime/otlp_tls_smoke.c "$OTLP/otlp_tls.c" \
  "$MBED/library/libmbedtls.a" "$MBED/library/libmbedx509.a" "$MBED/library/libmbedcrypto.a" \
  -o "$TMP/tls_smoke"

echo "[t0] starting HTTPS mock"
setsid "$RUBY" tests/runtime/mock_tls_server.rb "$PORT" "$TMP/srv.pem" >/tmp/.tls_mock.log 2>&1 &
SRV=$!
# readiness: client は connect しないので少し待つ代わりにポート確認 (sleep 無し)
"$RUBY" -rsocket -e '100.times { begin; Socket.tcp("127.0.0.1", Integer(ARGV[0]), connect_timeout: 0.1).close; exit 0; rescue SystemCallError; sleep 0.1; end }' "$PORT" || true

fail=0
echo "[t0] (1) verify ON + self-signed CA -> expect OK"
if OTEL_EXPORTER_OTLP_CERTIFICATE="$TMP/cert.pem" "$TMP/tls_smoke" localhost "$PORT"; then echo "  ok"; else echo "  FAIL"; fail=1; fi

echo "[t0] (2) INSECURE_SKIP_VERIFY=1 -> expect OK"
if OTEL_EXPORTER_OTLP_INSECURE_SKIP_VERIFY=1 "$TMP/tls_smoke" localhost "$PORT"; then echo "  ok"; else echo "  FAIL"; fail=1; fi

echo "[t0] (3) verify ON + system CA のみ (自己署名は非信頼) -> expect REJECT"
if "$TMP/tls_smoke" localhost "$PORT" 2>/dev/null; then
  # system CA は自己署名 cert を信頼しない -> handshake は検証で失敗するはず
  echo "  FAIL: should have rejected self-signed under system CA"; fail=1
else
  echo "  ok (rejected as expected — 検証が効いている)"
fi

[ "$fail" -eq 0 ] && echo "[t0] PASS: mbedTLS build + TLS client handshake & verify" || { echo "[t0] FAIL"; exit 1; }
