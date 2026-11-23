# scripts/gate-wave1.sh — gate.sh の波 1 の段 (E033 の guard の section・E034 の test run・E035 の attach — cilium との差動)。gate.sh が 500 行を
# 超えたので分けた (E035)。gate.sh から `.` で読む — step・die・verified・vrecord・HERE・TMPDIR は gate.sh のもの。単独で走らせない。

step "E033: 波 1 の program type の section — 変異 load.wave1_sections_reject で tree の波 1 の ELF が shape で止まる (H4 — 一覧もここから)、4 権限の照合しない load を bml と cilium で (名指しの none_guard・exp_attach_rewrite だけ — host、sudo — 利用者の承認 2026-10-01)"
if gate_root e033-wave1-load && ! verified wave1load; then
  # E036: lwt_seg6local は guard の表に無い (波 1 の 16 の外) — 正規表現を表に合わせた (v1.5.0 の tree の seg6local の 2 つは E036 の名指しの shape の停止)
  # E035: uretprobe/<symbol> を表に足した (E033 の書き漏らし) — 正規表現も合わせた
  W1RE='^section (action|cgroup_skb/(ingress|egress)|flow_dissector|fmod_ret/[^ ]+|iter/[^ ]+|kretprobe/[^ ]+|lwt_(in|out|xmit)|netfilter|raw_tp/[^ ]+|sk_lookup|socket|syscall|uretprobe(/[^ ]+)?) is not in the bpf-mlir ELF form$'
  # shellcheck disable=SC2046
  rsudo BML_MUTANT=load.wave1_sections_reject unshare -n "$HERE/build/tools-mut/load_case" --unchecked $(cat "$TMPDIR/gate-live-elfs.txt") 2> /dev/null |
    awk -F'\t' -v re="$W1RE" '$3=="shape" && $4 ~ re {print $1}' > "$TMPDIR/gate-wave1-elfs.txt"
  nw1=$(wc -l < "$TMPDIR/gate-wave1-elfs.txt")
  [ "$nw1" -ge 33 ] || die "E033: 変異 load.wave1_sections_reject で shape で止まる波 1 の ELF が $nw1 (33 以上のはず)"
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E033 の Go の oracle の build"
  rsudo "$HERE/scripts/load-wave1-target.sh" "$TMPDIR/gate-wave1" "$HERE/build/tools" "$HERE/build/oracles/load-oracle" "$TMPDIR/gate-wave1-elfs.txt" > "$TMPDIR/gate-wave1.txt" 2>&1 ||
    { cat "$TMPDIR/gate-wave1.txt"; die "E033: 波 1 の load が cilium と名指しの外で違う"; }
  head -1 "$TMPDIR/gate-wave1.txt"
  echo "ok: 変異で波 1 の ELF $nw1 が shape で止まる"
  vrecord wave1load
fi

step "E043: 波 2〜4 の program type の section — 変異 load.wave24_sections_reject で tree の波 2〜4 の ELF が shape で止まる (H4 — 一覧もここから)、4 権限の照合しない load を bml と cilium で (名指しの none_guard・exp_attach_rewrite・iter_target_missing (lsm の nohook) だけ — host、sudo — 利用者の承認 2026-10-04)"
if gate_root e043-wave24-load && ! verified wave24load; then
  W24RE='^section (cgroup/[^ ]+|lirc_mode2|lsm/[^ ]+|lsm[.]s/[^ ]+|lwt_seg6local|perf_event|raw_tp[.]w/[^ ]+|sk_msg|sk_reuseport(/migrate)?|sk_skb/(stream_parser|stream_verdict)|sockops) is not in the bpf-mlir ELF form$'
  # shellcheck disable=SC2046
  rsudo BML_MUTANT=load.wave24_sections_reject unshare -n "$HERE/build/tools-mut/load_case" --unchecked $(cat "$TMPDIR/gate-live-elfs.txt") 2> /dev/null |
    awk -F'\t' -v re="$W24RE" '$3=="shape" && $4 ~ re {print $1}' > "$TMPDIR/gate-wave24-elfs.txt"
  nw24=$(wc -l < "$TMPDIR/gate-wave24-elfs.txt")
  [ "$nw24" -ge 75 ] || die "E043: 変異 load.wave24_sections_reject で shape で止まる波 2〜4 の ELF が $nw24 (75 以上のはず)"
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E043 の Go の oracle の build"
  rsudo "$HERE/scripts/load-wave1-target.sh" "$TMPDIR/gate-wave24" "$HERE/build/tools" "$HERE/build/oracles/load-oracle" "$TMPDIR/gate-wave24-elfs.txt" > "$TMPDIR/gate-wave24.txt" 2>&1 ||
    { cat "$TMPDIR/gate-wave24.txt"; die "E043: 波 2〜4 の load が cilium と名指しの外で違う"; }
  head -1 "$TMPDIR/gate-wave24.txt"
  echo "ok: 変異で波 2〜4 の ELF $nw24 が shape で止まる"
  vrecord wave24load
