#!/bin/sh
# tests/contract/rewrites.sh -- the contract reader's two rewrites from the
# 2026-11-14 upstream synchronisation, and the shapes it must still refuse.
#
#   PrunedMethod  upstream blanks a def whose name no other node holds: every
#                 node of it is a NilNode in the nodes face.
#   ParenPeel     a desugar puts the one expression a pair of parentheses
#                 wraps in their place: the ParenthesesNode and its
#                 StatementsNode are NilNodes in the nodes face.
#
# Each accepted case first shows, through spinel-typedump, that the analysis
# really made the rewrite, so a pass is not the reader accepting a program it
# never had to recognise. The refusals feed spinel-fs-emit a wrapper typedump
# that edits one row of the nodes face into a near miss of each shape; every
# one must stay a kind-mismatch.
#
# Needs tools/contract/build.sh and tools/mlir/native/build.sh.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
TD=${TYPEDUMP:-$REPO/tools/contract/build/spinel-typedump}
FE=${SPINEL_CORE_BUILD:-$REPO/tools/mlir/native/build}/bin/spinel-fs-emit
PROF=$REPO/tools/freestanding/profiles/cortex-m33-zephyr.yaml
[ -x "$TD" ] || { echo "rewrites: no $TD (tools/contract/build.sh)" >&2; exit 2; }
[ -x "$FE" ] || { echo "rewrites: no $FE (tools/mlir/native/build.sh)" >&2; exit 2; }
unset SPINEL_KEEP_UNNAMED

W=$(mktemp -d "${TMPDIR:-/tmp}/contract-rewrites.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/spinel"
cp "$REPO/tools/freestanding/spinel/freestanding.rb" "$W/spinel/"

cat > "$W/prune.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  n + 1
end
def never_called(x)
  x * 2
end
EOF
# never_called is held by a Symbol in keep_ref, so upstream keeps it; keep_ref
# itself is named by nothing and is pruned.
cat > "$W/held.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  n + 1
end
def keep_ref
  :never_called
end
def never_called(x)
  x * 2
end
EOF
cat > "$W/paren.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  (n + 1) * 2
end
EOF
cat > "$W/paren2.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :i32
def go(n)
  (n; n + 1) * 2
end
EOF

# The wrapper: the real typedump, with the nodes face's rows named in EDIT
# ("id:kind id:kind ...") given that kind. spinel-fs-emit passes the source
# first and the face last. The source it passes is the kernel with the
# synthesized driver appended (the program the analysis sees); the wrapper
# keeps a copy beside the kernels, so the probes below read that program.
cat > "$W/td-edit" <<EOF
#!/bin/sh
cp "\$1" "$W/analysed.rb"
for a; do face=\$a; done
if [ "\$face" = nodes ] && [ -n "\${EDIT:-}" ]; then
  "$TD" "\$@" | awk -F'\t' -v OFS='\t' -v edit="\$EDIT" \\
    'BEGIN { n = split(edit, e, " "); for (i = 1; i <= n; i++) { split(e[i], p, ":"); k[p[1]] = p[2] } }
     NR > 1 && (\$1 in k) { \$2 = k[\$1] } { print }'
else
  exec "$TD" "\$@"
fi
EOF
chmod +x "$W/td-edit"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  pass $1"; }
ko() { fail=$((fail+1)); echo "  FAIL $1: $2"; }
emit() {  # file [typedump]
  (cd "$W" && "$FE" "$1" --freestanding --profile "$PROF" -o "$W/out.mlir" \
     --typedump "${2:-$TD}") > "$W/err" 2>&1
}
# the analysed program of kernel $1, as spinel-fs-emit hands it to typedump
analysed() { EDIT= emit "$1" "$W/td-edit" && cp "$W/analysed.rb" "$W/$1.analysed.rb"; }
nodes() { (cd "$W" && "$TD" "$1.analysed.rb" nodes); }
ast() { (cd "$W" && "$TD" "$1.analysed.rb" ast); }
# the id of the DefNode named $2 in $1's ast
def_id() { ast "$1" | awk -v name="$2" '$1 == "N" && $3 == "DefNode" { id = $2 } $1 == "S" && $2 == id && $3 == "name" && $4 == name { print id; exit }'; }
# the nodes-face kind of id $2 in $1
kind_of() { nodes "$1" | awk -F'\t' -v id="$2" '$1 == id { print $2 }'; }
# the first id of kind $2 in $1's ast at or after id $3
first_after() { ast "$1" | awk -v kind="$2" -v from="$3" '$1 == "N" && $3 == kind && $2 >= from { print $2; exit }'; }
accepted() {  # name file [typedump]
  if emit "$2" "${3:-}"; then ok "$1"; else ko "$1" "$(tail -1 "$W/err")"; fi
}
refused() {  # name file typedump-edit
  if EDIT=$3 emit "$2" "$W/td-edit"; then ko "$1" "accepted"
  elif grep -q 'kind-mismatch' "$W/err"; then ok "$1"
  else ko "$1" "refused, but not as kind-mismatch: $(tail -1 "$W/err")"; fi
}

echo "pruned method"
for k in prune.rb held.rb paren.rb paren2.rb; do analysed "$k" || { echo "rewrites: cannot read the analysed program of $k: $(tail -1 "$W/err")" >&2; exit 2; }; done
d=$(def_id prune.rb never_called)
if [ -n "$d" ] && [ "$(kind_of prune.rb "$d")" = NilNode ]; then ok "the analysis prunes never_called"
else ko "the analysis prunes never_called" "its DefNode $d is $(kind_of prune.rb "$d")"; fi
accepted "a pruned method is read" prune.rb
accepted "the wrapper unedited reads the same" prune.rb "$W/td-edit"
i=$(first_after prune.rb IntegerNode "$d")
refused "a def only partly NilNode" prune.rb "$i:IntegerNode"
h=$(def_id held.rb never_called)
if [ "$(kind_of held.rb "$h")" = DefNode ]; then ok "a def whose name a Symbol holds is kept"
else ko "a def whose name a Symbol holds is kept" "its DefNode $h is $(kind_of held.rb "$h")"; fi
accepted "the other, unnamed, def is pruned and read" held.rb
sub="$h:NilNode $(nodes held.rb | awk -F"\t" '$5 == "never_called" { printf "%s:NilNode ", $1 }')"
refused "a def blanked while a Symbol holds its name" held.rb "$sub"

echo "peeled parentheses"
p=$(first_after paren.rb ParenthesesNode 0)
if [ -n "$p" ] && [ "$(kind_of paren.rb "$p")" = NilNode ]; then ok "the analysis peels the parentheses"
else ko "the analysis peels the parentheses" "ParenthesesNode $p is $(kind_of paren.rb "$p")"; fi
accepted "peeled parentheses are read" paren.rb
refused "parentheses turned into another kind" paren.rb "$p:IntegerNode"
p2=$(first_after paren2.rb ParenthesesNode 0)
if [ "$(kind_of paren2.rb "$p2")" = ParenthesesNode ]; then ok "two statements in parentheses are not peeled"
else ko "two statements in parentheses are not peeled" "ParenthesesNode $p2 is $(kind_of paren2.rb "$p2")"; fi
refused "parentheses of two statements blanked" paren2.rb "$p2:NilNode $((p2 + 1)):NilNode"

echo "contract-rewrites: $pass pass, $fail fail"
[ "$fail" = 0 ]
