#!/usr/bin/env bash
#
# build-mbedtls.sh — vendored mbedTLS の static lib をビルド (ADR-013 T0)
#
# libmbedtls.a / libmbedx509.a / libmbedcrypto.a を third_party/mbedtls/library/ に生成する。
# 生成物はプラットフォーム固有 (host=macOS / container=linux) なので各環境で実行する (commit しない)。
# pin: mbedTLS v3.6.6 (LTS、生成ファイル同梱タグ → framework での生成は不要)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Spinel Extended: MBEDTLS_DIR names a user-local mbedTLS v3.6.6 checkout.
MBED="${MBEDTLS_DIR:-$REPO_ROOT/third_party/mbedtls}"
if [ ! -f "$MBED/Makefile" ]; then
  echo "error: the mbedtls submodule is not fetched. Run:" >&2
  echo "       git submodule update --init --recursive third_party/mbedtls" >&2
  exit 1
fi

# host(macOS) と container(linux) が同一 /work を共有するため、arch が変わったら clean して
# 再ビルドする (前回の他 arch の .o/.a を踏まない)。同一 arch の再実行は incremental で速い。
ARCH="$(uname -s)-$(uname -m)"
mkdir -p "$REPO_ROOT/build"
STAMP="$REPO_ROOT/build/.mbedtls_arch"   # submodule 外 (build/ は gitignore 済)
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$ARCH" ]; then
  echo "[build-mbedtls] arch changed ($(cat "$STAMP") -> $ARCH): make clean"
  make -C "$MBED" clean >/dev/null 2>&1 || true
fi

J="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo "[build-mbedtls] building the static lib for $ARCH (v3.6.6, -j$J)"
make -C "$MBED" lib -j"$J" CFLAGS="-O2"
echo "$ARCH" > "$STAMP"
echo "[build-mbedtls] done:"
ls -1 "$MBED/library"/libmbed*.a