fi

step "E034: 波 1 の test run (skb の族・flow_dissector・ctx・netfilter) を bml (ASan) と cilium の Program.Run で — 名指しの差は bml が kernel の前に止める VALUE_RANGE (N3・R2) と STATE (X1〜X4) だけ、変異 run.kind_any で X1〜X4 だけが落ちる (host、unshare -n、sudo — 利用者の承認 2026-10-01)"
if gate_root e034-wave1-run && ! verified wave1run; then
  E34="$TMPDIR/e034"; K34="$HERE/third_party/bpf-mlir/kernel"; mkdir -p "$E34"
  c34() { "$HERE/build/bpf-mlir/bin/ebpf-compile" "$1" --schema "$2" -o "$E34/$3.bpf.o" && sha256sum "$2" | cut -d' ' -f1 > "$E34/$3.sha"; }
  for n in sf act cgi cge lwt fd; do c34 "$K34/skbkinds/mlir/$n.mlir" "$K34/skbkinds/mlir/$n.schema.json" $n; done
  c34 "$K34/netfilter/mlir/nf.mlir" "$K34/netfilter/mlir/schema.json" nf
  c34 "$K34/rawtp/mlir/rawtp.mlir" "$K34/rawtp/mlir/schema.json" rawtp
  c34 "$K34/syscall/mlir/sys.mlir" "$K34/syscall/mlir/schema.json" sys
  c34 "$K34/sklookup/mlir/sk.mlir" "$K34/sklookup/mlir/schema.json" sk
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E034 の Go の oracle の build"
  R34="$HERE/test/abi/fixture/e34_runs.txt"
  rsudo unshare -n "$HERE/build/tools-asan/run_wave1" "$R34" "$E34" > "$TMPDIR/gate-e34-bml.txt" 2> "$TMPDIR/gate-e34-bml.err" || die "E034: run_wave1"
  rsudo unshare -n "$HERE/build/oracles/run-oracle" "$R34" "$E34" > "$TMPDIR/gate-e34-go.txt" 2> "$TMPDIR/gate-e34-go.err" || die "E034: run-oracle"
  d34=$(paste -d'|' "$TMPDIR/gate-e34-go.txt" "$TMPDIR/gate-e34-bml.txt" | awk -F'|' '{split($2,b,"\t"); if ($1 != $2) print b[1] ":" b[2]}' | tr '\n' ' ')
  [ "$d34" = "N3:value_range R2:value_range X1:state X2:state X3:state X4:state " ] || die "E034: cilium との違いが名指しと違う: $d34"
  [ "$(wc -l < "$TMPDIR/gate-e34-bml.txt")" = 20 ] || die "E034: case の数が 20 でない"
  m34=$(rsudo BML_MUTANT=run.kind_any unshare -n "$HERE/build/tools-mut/run_wave1" "$R34" "$E34" 2> /dev/null | diff - "$TMPDIR/gate-e34-bml.txt" | grep '^<' | cut -f1 | tr -d '< ' | tr '\n' ' ' || true)
  [ "$m34" = "X1 X2 X3 X4 " ] || die "E034: 変異 run.kind_any の落ちる case が予測と違う: $m34"
  echo "ok: 20 case — cilium と同じ 14、名指し (bml が先に止める) 6、変異 run.kind_any は X1〜X4"
  vrecord wave1run
