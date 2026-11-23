# scripts/gate-vm-guest.sh — --vm-root の guest 側の job の実行 (E068)。判定はしない。VM の guest の script と wire の対照から読む。
#   vm_guest_loop <queue の dir> <run id> <job の秒の枠>   rc 0: stop の印で終わった、rc 2: 保存の故障で止まった
vm_guest_sha() { sha256sum "$1" | cut -c1-64; }
vm_guest_key() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
vm_guest_job() {
  local q=$1 run=$2 limit=$3 id=$4 r="$1/req/$4" t="$1/resp/.$4.tmp" transport=ok rc=255 cwd s
  local -a argv envs
  mkdir "$t" && : > "$t/stdout" && : > "$t/stderr" || return 2
  if [ "$(vm_guest_key "$r/meta" run)" != "$run" ] || [ "$(vm_guest_key "$r/meta" job)" != "$id" ]; then transport=request_id_mismatch
  elif [ "$(vm_guest_key "$r/meta" argv)" != "$(vm_guest_sha "$r/argv")" ] || [ "$(vm_guest_key "$r/meta" cwd)" != "$(vm_guest_sha "$r/cwd")" ] ||
       [ "$(vm_guest_key "$r/meta" env)" != "$(vm_guest_sha "$r/env")" ]; then transport=request_hash_mismatch
  else
    mapfile -d '' -t argv < "$r/argv"; mapfile -d '' -t envs < "$r/env"; cwd=$(cat "$r/cwd"; printf x); cwd=${cwd%x}
    if [ ! -d "$cwd" ]; then transport=cwd_missing
    else
      s=$SECONDS
      ( cd "$cwd" && exec timeout -k 5 "$limit" env -i "${envs[@]}" "${argv[@]}" ) < /dev/null > "$t/stdout" 2> "$t/stderr"; rc=$?
      if { [ "$rc" = 124 ] || [ "$rc" = 137 ]; } && [ "$((SECONDS - s))" -ge "$limit" ]; then transport=guest_limit; fi
    fi
  fi
  printf '%s' "$rc" > "$t/rc" || return 2
  printf 'run\t%s\njob\t%s\nargv\t%s\ncwd\t%s\nenv\t%s\ntransport\t%s\nrc\t%s\nstdout\t%s\nstderr\t%s\n' "$run" "$id" \
    "$(vm_guest_key "$r/meta" argv)" "$(vm_guest_key "$r/meta" cwd)" "$(vm_guest_key "$r/meta" env)" "$transport" "$rc" \
    "$(vm_guest_sha "$t/stdout")" "$(vm_guest_sha "$t/stderr")" > "$t/meta" || return 2
  mv "$t" "$q/resp/$id" || return 2 # 完了は rename の 1 回で公開する
}
vm_guest_loop() {
  local q=$1 run=$2 limit=$3 n=1 id
  while :; do
    id=$(printf '%06d' "$n")
    if [ ! -d "$q/req/$id" ]; then [ ! -e "$q/stop" ] || return 0; sleep 0.02; continue; fi
    vm_guest_job "$q" "$run" "$limit" "$id" || return 2
    n=$((n + 1))
  done
}
