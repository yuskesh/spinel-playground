# scripts/gate-mutants.sh — gate.sh の版の取り込みの corpus の変異 (E032〜E041)。gate.sh が 500 行を超えたので分けた (E041)。
# gate.sh から `.` で読む — die・HERE・TMPDIR は gate.sh のもの。単独で走らせない。
# E032 (形式の版 10・判定の版 8 — bpf-mlir E397 / E404): uretprobe の呼び出し規約・fmod_ret の整数の引数
# E039 (形式の版 12・判定の版 11 — bpf-mlir E456): uretprobe_multi も同じ照合、新しい変異 3 つ (USDT の引数・multi の 2 番目以降の target・版 12 の行の最小の版)
# E041 (形式の版 13・判定の版 12 — bpf-mlir E480): kfunc の引数・map の target の静的な答え・版 13 の行の最小の版・caps の知らない形式の順
# E045: kfunc_allowed_skip は E525 のdenied 9・key_missing・no_query の 11 case を足して 26 (allowed は skip と同じ [])。
KFUNC_SKIP_IDS="e499_kfunc_allowed_caps8 e499_kfunc_allowed_error e499_kfunc_allowed_key_missing e499_kfunc_allowed_no_query e499_kfunc_allowed_unknown e499_kfunc_allowed_wrong_answer e499_kfunc_fsession_recipe_absent e499_kfunc_syscall_denied e499_kfunc_syscall_reprobe_denied e499_kfunc_xdp_denied e525_kfunc_cgroup_device_denied e525_kfunc_cgroup_sock_addr_denied e525_kfunc_cgroup_sock_denied e525_kfunc_cgroup_sockopt_denied e525_kfunc_cgroup_sysctl_denied e525_kfunc_perf_event_denied e525_kfunc_raw_tp_denied e525_kfunc_raw_tp_key_missing e525_kfunc_raw_tp_no_query e525_kfunc_sock_ops_denied e525_kfunc_tracepoint_denied v13_kfunc_absent v13_kfunc_int_width v13_kfunc_ok v13_kfunc_unknown v13_session_kfunc_7_1_8 e600_enumval_absent e600_enumval_caps10 e600_enumval_differs e600_enumval_no_query e600_enumval_ok e600_enumval_unknown e628_coreenum_absent e628_coreenum_caps10 e628_coreenum_no_query e628_coreenum_ok e628_coreenum_unknown e628_coreenum_value_differs" # stop-C: old26 + new12, no removals; preserve four fatal controls.
for mf in "check.uretprobe_abi_skip:uretprobe_go_function uretprobe_lang_unknown uretprobe_no_dwarf v12_uretmulti_go_function " \
          "check.fmodret_skip_farg:v10_fmodret_farg_mismatch v10_fmodret_no_func_param " \
          "check.usdt_arg_skip:v12_usdt_arg_sign v12_usdt_arg_size v12_usdt_rip v12_usdt_sib " \
          "check.multi_target_first_only:user_ptr_multi_mismatch v12_kmulti_arg_mismatch v12_kmulti_symbol_absent v12_umulti_arg_mismatch v12_umulti_symbol_absent v12_uretmulti_go_function v13_kmulti_args_mismatch v13_umulti_args_mismatch " \
          "check.kfunc_args_skip:v13_kfunc_int_width v13_session_kfunc_6_12 " \
          "check.static_map_target_skip:v13_sockmap_target_static v13_sockmap_target_wrong_kind v13_struct_ops_target_static v13_struct_ops_target_wrong_kind " \
          "check.kfunc_allowed_skip:$KFUNC_SKIP_IDS" \
          "check.tpbuf_skip:tpbuf_elf_error tpbuf_elf_key_missing tpbuf_elf_mismatch tpbuf_elf_no_query tpbuf_elf_prefixed_key tpbuf_elf_target_mismatch tpbuf_elf_target_wrong_key tpbuf_elf_unknown tpbuf_elf_unsigned " \
          "check.fentry_scalar_skip:fentry_scalar_mismatch fentry_scalar_no_param fentry_scalar_unknown " \
          "check.debug_build_id_skip:split_debug_build_id " "check.debug_crc_skip:split_debug_crc " \
          "dwarf.select_by_name:split_debug_alias split_debug_multi split_debug_no_link split_debug_ret split_debug_wrong_type " \
          "dwarf.legacy_name_first:split_debug_alias split_debug_multi split_debug_no_link split_debug_ret split_debug_wrong_type " \
          "dwarf.ptr_depth_any:user_ptr_indirect user_ptr_multi_mismatch user_ptr_void_indirect "; do # E047: 判定 15 の func_param、E055: 判定 16 の分けた DWARF と address の選び
  nrc=0; BML_MUTANT="${mf%%:*}" "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v10.txt" 2>&1 || nrc=$?
  got=$(grep '^DIFF' "$TMPDIR/gate-mut-v10.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
  gate_case_ids_match "${mf%%:*}" "$nrc" "$got" "${mf#*:}" || die "E032 / E039 / E041: 変異 ${mf%%:*} の落ちる case が予測と違う (rc $nrc): $got"
done
for mf in "parse.v12_rows_any_version:attach_kprobe_multi_before_v12 attach_usdt_before_v12 innermap_below_min_version mtarget_below_min_version usdtarg_below_min_version usdtsem_below_min_version " \
          "parse.v13_rows_any_version:attach_ksyscall_before_v13 attach_trace_lsm_cgroup_before_v13 btf_type_tag_before_v13 kfunc_below_min_version mtargetarg_below_min_version sysarg_below_min_version " \
          "parse.v14_rows_any_version:tpbuf_below_min_version tpbuf_min_version " \
          "parse.v15_rows_any_version:kfield_strptr_below_min_version " \
          "parse.v16_rows_any_version:sysarg_strarray_v15 sysarg_strptr sysarg_strptr_v15 tpfield_strarray_v15 tpfield_strptr_below_min_version " \
          "parse.v17_rows_any_version:embedded_kfield_v16 tpfield_array_below_min_version " \
          "parse.kfield_no_prefix_check:embedded_kfield_no_prefix " \
          "parse.v18_rows_any_version:mtargetarg_ptr_on_uprobe_multi uprobearg_ptr_below_min_version "; do # E047: kfield の型 strptr、E053: tpfield / sysarg の strptr・strarray、E054: tpfield の配列・kfield の経路と prefix
  nrc=0; BML_MUTANT="${mf%%:*}" "$HERE/scripts/corpus-parse.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v12p.txt" 2>&1 || nrc=$?
  got=$(grep '^DIFF' "$TMPDIR/gate-mut-v12p.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
  [ "$nrc" -eq 1 ] && [ "$got" = "${mf#*:}" ] || die "E039 / E041: 変異 ${mf%%:*} の落ちる case が予測と違う (rc $nrc): $got"
done
nrc=0; BML_MUTANT=caps.format_unknown_late "$HERE/scripts/corpus-json.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-fmt.txt" 2>&1 || nrc=$?
[ "$nrc" -eq 1 ] && [ "$(grep -c '^DIFF' "$TMPDIR/gate-mut-fmt.txt")" = 1 ] && grep -q '^DIFF caps_v21_newer_format' "$TMPDIR/gate-mut-fmt.txt" || die "E060: 変異 caps.format_unknown_late" # caps17 の直後
# E053: 記録の strptr / strarray の鍵の欠けを fatal に戻すと no_answer の 3 が落ちる (v16_tp_strptr_no_answer は族の不在の道 — 鍵の欠けの枝は
# strptr と strarray で同じ code (recorded_v16.c の keyed) で strarray の case が覆う)。深度を区別しない変異は corpus では落ちない (分類の差動が見る)
nrc=0; BML_MUTANT=caps.rec_str_absent_fatal "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v16.txt" 2>&1 || nrc=$?
# E054: 範囲を byte の配列の鍵に広げた — v17_tp_array_no_answer (族は在り u の鍵だけ) も落ちる。tp_array_shape_any・kpath_leaf_only は corpus で落ちない
[ "$nrc" -eq 1 ] && [ "$(grep '^DIFF' "$TMPDIR/gate-mut-v16.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ')" = "v16_sysarg_strarray_no_answer v16_sysarg_strptr_no_answer v16_tpfield_strarray_no_answer v17_tp_array_no_answer " ] ||
  die "E053: 変異 caps.rec_str_absent_fatal の落ちる case が予測と違う (rc $nrc)"
for m in caps.str_depth_any caps.tp_array_shape_any caps.kpath_leaf_only; do
  BML_MUTANT=$m "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v16d.txt" 2>&1 || die "E053 / E054: 変異 $m で corpus-cases が落ちた (予測は落ちない)"
done
echo "ok: E032〜E054 の変異 uretprobe_abi_skip 4・fmodret_skip_farg 2・usdt_arg_skip 4・multi_target_first_only 7・kfunc_args_skip 2・static_map_target_skip 4・kfunc_allowed_skip 26・tpbuf_skip 9・fentry_scalar_skip 3・v12〜v17_rows_any_version 6 / 6 / 2 / 1 / 5 / 2・kfield_no_prefix_check 1・rec_str_absent_fatal 4・str_depth_any / tp_array_shape_any / kpath_leaf_only 0 (corpus)・format_unknown_late 1"
. "$HERE/scripts/gate-reader-mutants.sh"