fi

step "E035: 波 1 の attach (raw_tp・kretprobe・uretprobe・iter・fmod_ret) を bml (ASan) と cilium の traceattach で — 6 入力 × root と bpf+perfmon の観測の文が同じ、check の行と変異 6 つが予測どおり、試験の program を残さない (host、unshare -n、sudo — 利用者の承認 2026-10-01)"
if gate_root e035-wave1-attach && ! verified wave1attach; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E035 の Go の oracle (traceattach) の build"
  rsudo "$HERE/scripts/attach-wave1-target.sh" "$TMPDIR/gate-e035" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/traceattach" \
    "$HERE/build/bpf-mlir/bin/ebpf-compile" > "$TMPDIR/gate-e035.txt" 2>&1 || { cat "$TMPDIR/gate-e035.txt"; die "E035: 波 1 の attach が cilium か予測と違う"; }
  [ "$(grep -c '^same ' "$TMPDIR/gate-e035.txt")" = 12 ] && [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e035.txt")" = 6 ] ||
    { cat "$TMPDIR/gate-e035.txt"; die "E035: same 12・変異 6 でない"; }
  ! grep -q '^note ' "$TMPDIR/gate-e035.txt" || { grep '^note ' "$TMPDIR/gate-e035.txt"; die "E035: traceattach と bml の ELF が違う"; }
  echo "ok: 6 入力 × 2 権限が cilium と同じ、check と変異 6 つが予測どおり、$(grep '^counts' "$TMPDIR/gate-e035.txt")"
  vrecord wave1attach
fi

step "E038: 呼び手の先への attach (cgroup・netns の fd・socket) を bml (ASan) と cilium の oracle で — 4 入力の観測の文が同じ、check の行・attachcheck の cge の want・変異 3 つが予測どおり、子の cgroup と試験の program を残さない (host、unshare -n、sudo — 利用者の承認 2026-10-02)"
if gate_root e038-caller-attach && ! verified callerattach; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E038 の Go の oracle (attach-caller-oracle) の build"
  rsudo "$HERE/scripts/attach-caller-target.sh" "$TMPDIR/gate-e038" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/attach-caller-oracle" \
    "$HERE/build/bpf-mlir/bin/ebpf-compile" > "$TMPDIR/gate-e038.txt" 2>&1 || { cat "$TMPDIR/gate-e038.txt"; die "E038: 呼び手の先への attach が cilium か予測と違う"; }
  [ "$(grep -c '^same ' "$TMPDIR/gate-e038.txt")" = 4 ] && [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e038.txt")" = 7 ] ||
    { cat "$TMPDIR/gate-e038.txt"; die "E038: same 4・変異 7 (3 種) でない"; }
  echo "ok: 4 入力が cilium と同じ、check と変異が予測どおり、$(grep '^progs' "$TMPDIR/gate-e038.txt")"
  vrecord callerattach
fi

step "E040: tracepoint の全ての CPU の attach (bpf-mlir U1 の回避) — CPU の list の単体試験 (非 root)、bml (ASan) と Go の livecaps.AttachTracepointAllCPUs の観測の文が同じ・link.Tracepoint の arm は変異 tp_cpu0_only と同じ、check と変異 3 種が予測どおり、試験の program を残さない (host、unshare -n、sudo — 利用者の承認 2026-10-02)"
"$HERE/build/tools-asan/tp_cpus" > "$TMPDIR/gate-tpcpus.txt" || { cat "$TMPDIR/gate-tpcpus.txt"; die "E040: CPU の list の単体試験"; }
if gate_root e040-tpallcpu && ! verified tpallcpu; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E040 の Go の oracle (attach-tp-oracle) の build"
  rsudo "$HERE/scripts/attach-tp-target.sh" "$TMPDIR/gate-e040" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/attach-tp-oracle" \
    "$HERE/build/bpf-mlir/bin/ebpf-compile" > "$TMPDIR/gate-e040.txt" 2>&1 || { cat "$TMPDIR/gate-e040.txt"; die "E040: tracepoint の attach が Go か予測と違う"; }
  [ "$(grep -c '^same ' "$TMPDIR/gate-e040.txt")" = 2 ] && [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e040.txt")" = 6 ] ||
    { cat "$TMPDIR/gate-e040.txt"; die "E040: same 2・変異 6 (3 種) でない"; }
  echo "ok: tpw と tp が Go と同じ、cilium の arm と変異が予測どおり、$(grep '^progs' "$TMPDIR/gate-e040.txt")"
  vrecord tpallcpu
