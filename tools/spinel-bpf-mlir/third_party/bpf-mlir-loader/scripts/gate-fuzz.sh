# Fuzz replay/search from gate.sh, kept separate to preserve its 500-line limit.
# Sourced with HERE, TMPDIR, step and die from the gate. Also runs in --static.
[ "$GATE_MODE" != vm-root ] || return 0 # E068: 非 root の fuzz は --static が受け持つ
step "E002 / E003 / E004 / E008: fuzz の種の再生 (ASan + UBSan — E011: 探索は gate の外で「scripts/fuzz.sh <名前> <秒>」、版の取り込みの時に — --full は 8 × 60 秒)"
for f in req_parse json req_elf recorded maps_decls btf_layout kbtf dwarf; do
  "$HERE/scripts/fuzz.sh" "$f" 0
done
# Full retains the existing fixed-time parallel search. Static only replays seeds.
if [ "${GATE_FULL:-0}" = 1 ]; then
  fp=()
  for f in req_parse json req_elf recorded maps_decls btf_layout kbtf dwarf; do
    "$HERE/scripts/fuzz.sh" "$f" 60 > "$TMPDIR/gate-fuzz-$f.txt" 2>&1 & fp+=("$!:$f")
  done
  for x in "${fp[@]}"; do
    wait "${x%%:*}" || { cat "$TMPDIR/gate-fuzz-${x#*:}.txt"; die "fuzz ${x#*:} の探索で crash (build/fuzz/${x#*:}/crash/)"; }
    tail -1 "$TMPDIR/gate-fuzz-${x#*:}.txt"
  done
fi
