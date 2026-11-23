#!/bin/bash
# Reproduce writer errors in the same || context as the real gate (no BPF/tool).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/tmp"
if [ "$#" = 1 ]; then
  W=$1
  [ ! -e "$W" ] || { echo 'gate-storage: output already exists' >&2; exit 2; }
  mkdir -p "$W"
else
  W=$(mktemp -d "$ROOT/build/tmp/gate-storage.XXXXXX")
fi
. "$ROOT/scripts/gate-case-order.sh"
HERE="$W/fixture"
mkdir -p "$HERE/scripts"
cat > "$HERE/scripts/corpus-cases.sh" <<'STUB'
#!/bin/bash
printf 'mutation\n' >> "$EVENTS"
printf 'DIFF a: want wrong\n          got right\n'
exit 1
STUB
chmod +x "$HERE/scripts/corpus-cases.sh"
# Stub later stages only to count entries. The real helper owns every file write.
gate_read_diff_ids() { printf 'parse\n' >> "$EVENTS"; printf 'a\n'; }
gate_case_ids_match() { printf 'compare\n' >> "$EVENTS"; }
gate_sorted_case_ids() { printf 'canonical\n' >> "$EVENTS"; printf 'a\n'; }
failures=0
for arm in log rc ids canonical normal; do
  d="$W/$arm"; mkdir -p "$d"
  export EVENTS="$d/events.txt"
  : > "$EVENTS"
  log="$d/mutation.log"
  case "$arm" in
    log) mkdir "$log"; want_events='' ;;
    rc) mkdir "$log.rc"; want_events='mutation' ;;
    ids) mkdir "$log.ids"; want_events=$'mutation\nparse' ;;
    canonical) mkdir "$log.canonical-ids"; want_events=$'mutation\nparse\ncompare' ;;
    normal) want_events=$'mutation\nparse\ncompare\ncanonical' ;;
  esac
  rc=0
  gate_context_mutation check.ctx_access_ignored a unused "$log" > "$d/stdout.txt" 2> "$d/stderr.txt" || rc=$?
  printf '%s\n' "$rc" > "$d/observed.rc"
  got_events=$(cat "$EVENTS")
  want_rc=2; [ "$arm" != normal ] || want_rc=0
  if [ "$rc" != "$want_rc" ] || [ "$got_events" != "$want_events" ]; then
    echo "gate-storage: FAIL $arm rc=$rc (want $want_rc), stage trace mismatch"
    failures=$((failures + 1))
  elif [ "$arm" != normal ] && ! grep -q 'case-ids: .*: cannot save' "$d/stderr.txt"; then
    echo "gate-storage: FAIL $arm missing named save error"
    failures=$((failures + 1))
  elif [ "$arm" = normal ]; then
    [ "$(cat "$log.rc")" = 1 ] && [ "$(cat "$log.ids")" = a ] &&
      [ "$(cat "$log.canonical-ids")" = a ] || exit 1
    echo 'gate-storage: GREEN normal writes, stage trace mutation/parse/compare/canonical'
  else
    echo "gate-storage: GREEN $arm cannot-save, all later stages 0"
  fi
done
echo "gate-storage: failures=$failures raw=$W"
[ "$failures" = 0 ]