fi

step "E044: USDT の attach (§8 の ref_ctr の契約) — 点の計算が Go の usdtattach.Points と byte で同じ (非 root、3 build)、bml (ASan) の点ごとの形と試験の口の multi の形が Go の AttachUSDT と同じ、名前つきの観測 multi_prog_perf_attach・norefctr、変異 6 つ、製品の照合する load は usdt_loader で止める (host、unshare -n、sudo — 利用者の承認 2026-10-04)"
E44="$TMPDIR/e044"; K44="$HERE/third_party/bpf-mlir/kernel/p1dusdt/mlir"; B44="$HERE/third_party/bpf-mlir/docs/experiments/results/E459/build"
rm -rf "$E44"; mkdir -p "$E44"
"$HERE/scripts/build-oracles.sh" > /dev/null || die "E044 の Go の oracle (usdt-attach-oracle) の build"
for b in O0 O2 gcc-O2; do
  s44="$K44/usdt-$b.schema.json"; [ "$b" = O0 ] && s44="$K44/usdt.schema.json"
  "$HERE/build/bpf-mlir/bin/ebpf-compile" "$K44/usdt.mlir" --schema "$s44" -o "$E44/usdt-$b.bpf.o" || die "E044: compile $b"
  sha256sum "$s44" | cut -d' ' -f1 > "$E44/usdt-$b.sha"
  cp "$B44/fixture-$b" "$E44/fixture-$b"
  cmp -s <("$HERE/build/oracles/usdt-attach-oracle" points "$E44/fixture-$b") <("$HERE/build/tools-asan/usdt_run" points "$E44/fixture-$b") ||
    die "E044: 点の計算が Go と違う ($b)"
done
if gate_root e044-usdt && ! verified usdtattach; then
  rsudo "$HERE/scripts/usdt-attach-target.sh" "$E44" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/usdt-attach-oracle" \
    > "$TMPDIR/gate-e044.txt" 2>&1 || { cat "$TMPDIR/gate-e044.txt"; die "E044: USDT の attach が Go か予測と違う"; }
  # E046: 製品の照合する load (C ABI の宣言 — E052 から cilium-v0.22-usdt-ksyscall) は OK・product の 3 build も Go と同じ (same 9)、
  # 変異 abi.decl_cilium022 (6 つ目)、E052 の abi.decl_no_usdt・abi.decl_no_ksyscall (8 つ)
  [ "$(grep -c '^same ' "$TMPDIR/gate-e044.txt")" = 9 ] && [ "$(grep -c '^named ' "$TMPDIR/gate-e044.txt")" = 2 ] &&
    [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e044.txt")" = 8 ] && grep -qx 'checked ok' "$TMPDIR/gate-e044.txt" ||
    { cat "$TMPDIR/gate-e044.txt"; die "E044 / E046 / E052: same 9・named 2・変異 8 (+ no_ref_ctr は named)・checked ok でない"; }
  echo "ok: 3 build × 点ごと / multi / 製品の照合する load + attach が Go と同じ、named 2、変異 9、製品の照合する load は OK (E046)"
  vrecord usdtattach
fi

