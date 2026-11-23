# tests/freestanding/stamps.sh -- sourced by lane-env.sh (every lane) and by
# run.sh (once, before any lane): the lanes' native tools and reader, held to
# this tree.
#
# It resolves the tools as the lanes do -- SPINEL_CORE_BUILD, MLIRGEN,
# FSCHECK and FSGRAD may name others -- and fs_stamps checks the source
# stamp of each that exists (tools/test/source-stamp.rb), and of the reader
# spinel-fs-emit finds by default, tools/contract/build/spinel-typedump. A
# tool built from other source than this tree's is refused, naming the
# tool and the inputs that differ: an override is used only when its stamp
# matches. A tool that is absent is left to the lane's own refusal. Needs
# REPO.
BIN=${SPINEL_CORE_BUILD:-$REPO/tools/mlir/native/build}/bin
MLIRGEN=${MLIRGEN:-$BIN/spinel-fs-emit}
FSCHECK=${FSCHECK:-$BIN/spinel-fs-check}
FSGRAD=${FSGRAD:-$BIN/spinel-fs-grad}
fs_stamps() {
  for _t in "$MLIRGEN" "$FSCHECK" "$FSGRAD"; do
    [ -f "$_t" ] || continue
    "${RUBY:-ruby}" "$REPO/tools/test/source-stamp.rb" check kernel "$_t" > /dev/null || return 1
  done
  _r=$REPO/tools/contract/build/spinel-typedump
  [ -f "$_r" ] || return 0
  "${RUBY:-ruby}" "$REPO/tools/test/source-stamp.rb" check reader "$_r" > /dev/null || return 1
}
