#!/bin/sh
#
# tools/doom/fetch-iwad.sh — fetch the Doom shareware IWAD with verified
# length and SHA-256, and publish it only after both match.
#
#   tools/doom/fetch-iwad.sh [DESTDIR]    # default: build/doom-wad
#
# The IWAD is **never committed** (decision 0006 keeps the repository free of
# game data).  What lives here is the URL set and the digest; the bytes always
# stay in an untracked directory.  doom1.wad is the Doom shareware 1.9 IWAD,
# which id Software permits to be redistributed.
#
# Adapted from the predecessor's doom/tools/fetch_wad.sh (read-only source) with
# three changes: the digest is taken through tools/doom/sha256.sh, which picks a
# working SHA-256 tool rather than assuming one platform's packaging; an *owned*
# temporary file created by mktemp rather than a fixed ".part" name; and a length
# check before the digest so a truncated or error-page body is named as such
# instead of only as a digest mismatch.
set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/sha256.sh"

DEST="${1:-build/doom-wad}"

# Several mirrors, tried in order; the first whose bytes match *both* the length
# and the digest wins.  A single URL cannot distinguish "the gate failed" from
# "the gate could not be run" when the host 404s, which is what happened to the
# predecessor's E068.  A mirror may only be added here if it serves these exact
# bytes -- the verification below always runs, for every mirror and again at the
# end for an already-present file.
WAD_URLS="
https://cdn.jsdelivr.net/gh/Akbar30Bill/DOOM_wads@master/doom1.wad
https://raw.githubusercontent.com/Akbar30Bill/DOOM_wads/master/doom1.wad
https://github.com/Akbar30Bill/DOOM_wads/raw/master/doom1.wad
"
WAD_SHA256="1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
WAD_BYTES=4196020

digest() { sp_sha256 "$1"; }
length() { wc -c < "$1" | tr -d ' \t'; }

mkdir -p "$DEST"
WAD="$DEST/doom1.wad"

if [ ! -f "$WAD" ]; then
  tmp=$(mktemp "$DEST/.doom1.wad.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT INT TERM
  got=""
  for u in $WAD_URLS; do
    if ! curl -fsSL --max-time 300 -o "$tmp" "$u"; then
      echo "fetch-iwad: $u: transfer failed" >&2
      continue
    fi
    n=$(length "$tmp")
    if [ "$n" != "$WAD_BYTES" ]; then
      echo "fetch-iwad: $u: served $n bytes, want $WAD_BYTES -- trying the next mirror" >&2
      continue
    fi
    s=$(digest "$tmp")
    if [ "$s" != "$WAD_SHA256" ]; then
      echo "fetch-iwad: $u: sha256 $s is not the shareware 1.9 IWAD -- trying the next mirror" >&2
      continue
    fi
    # Publish only now, once both the length and the digest have matched.
    mv "$tmp" "$WAD"
    got="$u"
    break
  done
  trap - EXIT INT TERM
  rm -f "$tmp"
  if [ -z "$got" ]; then
    echo "fetch-iwad: no mirror served the shareware IWAD; place doom1.wad in $DEST by hand" >&2
    exit 1
  fi
fi

# Re-verify unconditionally, including the already-present case: the file may
# have been placed by hand, or truncated since.
got_sha=$(digest "$WAD")
got_len=$(length "$WAD")
[ "$got_len" = "$WAD_BYTES" ] || { echo "fetch-iwad: $WAD is $got_len bytes, want $WAD_BYTES" >&2; exit 1; }
[ "$got_sha" = "$WAD_SHA256" ] || { echo "fetch-iwad: $WAD has sha256 $got_sha, want $WAD_SHA256" >&2; exit 1; }

echo "$WAD  sha256=$got_sha  bytes=$got_len  (Doom shareware 1.9)"
