#!/bin/sh
#
# tools/doom/verify-sources.sh — check the imported DOOM sources against
# tests/doom/manifest.tsv.
#
#   tools/doom/verify-sources.sh
#
# Everything it reads is inside this checkout.  It takes no source path, has no
# fallback to any other repository, and cannot be pointed at one: the imported
# files are tracked here, and a build or test that reached outside the checkout
# for them would make the predecessor a build dependency, which AGENTS.md and
# decision 0006 both forbid.
#
# The check is a bijection, not a spot check:
#   - every file the manifest names exists, at its recorded byte length and
#     local SHA-256;
#   - every file under the imported directories is named by the manifest.
# Either direction failing is a failure.
#
# The manifest's ORIGINAL columns are not consulted here.  Re-deriving those
# needs the source revision, which lives in another repository, so it is an
# audit rather than part of any build: tools/doom/audit-origin.sh.
set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/sha256.sh"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFEST="$ROOT/tests/doom/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "verify-sources: no manifest at $MANIFEST" >&2; exit 1; }

n=0; mod=0; loc=0
while IFS='	' read -r kind opath obytes osha lpath lbytes lsha modified; do
  case "$kind" in ''|\#*) continue ;; esac
  f="$ROOT/$lpath"
  [ -f "$f" ] || { echo "verify-sources: $lpath is missing" >&2; exit 1; }
  got_b=$(wc -c < "$f" | tr -d ' \t')
  got_s=$(sp_sha256 "$f")
  [ "$got_b" = "$lbytes" ] || { echo "verify-sources: $lpath is $got_b bytes, manifest says $lbytes" >&2; exit 1; }
  [ "$got_s" = "$lsha" ]   || { echo "verify-sources: $lpath has sha256 $got_s, manifest says $lsha" >&2; exit 1; }
  # A file written here rather than imported has no original to compare against.
  # It is still digest-checked above; only the original-vs-local consistency is
  # skipped, and the row must say so rather than carrying a stale "no".
  if [ "$kind" = local ]; then
    loc=$((loc + 1))
    if [ "$modified" != "n/a" ] || [ "$osha" != "-" ]; then
      echo "verify-sources: $lpath is kind=local but its original columns are not '-'/'n/a'" >&2
      exit 1
    fi
    continue
  fi

  # A file recorded as unchanged must still equal its original digest; one
  # recorded as changed must still differ.  Both directions are checked so the
  # "modified" column cannot quietly go stale.
  if [ "$modified" = no ] && [ "$osha" != "$lsha" ]; then
    echo "verify-sources: $lpath is recorded as unmodified but its digest differs from the original" >&2; exit 1
  fi
  if [ "$modified" = yes ]; then
    mod=$((mod + 1))
    if [ "$osha" = "$lsha" ]; then
      echo "verify-sources: $lpath is recorded as modified but equals the original" >&2; exit 1
    fi
  fi
  n=$((n + 1))
done < "$MANIFEST"

[ "$n" -gt 0 ] || { echo "verify-sources: the manifest named no files" >&2; exit 1; }

declared=$(mktemp); actual=$(mktemp)
trap 'rm -f "$declared" "$actual"' EXIT INT TERM
awk -F'\t' '!/^#/ && NF>=8 { print $5 }' "$MANIFEST" | sort > "$declared"
# Every directory the manifest can name, so the surjective half stays honest as
# the import grows.  A new imported file in a directory not listed here would
# pass the per-file check and never be tested for being declared.  A LICENSE
# is the licence text beside the files, not one of them; docs/imports.tsv and
# tools/provenance/check-imports.rb cover it.
( cd "$ROOT" && find examples/doom/lib examples/doom/bin examples/doom/native \
    tests/doom/cases tests/doom/fixtures/scripts tests/doom/fixtures/allowances \
    tests/doom/native tests/doom/cases-aux tools/doom -type f -not -name README.md -not -name LICENSE -not -name "*.sh" 2>/dev/null ) | sort > "$actual"
if ! cmp -s "$declared" "$actual"; then
  echo "verify-sources: the imported tree does not match the manifest:" >&2
  diff -u "$declared" "$actual" >&2 || true
  exit 1
fi

echo "verify-sources: $n files verified ($mod changed on import, $loc written here), digests by $(sp_sha256_tool)"
