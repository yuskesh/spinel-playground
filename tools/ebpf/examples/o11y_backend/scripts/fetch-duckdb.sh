#!/bin/sh
# libduckdb (C API, linux arm64) を vendor/duckdb/ に取得する。container 内で実行する。
# 版は DUCKDB_VERSION で pin、無指定なら GitHub releases の latest を解決して VERSION に記録。
set -e
base="$(cd "$(dirname "$0")/.." && pwd)"
dir="$base/vendor/duckdb"
mkdir -p "$dir"
cd "$dir"

ver="${DUCKDB_VERSION:-}"
if [ -z "$ver" ]; then
  ver=$(curl -fsSL https://api.github.com/repos/duckdb/duckdb/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)
fi
[ -n "$ver" ] || { echo "fetch-duckdb: could not resolve latest release tag; set DUCKDB_VERSION=vX.Y.Z" >&2; exit 1; }

# asset 名は release 世代で libduckdb-linux-arm64 / -aarch64 の両方があるので順に試す
for asset in libduckdb-linux-arm64.zip libduckdb-linux-aarch64.zip; do
  if curl -fsSL -o libduckdb.zip "https://github.com/duckdb/duckdb/releases/download/$ver/$asset"; then
    got="$asset"; break
  fi
done
[ -n "${got:-}" ] || { echo "fetch-duckdb: no arm64 asset found for $ver" >&2; exit 1; }

unzip -o -q libduckdb.zip
rm -f libduckdb.zip
echo "$ver" > VERSION
echo "fetched libduckdb $ver ($got) -> $dir"
ls -l "$dir"
