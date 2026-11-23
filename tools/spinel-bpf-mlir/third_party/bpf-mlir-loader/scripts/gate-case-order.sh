# The mutation case-ID collection is unordered; diagnostics inside a case are not.
# Keep duplicates and propagate parser/sort/comm failures rather than hiding them.
gate_sorted_case_ids() {
  printf '%s\n' "$1" | tr '[:space:]' '\n' | sed '/^$/d' | LC_ALL=C sort
}

gate_read_diff_ids() {
  awk '/^DIFF / {
    if (NF < 2 || $2 !~ /:$/) { bad=1; next }
    sub(/:$/, "", $2); print $2
  } END { if (bad) { print "case-ids: malformed DIFF record" > "/dev/stderr"; exit 2 } }' "$1"
}

gate_case_ids_match() {
  local label=$1 rc=$2 got want duplicates missing extra
  [ "$rc" = 1 ] || { echo "case-ids: $label: rc mismatch (want 1, got $rc)" >&2; return 1; }
  got=$(gate_sorted_case_ids "$3") || { echo "case-ids: $label: sort/parser failed (actual)" >&2; return 2; }
  want=$(gate_sorted_case_ids "$4") || { echo "case-ids: $label: sort/parser failed (expected)" >&2; return 2; }
  duplicates=$(printf '%s\n' "$got" | uniq -d) || return 2
  [ -z "$duplicates" ] || { echo "case-ids: $label: duplicate $duplicates" >&2; return 1; }
  missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got")) || return 2
  extra=$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got")) || return 2
  [ -z "$missing" ] || { echo "case-ids: $label: missing $missing" >&2; return 1; }
  [ -z "$extra" ] || { echo "case-ids: $label: extra $extra" >&2; return 1; }
  printf 'case-ids: %s: rc 1, %s IDs match\n' "$label" "$(printf '%s\n' "$want" | wc -l)"
}

# The normal gate and six locale/mode arms call this same real mutation stage.
gate_context_mutation() {
  local label=$1 expected=$2 tools=$3 log=$4 rc=0 ids log_fd
  exec {log_fd}> "$log" || { echo "case-ids: $label: cannot save log" >&2; return 2; }
  BML_MUTANT="$label" "$HERE/scripts/corpus-cases.sh" "$tools" >&"$log_fd" 2>&1 || rc=$?
  exec {log_fd}>&- || { echo "case-ids: $label: cannot save log (close)" >&2; return 2; }
  printf '%s\n' "$rc" > "$log.rc" || { echo "case-ids: $label: cannot save rc" >&2; return 2; }
  ids=$(gate_read_diff_ids "$log") || return 2
  printf '%s\n' "$ids" > "$log.ids" || { echo "case-ids: $label: cannot save IDs" >&2; return 2; }
  gate_case_ids_match "$label" "$rc" "$ids" "$expected" || return $?
  gate_sorted_case_ids "$ids" > "$log.canonical-ids" || { echo "case-ids: $label: cannot save canonical IDs" >&2; return 2; }
}
