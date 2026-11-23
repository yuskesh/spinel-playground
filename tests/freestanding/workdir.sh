# tests/freestanding/workdir.sh -- sourced by the scripts that rebuild a work
# directory from scratch before each run.
#
# fs_fresh_workdir DIR empties DIR only if this helper created it: on creation
# it leaves the marker file below, and it refuses to remove a directory that
# lacks it. The work directory is never read from the environment; a name such
# as W exported by a caller once made a script delete a checkout.
FS_WORKDIR_MARK=.spinel-freestanding-workdir

fs_fresh_workdir() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    if [ -L "$1" ] || [ ! -d "$1" ] || [ ! -f "$1/$FS_WORKDIR_MARK" ]; then
      echo "$0: refusing to remove $1: it has no $FS_WORKDIR_MARK, so this script did not create it" >&2
      exit 2
    fi
    rm -rf "$1" || exit 2
  fi
  mkdir -p "$1" && : > "$1/$FS_WORKDIR_MARK" || exit 2
}
