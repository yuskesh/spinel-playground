#!/usr/bin/env bash
#
# k8s_oneshot.sh — Kubernetes の作法で eBPF probe を「注射して、計測して、抜く」1 コマンド。
#
# 気になった瞬間に、書き捨ての probe binary を `kubectl debug node/<node>` (privileged な
# sysadmin プロファイル) で作った debug pod へ `kubectl cp` で送り込み、`nsenter -t 1`
# でノードのホスト名前空間に入って有限時間だけ実行し、成果物を回収して debug pod ごと
# 撤収する。probe が pin しない限り、プロセス終了で BPF prog/link は自動 detach される
# ので、撤収後のクラスタはクリーンに戻る (spinel-ebpf E305)。
#
# 常駐 agent / DaemonSet は張らない。これは「ワンショット計測」の投下・抜去経路そのもの。
#
# 2 つの投下モード (E305 / E307):
#   (1) cp+nsenter モード (E305、既定): --binary で手元の probe ELF を kubectl cp し
#       nsenter -t 1 でホスト名前空間で実行する。ビルド環境 = ノードと同 arch/glibc が要る。
#   (2) image モード (E307): --probe-image で probe を焼いた OCI image を debug pod の
#       image として走らせる。cp 不要・pull 1 発・per-arch は image manifest で吸収。
#       image の ENTRYPOINT が実行モデル (pure=in-pod / hybrid=nsenter) を担う。probe の
#       AOT ネイティブ性 (自己完結バイナリ) を活かした配布形。
#
# 使い方:
#   tools/k8s_oneshot.sh --binary ./probe --seconds 30 [options] [-- <probe args>]   # cp+nsenter
#   tools/k8s_oneshot.sh --probe-image REF --mode hybrid --seconds 45 [options]      # image
#
# 主なオプション:
#   --binary PATH        (cp+nsenter モード) ノードのホスト側で実行する実行ファイル
#   --probe-image REF    (image モード) probe を焼いた container image。debug pod の image に。
#   --mode M             (image モード) SPNL_PROBE_MODE (recon|pure|hybrid、既定 hybrid)。
#   --seconds N          実行の timeout 秒数 (既定 30)
#   --max-events K       (E323) probe に SPNL_MAX_EVENTS=K を注入。emit/drain ベースの
#                        probe が K イベント取ったら自分で clean exit する (痕跡ゼロ)。
#                        --seconds と併用可 = whichever-first (時間 or 件数の先着)。
#   --env FILE           binary を起動する前に source する env ファイル (token 等)。
#                        中身はログに出さない。実行後にノードから削除する。
#   --file PATH[:NAME]   binary と一緒に注入する追加ファイル (繰り返し可)。
#                        probe args 内では @DIR@/NAME で参照できる。
#   --collect NAME[:DST] 実行後に run ディレクトリの NAME を DST に回収 (繰り返し可)。
#   --node NODE          対象ノード (既定: 最初の Ready ノード)
#   --image IMG          debug pod のイメージ (既定: busybox。nsenter/tar/timeout applet 必須)
#   --profile PROF       debug プロファイル (既定: sysadmin = privileged + host ns)
#   --pull-policy P      イメージ pull policy (既定: IfNotPresent — airgap 済なら pull 無し)
#   --log FILE           probe の stdout+stderr をここへ (既定: 標準出力)
#   --kubectl CMD        kubectl コマンド (既定: kubectl)
#   --keep               debug pod を残す (デバッグ用)
#   -- <probe args>      binary に渡す引数。@DIR@ は注入先ホストディレクトリに置換される。
#
# probe args の @DIR@ 置換により、追加ファイルや wire 出力先をホストパスで指定できる:
#   --binary ./driver --file probe.bpf.o --file uidmap.txt --collect wire.pb:/out/wire.pb \
#     -- "$EP" @DIR@/probe.bpf.o /etc/hostname /sys/fs/cgroup @DIR@/uidmap.txt @DIR@/wire.pb
#
set -euo pipefail

die() { echo "k8s_oneshot: $*" >&2; exit 1; }
log() { echo "[oneshot] $*" >&2; }

# ---- defaults ----
BINARY=""; SECONDS_RUN=30; ENVFILE=""; NODE=""; LOGFILE=""; MAX_EVENTS=""
IMAGE="docker.io/rancher/mirrored-library-busybox:1.37.0"
PROBE_IMAGE=""; PROBE_MODE="hybrid"
PROFILE="sysadmin"; PULL_POLICY="IfNotPresent"; KUBECTL="kubectl"; KEEP=0
FILES=(); COLLECTS=(); PROBE_ARGS=()