step "E049 / E052: ksyscall の attach (bml_attach_ksyscall — Go の livecaps.AttachKsyscall の写し) — count / args / nosys の行が Go と byte で同じ、変異 3 つ (照らし・machine・照らしを外すと付いてしまう対照)。E052: 製品の照合する load (宣言 cilium-v0.22-usdt-ksyscall) は OK・製品の口の行・nosys の照合が Go の ebpf-precheck と同じ・宣言の変異 3 つ (host、unshare -n、sudo — 利用者の承認 2026-10-12・2026-10-18)"
E49="$TMPDIR/e049"; K49="$HERE/third_party/bpf-mlir/kernel/p2cksys/mlir"
rm -rf "$E49"; mkdir -p "$E49"
for n in count args nosys; do
  "$HERE/build/bpf-mlir/bin/ebpf-compile" "$K49/$n.mlir" --schema "$K49/$n.schema.json" -o "$E49/$n.bpf.o" || die "E049: compile $n"
  sha256sum "$K49/$n.schema.json" | cut -d' ' -f1 > "$E49/$n.sha"
done
if gate_root e049-ksyscall && ! verified ksysattach; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E049 の Go の oracle (ksys-attach-oracle) の build"
  rsudo "$HERE/scripts/ksys-attach-target.sh" "$E49" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/ksys-attach-oracle" \
    "$HERE/build/tools/ebpf-precheck" > "$TMPDIR/gate-e049.txt" 2>&1 || { cat "$TMPDIR/gate-e049.txt"; die "E049 / E052: ksyscall の attach が Go か予測と違う"; }
  [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e049.txt")" = 6 ] && [ "$(grep -c '^same ' "$TMPDIR/gate-e049.txt")" = 3 ] &&
    grep -qx 'checked ok' "$TMPDIR/gate-e049.txt" || { cat "$TMPDIR/gate-e049.txt"; die "E049 / E052: same 3・変異 6・checked ok でない"; }
  echo "ok: Go と同じ、製品の口の行と nosys の照合も同じ、変異 6、製品の照合する load は OK (E052)"
  vrecord ksysattach
fi

step "E051: netfilter の link (bml_attach_netfilter — cilium の link.AttachNetfilter と同じ) — 使い捨ての netns の中で E402 の観測の文と link の info が Go と byte で同じ、無効な引数、変異 2 つ (照らし・照らしを外すと別の priority に付いてしまう対照) (host、unshare -n、sudo — 利用者の承認 2026-10-13)"
E51="$TMPDIR/e051"; K51="$HERE/third_party/bpf-mlir/kernel/netfilter/mlir"
rm -rf "$E51"; mkdir -p "$E51"
"$HERE/build/bpf-mlir/bin/ebpf-compile" "$K51/nf.mlir" --schema "$K51/schema.json" -o "$E51/nf.bpf.o" || die "E051: compile nf"
sha256sum "$K51/schema.json" | cut -d' ' -f1 > "$E51/nf.sha"
if gate_root e051-netfilter && ! verified nfattach; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E051 の Go の oracle (nf-attach-oracle) の build"
  rsudo "$HERE/scripts/nf-attach-target.sh" "$E51" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/oracles/nf-attach-oracle" \
    > "$TMPDIR/gate-e051.txt" 2>&1 || { cat "$TMPDIR/gate-e051.txt"; die "E051: netfilter の link が Go か予測と違う"; }
  [ "$(grep -c '^mutant .* ok' "$TMPDIR/gate-e051.txt")" = 2 ] && grep -x 'same c go' "$TMPDIR/gate-e051.txt" > /dev/null ||
    { cat "$TMPDIR/gate-e051.txt"; die "E051: same・変異 2 でない"; }
  echo "ok: 使い捨ての netns の中で Go と同じ、変異 2"
  vrecord nfattach
fi

step "E053: tpfield / sysarg の strptr・strarray — 分類の差動 (非 root の作った宣言・tracefs・__do_sys_ の BTF と root の本当の tracefs)、変異 caps.str_depth_any、作った ELF 9 の live の差動と製品の照合する load (load だけ)"
E53="$TMPDIR/e053"; K53="$HERE/third_party/bpf-mlir/kernel"
rm -rf "$E53"; mkdir -p "$E53"
for m in ksysuserstr/mlir/ksys_user_str:schema tpuserstr/mlir/tp_user_str:schema userargv/mlir/argv:argv.schema userargv/mlir/argv20:argv20.schema \
         userargv/mlir/tp_argv:tp_argv.schema userargv/diff/mlir/f1:f1.schema userargv/diff/mlir/f2:f2.schema userargv/diff/mlir/f3:f3.schema userargv/diff/mlir/f4:f4.schema; do
  p=${m%%:*}; s="$K53/$(dirname "$p")/${m##*:}.json"
  "$HERE/build/bpf-mlir/bin/ebpf-compile" "$K53/$p.mlir" --schema "$s" -o "$E53/$(basename "$p").bpf.o" || die "E053: compile $p"
  sha256sum "$s" | cut -d' ' -f1 > "$E53/$(basename "$p").sha"
