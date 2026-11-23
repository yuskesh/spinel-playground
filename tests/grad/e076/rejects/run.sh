#!/bin/sh
# E076 rejects -- the reject corpus and the O2 bite-proof. Ported from
# spinel-llvm 463d49dd docs/experiments/results/E076/rejects/run.sh.
#
# Checks: the corpus compiles and runs as ordinary Ruby; gradgen refuses each of
# its declarations with the obstacle its section of rejects.rb names (expect.tsv;
# gradgen may name a pair such as O4/O6, and the expected one must be in it),
# and accepts only the rows expect.tsv marks `accepted`, each with its gradient
# gate G3 OK (O6's odecay, since the pin baddd25a9 types its local Float:
# docs/provenance.md); and `--bite oint`, which forces the integer
# primal past G1 on purpose, gets the adjoint E076 describes -- `ret void` --
# with nothing refused by opt.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
"$SPINEL" rejects.rb -o rejects_run
if ./rejects_run > run.txt 2>&1; then rc=0; else rc=1; fi
result corpus_runs_as_ruby $rc "$(wc -l < run.txt) lines"

if "$GRADGEN" rejects.rb -o out --allow-rejects > gradgen.txt 2>&1; then rc=0; else rc=1; fi
result gradgen_allow_rejects_exit $rc "$(tail -1 gradgen.txt)"
acc=$(awk -F'\t' 'NR>1 {print $1}' out/targets.tsv 2>/dev/null | sort | tr '\n' ' ')
want_acc=$(awk -F'\t' 'NR>1 && $2=="accepted" {print $1}' "$HERE/expect.tsv" | sort | tr '\n' ' ')
if [ "$acc" = "$want_acc" ]; then rc=0; else rc=1; fi
result only_expected_accepted $rc "accepted: ${acc:-none}; expected: ${want_acc:-none}"
tail -n +2 "$HERE/expect.tsv" | while IFS="$(printf '\t')" read -r t want; do
  if [ "$want" = accepted ]; then
    g3=$(awk -F'\t' -v t="$t" '$1=="G3" && $2==t {print $9}' out/gates.tsv | sort -u | tr '\n' ' ')
    if [ "$g3" = "OK " ]; then ok=0; else ok=1; fi
    result "accept_$t" $ok "G3 ${g3:-(no row)}"
    continue
  fi
  got=$(awk -F'\t' -v t="$t" '$1==t {print $2}' out/rejects.tsv)
  case "/$got/" in */"$want"/*) ok=0 ;; *) ok=1 ;; esac
  result "reject_$t" $ok "expected $want, got ${got:-(not refused)}"
done
n=$(awk 'NR>1' out/rejects.tsv | wc -l | tr -d ' ')
want_n=$(awk -F'\t' 'NR>1 && $2!="accepted"' "$HERE/expect.tsv" | wc -l | tr -d ' ')
if [ "$n" = "$want_n" ]; then rc=0; else rc=1; fi
result reject_rows $rc "$n rows"

"$GRADGEN" rejects.rb -o bite --allow-rejects --bite oint > bite.txt 2>&1 || true
if [ -f bite/bite_oint_adjoint.ll ] && grep -q 'ret void' bite/bite_oint_adjoint.ll; then rc=0; else rc=1; fi
result bite_empty_adjoint $rc "bite/bite_oint_adjoint.ll"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
