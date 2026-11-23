# tools/doom/sha256.sh — a SHA-256 helper that works on Debian and macOS.
#
# Source it, then call `sp_sha256 <file>`; it echoes 64 lowercase hex digits.
#
#   . "$(dirname "$0")/sha256.sh"
#   d=$(sp_sha256 "$f")
#
# There is no one command for this across the platforms this project targets.
# Debian ships `sha256sum` (coreutils) and has no `shasum` guarantee; macOS
# ships `shasum` (Perl) and has no `sha256sum` unless Homebrew coreutils is
# installed.  Relying on either alone makes an undeclared dependency on one
# platform's packaging, which is how the Mac side came to run this recipe only
# because Homebrew happened to provide `sha256sum`.
#
# So the tool is chosen at first use from: SP_SHA256_CMD if the caller sets one,
# then sha256sum, shasum, openssl.  The choice is then VERIFIED against a known
# vector before it is used for anything -- the empty input must digest to
# e3b0c442...b855.  A tool that is present but answers in an unexpected format,
# or is a wrapper that prints something else, is rejected at selection rather
# than silently producing digests that never match.
#
# Input is fed on stdin, not named on the command line, so no filename appears
# in the output to be parsed around.
#
# If nothing usable is found the caller is told what to install, and the script
# fails.  It never falls back to skipping the check.

SP_SHA256_TOOL=""

sp_sha256_raw() {   # $1 = tool, stdin = data
  case "$1" in
    sha256sum) sha256sum        | cut -d' ' -f1 ;;
    shasum)    shasum -a 256    | cut -d' ' -f1 ;;
    openssl)   openssl dgst -sha256 | awk '{print $NF}' ;;
    *)         return 127 ;;
  esac
}

sp_sha256_select() {
  [ -n "$SP_SHA256_TOOL" ] && return 0
  empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  tried=""
  for t in ${SP_SHA256_CMD:-} sha256sum shasum openssl; do
    command -v "$t" >/dev/null 2>&1 || { tried="$tried $t(absent)"; continue; }
    got=$(printf '' | sp_sha256_raw "$t" 2>/dev/null) || { tried="$tried $t(failed)"; continue; }
    if [ "$got" = "$empty" ]; then
      SP_SHA256_TOOL="$t"
      return 0
    fi
    tried="$tried $t(wrong output: '$got')"
  done
  echo "sha256: no usable SHA-256 tool.  Tried:$tried" >&2
  echo "sha256: install coreutils (sha256sum), perl's shasum, or openssl," >&2
  echo "sha256: or set SP_SHA256_CMD to one of those names." >&2
  return 1
}

sp_sha256() {   # $1 = file
  sp_sha256_select || return 1
  sp_sha256_raw "$SP_SHA256_TOOL" < "$1"
}

# The name of the tool actually in use, for diagnostics.
sp_sha256_tool() { sp_sha256_select || return 1; echo "$SP_SHA256_TOOL"; }
