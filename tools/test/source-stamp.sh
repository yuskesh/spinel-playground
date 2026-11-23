# tools/test/source-stamp.sh — a lane's kernel and reader, held to its tree.
#
# Sourced by every lane that takes a kernel (or a tool of the native build
# beside it) or a reader, after it resolves them. Each binary must carry the
# source stamp its build script wrote beside it, and the stamp must be this
# tree's source (tools/test/source-stamp.rb): a copied binary built before the
# source changed is refused before the lane uses it, naming the inputs that
# differ. A binary that is absent is left to the lane's own skip or refusal.
# tools/core/spinel-core-build does not check (it needs no Ruby); the lanes
# that call it do. Needs ROOT (or root); RUBY defaults to ruby.
source_stamp() { # kernel|reader PATH
  [ -f "$2" ] || return 0
  "${RUBY:-ruby}" "${ROOT:-${root:?ROOT or root names the tree}}/tools/test/source-stamp.rb" check "$1" "$2" || exit 1
}