# ---- parse ----
while [ $# -gt 0 ]; do
  case "$1" in
    --binary)      BINARY="$2"; shift 2 ;;
    --probe-image) PROBE_IMAGE="$2"; shift 2 ;;
    --mode)        PROBE_MODE="$2"; shift 2 ;;
    --seconds)     SECONDS_RUN="$2"; shift 2 ;;
    --max-events)  MAX_EVENTS="$2"; shift 2 ;;
    --env)         ENVFILE="$2"; shift 2 ;;
    --file)        FILES+=("$2"); shift 2 ;;
    --collect)     COLLECTS+=("$2"); shift 2 ;;
    --node)        NODE="$2"; shift 2 ;;
    --image)       IMAGE="$2"; shift 2 ;;
    --profile)     PROFILE="$2"; shift 2 ;;
    --pull-policy) PULL_POLICY="$2"; shift 2 ;;
    --log)         LOGFILE="$2"; shift 2 ;;
    --kubectl)     KUBECTL="$2"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --)            shift; PROBE_ARGS=("$@"); break ;;
    *)             die "unknown option: $1" ;;
  esac
done

if [ -n "$PROBE_IMAGE" ]; then
  [ -z "$BINARY" ] || die "--binary and --probe-image are mutually exclusive (pick cp+nsenter OR image mode)"
else
  [ -n "$BINARY" ] || die "--binary (cp+nsenter) or --probe-image (image mode) is required"
  [ -f "$BINARY" ] || die "binary not found: $BINARY"
fi
[ -n "$ENVFILE" ] && { [ -f "$ENVFILE" ] || die "env file not found: $ENVFILE"; }

kc() { $KUBECTL "$@"; }

# ---- pick node ----
if [ -z "$NODE" ]; then
  NODE="$(kc get nodes -o jsonpath='{range .items[?(@.status.conditions[-1].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
  [ -n "$NODE" ] || NODE="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
fi
[ -n "$NODE" ] || die "no node found"
if [ -n "$PROBE_IMAGE" ]; then
  log "node=$NODE probe-image=$PROBE_IMAGE mode=$PROBE_MODE profile=$PROFILE seconds=$SECONDS_RUN"
else
  log "node=$NODE image=$IMAGE profile=$PROFILE seconds=$SECONDS_RUN"
fi

# 撤収し損ねた過去の debug pod (Succeeded/Failed) を掃除しておく (冪等性)
kc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | awk -v n="$NODE" '$2 ~ ("^node-debugger-" n "-") && ($3=="Succeeded"||$3=="Failed"){print $1, $2}' \
  | while read -r ns pod; do log "cleanup stale $ns/$pod"; kc delete pod -n "$ns" "$pod" --grace-period=1 --wait=false >/dev/null 2>&1 || true; done