done
ls "$E53"/*.bpf.o > "$E53/list.txt"
if ! verified strarg; then
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E053 の Go の oracle (strarg-live) の build"
  "$HERE/scripts/diff-strarg.sh" n "$HERE/build/tools" "$TMPDIR/gate-strarg-n" || die "E053: 非 root の分類の差動で差"
  mrc=0; BML_MUTANT=caps.str_depth_any "$HERE/scripts/diff-strarg.sh" n "$HERE/build/tools-mut" "$TMPDIR/gate-strarg-mut" > "$TMPDIR/gate-strarg-mut.txt" 2>&1 || mrc=$?
  [ "$mrc" = 1 ] && grep -q '^diff-strarg: fmt DIFF' "$TMPDIR/gate-strarg-mut.txt" && grep -q '^diff-strarg: btf DIFF' "$TMPDIR/gate-strarg-mut.txt" &&
    grep -q '^diff-strarg: decl .* same' "$TMPDIR/gate-strarg-mut.txt" || { cat "$TMPDIR/gate-strarg-mut.txt"; die "E053: 変異 caps.str_depth_any が fmt と btf で落ちない"; }
  if gate_root e053-strarg; then
  rsudo "$HERE/scripts/diff-strarg.sh" r "$HERE/build/tools" "$TMPDIR/gate-strarg-r" || die "E053: root の本当の tracefs の分類の差動で差"
  rsudo "$HERE/scripts/checked-load-target.sh" "$E53" "$HERE/test/abi/fixture/e53-ringbuf.maps.json" "$HERE/build/tools" "$HERE/build/tools/ebpf-precheck" \
    > "$TMPDIR/gate-e053-load.txt" 2>&1 || { cat "$TMPDIR/gate-e053-load.txt"; die "E053: 製品の照合する load が Go と違う"; }
  [ "$(grep -c '^root [^ ]*\.bpf\.o kind=0 unmet=$' "$TMPDIR/gate-e053-load.txt")" = 5 ] || { cat "$TMPDIR/gate-e053-load.txt"; die "E053: root の製品の load が 5 つとも OK でない"; }
  rsudo "$HERE/scripts/live-diff.sh" "$E53/list.txt" "$TMPDIR/gate-e053-live" "$HERE/build/tools" root bpf,net_admin > "$TMPDIR/gate-e053-live.txt" 2>&1
  [ "$(grep -c "(A) 記録: *9 same" "$TMPDIR/gate-e053-live.txt")" = 2 ] && [ "$(grep -cE "\(B\) .*: *9 same" "$TMPDIR/gate-e053-live.txt")" = 4 ] ||
    { cat "$TMPDIR/gate-e053-live.txt"; die "E053: 作った ELF 9 の live の差動で差"; }
  echo "ok: 分類の差動 (n・r)・変異 str_depth_any・製品の load・作った ELF 9 の live"
  vrecord strarg
  fi
fi

step "E054: tpfield の byte の配列 [N]u8 / [N]i8 と kfield の経路 — 変異 caps.tp_array_shape_any (分類の差動の fmt) と caps.kpath_leaf_only (diff-live-btf)、作った ELF 17 の live の差動と製品の照合する load 13 (load だけ)"
E54="$TMPDIR/e054"; rm -rf "$E54"; mkdir -p "$E54"
for p in tparray/mlir/copy tparray/mlir/copy4 tparray/mlir/copy_ring tparray/diff/mlir/f1 tparray/diff/mlir/f2 tparray/diff/mlir/f3 tparray/diff/mlir/f4 \
         kfieldpath/mlir/copy kfieldpath/mlir/load kfieldpath/mlir/load3 kfieldpath/mlir/mutant kfieldpath/mlir/ptr kfieldpath/mlir/socket kfieldpath/mlir/str \
         kptraddr/mlir/end kptraddr/mlir/mutant kptraddr/mlir/request; do
  n=$(printf '%s' "$p" | tr / _ | sed 's/_mlir//')
  "$HERE/build/bpf-mlir/bin/ebpf-compile" "$K53/$p.mlir" --schema "$K53/$p.schema.json" -o "$E54/$n.bpf.o" || die "E054: compile $p"
  sha256sum "$K53/$p.schema.json" | cut -d' ' -f1 > "$E54/$n.sha"
done
ls "$E54"/*.bpf.o > "$E54/list.txt"
if ! verified tparray; then
  mrc=0; BML_MUTANT=caps.tp_array_shape_any "$HERE/scripts/diff-strarg.sh" n "$HERE/build/tools-mut" "$TMPDIR/gate-tparray-mut" > "$TMPDIR/gate-tparray-mut.txt" 2>&1 || mrc=$?
  [ "$mrc" = 1 ] && grep -q '^diff-strarg: fmt DIFF' "$TMPDIR/gate-tparray-mut.txt" && grep -q '^diff-strarg: decl .* same' "$TMPDIR/gate-tparray-mut.txt" ||
    { cat "$TMPDIR/gate-tparray-mut.txt"; die "E054: 変異 caps.tp_array_shape_any が fmt で落ちない"; }
  if BML_MUTANT=caps.kpath_leaf_only "$HERE/scripts/diff-live-btf.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-kpath-mut.txt" 2>&1; then die "E054: 変異 caps.kpath_leaf_only で diff-live-btf が落ちない"; fi
  if gate_root e054-tparray; then
  rsudo "$HERE/scripts/checked-load-target.sh" "$E54" "$HERE/test/abi/fixture/e54-undeclared.maps.json" "$HERE/build/tools" "$HERE/build/tools/ebpf-precheck" \
    tparray_copy tparray_copy4 tparray_copy_ring tparray_diff_f1 tparray_diff_f2 tparray_diff_f3 tparray_diff_f4 \
    kfieldpath_copy kfieldpath_load kfieldpath_load3 kfieldpath_ptr kfieldpath_socket kfieldpath_str > "$TMPDIR/gate-e054-load.txt" 2>&1 ||
    { cat "$TMPDIR/gate-e054-load.txt"; die "E054: 製品の照合する load が Go と違う"; }
  [ "$(grep -c '^root tparray_[^ ]*\.bpf\.o kind=0 unmet=$' "$TMPDIR/gate-e054-load.txt")" = 7 ] || { cat "$TMPDIR/gate-e054-load.txt"; die "E054: root の tparray の製品の load が 7 つとも OK でない"; }
  rsudo "$HERE/scripts/live-diff.sh" "$E54/list.txt" "$TMPDIR/gate-e054-live" "$HERE/build/tools" root bpf,net_admin > "$TMPDIR/gate-e054-live.txt" 2>&1
  [ "$(grep -c "(A) 記録: *17 same" "$TMPDIR/gate-e054-live.txt")" = 2 ] && [ "$(grep -cE "\(B\) .*: *17 same" "$TMPDIR/gate-e054-live.txt")" = 4 ] ||
    { cat "$TMPDIR/gate-e054-live.txt"; die "E054: 作った ELF 17 の live の差動で差"; }
  echo "ok: 変異 tp_array_shape_any・kpath_leaf_only、製品の load 13、作った ELF 17 の live"
  vrecord tparray
  fi
fi

step "E055: 分けた DWARF (判定の版 16) — bml-precheck と ebpf-precheck の差動 (記録の caps 37 組・root の live 22 組と記録の再生)・変異 4 つの名指し・製品の照合する load (load だけ)"
if ! verified splitdwarf; then
  "$HERE/scripts/diff-split-dwarf.sh" n "$HERE/build/tools" "$TMPDIR/gate-split-n" > "$TMPDIR/gate-split-n.txt" 2>&1 || { tail -20 "$TMPDIR/gate-split-n.txt"; die "E055: 分けた DWARF の差動 (記録の caps) で差"; }
  for mf in "check.debug_build_id_skip:multi_badid badid " "check.debug_crc_skip:badcrc " \
            "dwarf.select_by_name:alias_ok embed_alias ret_alias multi nolink_ok badcrc_nolink zlib relpath " \
            "dwarf.legacy_name_first:alias_ok twocu_u64 twocu_u32 embed_twocu_u64 embed_twocu_u32 embed_alias ret_alias multi nolink_ok badcrc_nolink zlib relpath "; do
    mrc=0; BML_MUTANT="${mf%%:*}" "$HERE/scripts/diff-split-dwarf.sh" n "$HERE/build/tools-mut" "$TMPDIR/gate-split-mut" > "$TMPDIR/gate-split-mut.txt" 2>&1 || mrc=$?
    got=$(grep '^DIFF' "$TMPDIR/gate-split-mut.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
    [ "$mrc" = 1 ] && [ "$got" = "${mf#*:}" ] || die "E055: 変異 ${mf%%:*} の落ちる組が予測と違う (rc $mrc): $got"
  done
  if gate_root e055-splitdwarf; then
  rsudo "$HERE/scripts/diff-split-dwarf.sh" r "$HERE/build/tools" "$TMPDIR/gate-split-r" > "$TMPDIR/gate-split-r.txt" 2>&1 || { tail -20 "$TMPDIR/gate-split-r.txt"; die "E055: 分けた DWARF の差動 (root の live) で差"; }
  rsudo "$HERE/scripts/split-load-target.sh" "$TMPDIR/gate-split-load" "$HERE/build/tools" "$HERE/build/bpf-mlir/bin/ebpf-compile" > "$TMPDIR/gate-split-load.txt" 2>&1 ||
    { cat "$TMPDIR/gate-split-load.txt"; die "E055: 製品の照合する load が Go と違う"; }
  [ "$(grep -cE '^root (override|root) kind=0 unmet=$' "$TMPDIR/gate-split-load.txt")" = 2 ] || { cat "$TMPDIR/gate-split-load.txt"; die "E055: 合う分けた file の製品の load が OK でない"; }
  echo "ok: $(tail -1 "$TMPDIR/gate-split-n.txt")・$(tail -1 "$TMPDIR/gate-split-r.txt")・変異 4・製品の load"
  vrecord splitdwarf
  fi
fi

step "E056: uprobe の attach の file offset (照合と同じ規則 — .dynsym だけの binary) — cilium の写しとの比べ (system の libc と fixture)・変異 uprobe.attach_symtab_only・自分の子 process への attach (root)"
if ! verified uprobeoffset; then
  "$HERE/scripts/diff-uprobe-offset.sh" "$HERE/build/tools" "$TMPDIR/gate-uoff" > "$TMPDIR/gate-uoff.txt" 2>&1 || { tail -5 "$TMPDIR/gate-uoff.txt"; die "E056: attach の offset が cilium と違う"; }
  BML_MUTANT=uprobe.attach_symtab_only "$HERE/build/tools-mut/uprobe_offset" "$TMPDIR/gate-uoff/fx/dynsym" | grep -qP '^e56_fn\terror\tthe target has 0 FUNC symbols named e56_fn' ||
    die "E056: 変異 uprobe.attach_symtab_only で dynsym の e56_fn が 0 FUNC にならない"
  "$HERE/scripts/e56-attach-target.sh" prep "$TMPDIR/gate-e56" none || die "E056: H3 の prep"
  if gate_root e056-uprobe-offset; then
  rsudo "$HERE/scripts/e56-attach-target.sh" run "$TMPDIR/gate-e56" > "$TMPDIR/gate-e56.txt" 2>&1 || { cat "$TMPDIR/gate-e56.txt"; die "E056: .dynsym だけの本体への attach"; }
  echo "ok: $(tail -1 "$TMPDIR/gate-uoff.txt" | cut -c1-120)・変異・attach hits=4,4"
  vrecord uprobeoffset
  fi
fi
