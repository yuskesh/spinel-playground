# scripts/lib/bml-submodule.sh — E167: bml (third_party/bpf-mlir-loader) の submodule の取得 (setup.sh・clone-check.sh・tutorial-run.sh が source する)。
# dev の .gitmodules の bml の URL は file:// (利用者の決定 2026-09-27 — remote を作らない) で git の既定は file の protocol を submodule で拒否する。
# protocol.file.allow=always はその URL が file:// の時だけ付ける (公開の形の .gitmodules は https — P170 §3.3 — で要らない)。

# bml_file_allow <URL> は git の前に置く引数を 1 行に 1 つ出す (file:// の時だけ `-c` と `protocol.file.allow=always`)。
bml_file_allow() {
  case "${1:-}" in
    file://*) printf '%s\n' -c protocol.file.allow=always ;;
  esac
}

# bml_submodule_update <repo> [submodule update の引数…] は repo の .gitmodules の bml の URL を読み、bml の submodule を取る。
bml_submodule_update() {
  local repo=$1 url
  shift
  url=$(git -C "$repo" config -f .gitmodules submodule.third_party/bpf-mlir-loader.url) || { echo "bml_submodule_update: $repo/.gitmodules has no URL for third_party/bpf-mlir-loader" >&2; return 2; }
  local -a c
  mapfile -t c < <(bml_file_allow "$url")
  git -C "$repo" "${c[@]}" submodule update "$@" third_party/bpf-mlir-loader
}