# ======================================================================================
# image モード (E307): probe を焼いた image を debug pod の image として走らせる。
# cp+nsenter しない — image の ENTRYPOINT が実行モデル (SPNL_PROBE_MODE=recon|pure|hybrid)
# を担う。token は image に焼かず、非機微 env のみ debug pod に注入 (--env ファイル)。
# ======================================================================================
if [ -n "$PROBE_IMAGE" ]; then
  IPOD=""
  icleanup() {
    local rc=$?
    if [ -n "$IPOD" ] && [ "$KEEP" -eq 0 ]; then
      log "deleting debug pod $IPOD"
      kc delete pod "$IPOD" --grace-period=1 --wait=true --timeout=60s >/dev/null 2>&1 || true
    elif [ -n "$IPOD" ]; then
      log "--keep set; leaving pod $IPOD"
    fi
    return $rc
  }
  trap icleanup EXIT INT TERM

  # 非機微 env を --env KEY=VAL で注入 (token は含めない前提。含む場合は呼び出し側で弾く)。
  ENVARGS=(--env "SPNL_PROBE_MODE=$PROBE_MODE" --env "SPNL_PROBE_SECONDS=$SECONDS_RUN")
  [ -n "$MAX_EVENTS" ] && ENVARGS+=(--env "SPNL_MAX_EVENTS=$MAX_EVENTS")   # E323: event-boxed
  if [ -n "$ENVFILE" ]; then
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      ENVARGS+=(--env "$line")
    done < "$ENVFILE"
  fi

  DBG_TTL=$((SECONDS_RUN + 180))
  log "kubectl debug node/$NODE --image=$PROBE_IMAGE --profile=$PROFILE mode=$PROBE_MODE (image ENTRYPOINT)"
  DBG_OUT="$(kc debug "node/$NODE" --image="$PROBE_IMAGE" --profile="$PROFILE" \
               --image-pull-policy="$PULL_POLICY" --attach=false \
               "${ENVARGS[@]}" 2>&1 || true)"
  IPOD="$(printf '%s\n' "$DBG_OUT" | grep -oE 'node-debugger-[a-z0-9.-]+' | head -1 || true)"
  if [ -z "$IPOD" ]; then
    IPOD="$(kc get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
            | awk -v n="$NODE" '$2==n && $1 ~ /^node-debugger-/{print $1}' | tail -1)"
  fi
  [ -n "$IPOD" ] || { echo "$DBG_OUT" >&2; die "could not determine debug pod name (image mode)"; }
  log "debug pod = $IPOD"

  log "waiting for pod Running..."
  if ! kc wait --for=jsonpath='{.status.phase}'=Running "pod/$IPOD" --timeout=120s >/dev/null 2>&1; then
    phase="$(kc get pod "$IPOD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "$phase" != "Running" ] && [ "$phase" != "Succeeded" ]; then
      log "pod not Running; phase=${phase:-<none>}; recent events:"
      kc describe pod "$IPOD" 2>/dev/null | sed -n '/Events:/,$p' | head -25 >&2 || true
      die "debug pod $IPOD not Running (image import? scheduling? entrypoint?)"
    fi
  fi

  # probe (entrypoint) は timeout SECONDS で自己終了 → pod Succeeded/Failed。完了を待つ。
  log "waiting up to $((SECONDS_RUN + 60))s for probe to finish..."
  end=$(( $(date +%s) + SECONDS_RUN + 60 ))
  phase="Running"
  while [ "$(date +%s)" -lt "$end" ]; do
    phase="$(kc get pod "$IPOD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  log "probe pod phase=$phase"

  # stdout (entrypoint + probe) を回収
  if [ -n "$LOGFILE" ]; then
    kc logs "$IPOD" >"$LOGFILE" 2>&1 || true
    log "probe logs -> $LOGFILE"
  else
    kc logs "$IPOD" 2>&1 || true
  fi
  # cleanup は trap (EXIT) が pod 削除。RC は pod phase で決める。
  [ "$phase" = "Succeeded" ] && exit 0 || exit 1
fi

# 一意な run ディレクトリ (ホスト /tmp 上、debug pod からは /host/tmp 上に見える)
RUNID="spnl-oneshot-$$-$(date +%s)"
HOSTDIR="/tmp/$RUNID"           # ノードのホスト側から見たパス (nsenter 後)
PODDIR="/host/tmp/$RUNID"       # debug pod から見たパス (host / が /host に mount 済)

POD=""
cleanup() {
  local rc=$?
  if [ -n "$POD" ]; then
    # 注入物 (env の token 含む) をホストから削除してから pod を消す
    kc exec "$POD" -- rm -rf "$PODDIR" >/dev/null 2>&1 || true
    if [ "$KEEP" -eq 0 ]; then
      log "deleting debug pod $POD"
      kc delete pod "$POD" --grace-period=1 --wait=true --timeout=60s >/dev/null 2>&1 || true
    else
      log "--keep set; leaving pod $POD"
    fi
  fi
  return $rc
}
trap cleanup EXIT INT TERM

# ---- create debug pod (kubectl debug node/) ----
# --attach=false で detach 生成。command は seconds+buffer だけ sleep して自己終了させる
# (撤収漏れ時の保険)。生成メッセージ (stderr) から pod 名を拾う。
DBG_TTL=$((SECONDS_RUN + 180))
log "kubectl debug node/$NODE --profile=$PROFILE ..."
DBG_OUT="$(kc debug "node/$NODE" --image="$IMAGE" --profile="$PROFILE" \
             --image-pull-policy="$PULL_POLICY" --attach=false \
             -- sleep "$DBG_TTL" 2>&1 || true)"
POD="$(printf '%s\n' "$DBG_OUT" | grep -oE 'node-debugger-[a-z0-9.-]+' | head -1 || true)"
if [ -z "$POD" ]; then
  # フォールバック: 対象ノードの最新 node-debugger pod
  POD="$(kc get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
          | awk -v n="$NODE" '$2==n && $1 ~ /^node-debugger-/{print $1}' | tail -1)"
