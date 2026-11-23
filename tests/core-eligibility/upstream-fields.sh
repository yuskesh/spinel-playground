#!/bin/sh
# tests/core-eligibility/upstream-fields.sh -- what the CORE checker reads of
# the analysis written by upstream Spinel since the 2026-11-14 synchronisation,
# and the near misses it must still refuse.
#
#   DefNode.locals        Prism's local table of a def. Known only when its
#                         names are the method's leading slots in the locals
#                         face, in slot order.
#   ignore_visibility     Prism's flag on a call that may reach a private
#                         method. Known only on a call with no receiver or a
#                         literal `self`.
#   block slot names      the slot a block parameter lives in is read from the
#                         nodes face (the parameter node's name there), not
#                         spelled by the checker.
#   --keep-method         the kernel names its entry to the reader, so the
#                         analysis keeps it although nothing in the program
#                         calls it.
#
# Each refusal edits one line of one face through a wrapper reader, from a
# program the unedited wrapper compiles, and must name what it edited.
#
# Needs tools/contract/build.sh and tools/mlir/native/build.sh, and
# LLVM_PREFIX (or CLANG) for the kernel's clang.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
KERNEL=$BIN/spinel-core-kernel
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
die() { echo "upstream-fields: $*" >&2; exit 2; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (tools/mlir/native/build.sh)"
[ -x "$READER" ] || die "no reader at $READER (tools/contract/build.sh)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"

T=$(mktemp -d "${TMPDIR:-/tmp}/upstream-fields.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/src"
# k.rb: pick's block parameter `i` gets a slot of its own (other also has an
# `i`), twice's `x + x` is a call with a receiver, `twice(b)` one without
# (which Prism flags). Upstream leaves its prune of unnamed methods off for a
# program with a block, so the prune is shown on plain.rb instead, whose pick
# nothing calls.
cat > "$T/src/k.rb" <<'EOF'
def twice(x)
  x + x
end

def other(i)
  i
end

def pick(a, b)
  s = 0
  a.times { |i| s += i }
  s + twice(b) + other(a)
end

twice(1)
EOF
cat > "$T/src/plain.rb" <<'EOF'
def pick(a, b)
  a + b
end

def other(i)
  i
end
EOF
contract() { # source, contract
  printf 'core-contract 1\nroot src/%s\nentry pick\nresult i64\nparam a scalar i64\nparam b scalar i64\n' "$1" > "$2"
}
contract k.rb "$T/k.contract"
contract plain.rb "$T/plain.contract"

# The wrapper: the real reader, with face $FACE's lines run through the sed
# expression $SED, and with every --keep-method dropped when $DROP_KEEP is
# set. The kernel passes the mode last.
cat > "$T/reader" <<EOF
#!/bin/sh
for a; do mode=\$a; done
if [ -n "\${DROP_KEEP:-}" ]; then
  for a; do shift; case \$a in --keep-method=*) ;; *) set -- "\$@" "\$a" ;; esac; done
fi
if [ "\$mode" = "\${FACE:-}" ]; then
  "$READER" "\$@" | sed "\$SED"
else
  exec "$READER" "\$@"
fi
EOF
chmod +x "$T/reader"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
kernel() { # contract, reader; prints the exit status, stderr in $T/err
  rm -f "$T/k.o"
  (cd "$T" && "$KERNEL" "$1" --root "$T" --typedump "$2" -o "$T/k.o" \
     --header "$T/k.h" --clang "$CC_BIN") > "$T/err" 2>&1
  echo $?
}
# 1 when stderr says it, else 0
said() { if grep -q -- "$1" "$T/err"; then echo 1; else echo 0; fi; }
face() { (cd "$T/src" && "$READER" "$1" --keep-method=pick "$2"); }

echo "upstream-fields: controls"
ok "the program compiles" "$(kernel "$T/k.contract" "$READER")" 0
ok "the unedited wrapper compiles it too" "$(kernel "$T/k.contract" "$T/reader")" 0
face k.rb ast > "$T/ast"
def=$(awk '$1 == "S" && $3 == "name" && $4 == "pick" { print $2; exit }' "$T/ast")
ok "the analysis writes pick's locals" \
   "$(awk -v d="$def" '$1 == "S" && $2 == d && $3 == "locals" { print $4; exit }' "$T/ast")" "a,b,s"

echo "upstream-fields: --keep-method"
pd=$(face plain.rb ast | awk '$1 == "S" && $3 == "name" && $4 == "pick" { print $2; exit }')
ok "without it the analysis prunes plain.rb's pick" \
   "$(cd "$T/src" && "$READER" plain.rb nodes | awk -F'\t' -v d="$pd" '$1 == d { print $2 }')" NilNode
ok "with it, pick is kept" "$(face plain.rb nodes | awk -F'\t' -v d="$pd" '$1 == d { print $2 }')" DefNode
ok "the kernel compiles plain.rb's pick" "$(kernel "$T/plain.contract" "$T/reader")" 0
ok "a reader that drops --keep-method leaves the entry pruned, refused" \
   "$(DROP_KEEP=1 kernel "$T/plain.contract" "$T/reader")|$(said 'nothing in the program names')" "1|1"

echo "upstream-fields: DefNode.locals"
ok "a list in another order is refused" \
  "$(FACE=ast SED="s/^S $def locals a,b,s\$/S $def locals a,s,b/" kernel "$T/k.contract" "$T/reader")|$(said 'unsupported-field: DefNode.locals')" "1|1"
ok "a list with a name the face lacks is refused" \
  "$(FACE=ast SED="s/^S $def locals a,b,s\$/S $def locals a,b,s,zz/" kernel "$T/k.contract" "$T/reader")|$(said 'unsupported-field: DefNode.locals')" "1|1"

echo "upstream-fields: ignore_visibility"
callnamed() { awk -v n="$1" '$1 == "N" && $3 == "CallNode" { id = $2 } $1 == "S" && $2 == id && $3 == "name" && $4 == n { print id; exit }' "$T/ast"; }
plus=$(callnamed +)
twice=$(callnamed twice)
ok "the analysis flags the receiverless call" \
   "$(awk -v c="$twice" '$1 == "I" && $2 == c && $3 == "ignore_visibility" { print $4 }' "$T/ast")" 1
ok "the analysis does not flag x + x" \
   "$(awk -v c="$plus" '$1 == "I" && $2 == c && $3 == "ignore_visibility"' "$T/ast" | wc -l | tr -d ' ')" 0
ok "the flag on a call with a receiver is refused" \
  "$(FACE=ast SED="/^N $plus CallNode\$/a I $plus ignore_visibility 1" kernel "$T/k.contract" "$T/reader")|$(said 'unsupported-field: CallNode.ignore_visibility')" "1|1"
ok "a flag other than 1 is refused" \
  "$(FACE=ast SED="s/^I $twice ignore_visibility 1\$/I $twice ignore_visibility 2/" kernel "$T/k.contract" "$T/reader")|$(said 'unsupported-field: CallNode.ignore_visibility')" "1|1"

echo "upstream-fields: block slot names"
slot=$(face k.rb nodes | awk -F'\t' '$2 == "RequiredParameterNode" && $8 ~ /^i__b/ { print $8; exit }')
ok "the block parameter has a slot of its own" "$(printf '%s\n' "$slot" | grep -c '^i__b')" 1
ok "a parameter node naming no slot is refused" \
  "$(FACE=nodes SED="/	RequiredParameterNode	/s/	$slot\$/	i/" kernel "$T/k.contract" "$T/reader")|$(said 'local scope identity is not established')" "1|1"

echo "upstream-fields: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
