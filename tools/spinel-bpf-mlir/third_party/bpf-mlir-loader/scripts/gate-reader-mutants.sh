# E060 H4: expected IDs come from source/want, fixed before the first run.
# Sourced by gate-mutants.sh; no root operations.
for mf in 'parse.fibflags_any_version:fibflags_below_min_version' \
          'parse.arena_no_reverse:arena_document_missing_row'; do
  nrc=0
  BML_MUTANT="${mf%%:*}" "$HERE/scripts/corpus-parse.sh" "$HERE/build/tools-mut" > "$TMPDIR/${mf%%:*}.log" 2>&1 || nrc=$?
  ids=$(gate_read_diff_ids "$TMPDIR/${mf%%:*}.log") || die "E060: parse mutation IDs"
  gate_case_ids_match "${mf%%:*}" "$nrc" "$ids" "${mf#*:}" || die "E060: parse mutation mismatch"
done
gate_context_mutation check.guard_unknown_false e621_kfield_guard_unknown "$HERE/build/tools-mut" "$TMPDIR/guard-unknown.log" || die 'E060: Unknown guard was not detected'
arena_ids=$(jq -r 'select(any(.unmet[]?; .kind == "arena_loader_unknown")) | input_filename | split("/")[-2]' "$HERE"/third_party/bpf-mlir/conformance/requirements/cases/*/want.json) || die 'E060: arena expected IDs'
[ -n "$arena_ids" ] || die 'E060: empty arena control'
gate_context_mutation check.arena_unknown_nonblocking "$arena_ids" "$HERE/build/tools-mut" "$TMPDIR/arena-unknown.log" || die 'E060: nonblocking arena Unknown was not detected'
# E066: 形式 30〜32 の corpus の外の差動・H4・H7 と、固定の表 (results/E066/mutants.tsv) の変異。kernel0
TR_OUT="$(mktemp -d "$TMPDIR/target-rows.XXXXXX")/run"
bash "$HERE/scripts/target-rows-unit.sh" "$TR_OUT" || die 'E066: target-rows unit'
bash "$HERE/scripts/target-rows-mutants.sh" "$TR_OUT" || die 'E066: target-rows mutants'
bash "$HERE/scripts/netkit-attach-mutants.sh" "$TR_OUT" || die 'E067: netkit attach mutants'