fi
[ -n "$POD" ] || { echo "$DBG_OUT" >&2; die "could not determine debug pod name"; }
log "debug pod = $POD"

log "waiting for pod Ready/Running..."
if ! kc wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1; then
  phase="$(kc get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" != "Running" ]; then
    log "pod not Ready; phase=${phase:-<none>}; recent events:"
    kc describe pod "$POD" 2>/dev/null | sed -n '/Events:/,$p' | head -25 >&2 || true
    die "debug pod $POD not Ready (image pull? scheduling? kubectl debug unsupported?)"
  fi
  log "pod phase=Running (no readiness gate)"
fi

# ---- inject binary + aux files via kubectl cp (into /host = node root fs) ----
kc exec "$POD" -- mkdir -p "$PODDIR" || die "mkdir in debug pod failed"
BINNAME="$(basename "$BINARY")"
log "kubectl cp $BINNAME -> node:$HOSTDIR/"
kc cp "$BINARY" "$POD:$PODDIR/$BINNAME" || die "kubectl cp binary failed"

for f in "${FILES[@]:-}"; do
  [ -n "$f" ] || continue
  src="${f%%:*}"; nm="${f#*:}"; [ "$nm" = "$f" ] && nm="$(basename "$src")"
  [ -f "$src" ] || die "aux file not found: $src"
  log "kubectl cp $nm"
  kc cp "$src" "$POD:$PODDIR/$nm" || die "kubectl cp $nm failed"
done

if [ -n "$ENVFILE" ]; then
  # token を含みうる env はファイルとして注入 (コマンドラインに載せない)
  kc cp "$ENVFILE" "$POD:$PODDIR/env" || die "kubectl cp env failed"
fi

# ---- @DIR@ 置換した probe args ----
SUBST_ARGS=()
for a in "${PROBE_ARGS[@]:-}"; do SUBST_ARGS+=("${a//@DIR@/$HOSTDIR}"); done

# ---- ホスト側で実行する runner を生成 (token はファイル経由・ログ非出力) ----
RUNNER="$(mktemp)"
{
  echo '#!/bin/sh'
  echo "set -a"
  echo "[ -f \"$HOSTDIR/env\" ] && . \"$HOSTDIR/env\""
  [ -n "$MAX_EVENTS" ] && echo "SPNL_MAX_EVENTS=$MAX_EVENTS"   # E323: event-boxed one-shot
  echo "set +a"
  echo "chmod +x \"$HOSTDIR/$BINNAME\" 2>/dev/null || true"
  echo "cd \"$HOSTDIR\""
  printf 'exec timeout %s "%s/%s"' "$SECONDS_RUN" "$HOSTDIR" "$BINNAME"
  for a in "${SUBST_ARGS[@]:-}"; do printf ' %q' "$a"; done
  printf '\n'
} > "$RUNNER"
kc cp "$RUNNER" "$POD:$PODDIR/run.sh" || die "kubectl cp runner failed"
rm -f "$RUNNER"

# ---- nsenter でホスト名前空間に入って実行 (有限時間) ----
log "nsenter -t 1 -m -u -i -n -p  timeout ${SECONDS_RUN}s  $BINNAME"
set +e
if [ -n "$LOGFILE" ]; then
  kc exec "$POD" -- nsenter -t 1 -m -u -i -n -p -- /bin/sh "$HOSTDIR/run.sh" >"$LOGFILE" 2>&1
  RUN_RC=$?
  log "probe exited rc=$RUN_RC (log: $LOGFILE)"
else
  kc exec "$POD" -- nsenter -t 1 -m -u -i -n -p -- /bin/sh "$HOSTDIR/run.sh"
  RUN_RC=$?
  log "probe exited rc=$RUN_RC"
fi
set -e

# ---- 成果物回収 ----
for c in "${COLLECTS[@]:-}"; do
  [ -n "$c" ] || continue
  nm="${c%%:*}"; dst="${c#*:}"; [ "$dst" = "$c" ] && dst="./$nm"
  if kc cp "$POD:$PODDIR/$nm" "$dst" >/dev/null 2>&1; then log "collected $nm -> $dst"; else log "collect $nm: not found"; fi
done

# cleanup は trap (EXIT) が pod 削除 + 注入物削除を実施
exit "$RUN_RC"
