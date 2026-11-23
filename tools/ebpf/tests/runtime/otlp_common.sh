#!/usr/bin/env bash
# otlp_common.sh — run_otlp_*.sh 共通ヘルパ (E263 G5)。`. otlp_common.sh` で source する。
# 呼び出し側は PROTOC (既定 protoc) と PROTO_ROOT (otel-proto のルート) を設定しておく。

OTLP_FAIL=0

# otlp_decode <message-fqn> <proto-rel-path> <in-bytes> <out-text>
otlp_decode() {
  "${PROTOC:-protoc}" --decode="$1" -I "$PROTO_ROOT" "$2" < "$3" > "$4"
}

# otlp_assert <file> <needle>    — needle が含まれれば ok、なければ FAIL マーク
otlp_assert() {
  if grep -qF "$2" "$1"; then echo "  ok: $2"; else echo "  MISSING: $2"; OTLP_FAIL=1; fi
}

# otlp_count <file> <needle> <n> — needle の出現回数が n か
otlp_count() {
  c=$(grep -cF "$2" "$1")
  if [ "$c" = "$3" ]; then echo "  ok: $2 x$3"; else echo "  WRONG COUNT $2 = $c (want $3)"; OTLP_FAIL=1; fi
}

# otlp_done <label> — どれか失敗していれば exit 1
otlp_done() {
  if [ "$OTLP_FAIL" -ne 0 ]; then echo "FAIL: $1"; exit 1; fi
  echo "PASS: $1"
}
