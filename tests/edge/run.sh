#!/usr/bin/env bash
# tests/edge/run.sh -- the edge examples, built and run locally, each against
# the contract its own source documents.
#
#   sh tests/edge/run.sh
#
# Ported from spinel-llvm 463d49dd, where these examples had build scripts and
# a narrated demo but no checks. Every expectation below is the example's own
# documented contract (its header comment, its router's status table, its
# configuration), never a recorded output:
#
#   hello-http    the CGI contract: /info echoes path, query and method, /echo
#                 returns the body byte for byte, /fail is a 500 whose body is
#                 stderr
#   fetch-kv      /kv increments a KV counter (1, then 2); any other path
#                 fetches FETCH_URL (a local origin here) and reports it
#   r2-d1         an upload lands in R2 and D1 (303), is listed, is served back
#                 byte for byte, and is deleted from both
#   hello-fastly  the SAME program on Fastly (Viceroy) and Workers (workerd):
#                 /echo, /info and /kv answer byte for byte alike
#   gatekeeper    an admitted request runs the Ruby module; with a 20-token
#                 burst, the 21st rapid request of one identity is refused 429;
#                 a request the bot kernel blocks is 403; neither refusal runs
#                 the module
#   edge-twin     the device writes its 1048-row audit log under QEMU; the edge
#                 accepts it (200), catches three forgeries (409), answers a
#                 reading outside the domain with 422 and stays up; the device
#                 panics on the same reading and runs nothing after the trap
#
# Local only: workerd through `wrangler dev --local` (no account, no network),
# Viceroy for Fastly, QEMU for the device. Nothing is deployed.
#
# Requires LLVM_PREFIX, WASI_SYSROOT, WASI_BUILTINS, ZEPHYR_BASE and
# ZEPHYR_SDK_INSTALL_DIR, and wrangler, node, viceroy and west on PATH (VICEROY
# may name viceroy's path). A missing tool fails the run; nothing is skipped.
# The file is bash (arrays, here-strings). The documented command is `sh ...`,
# which is bash on macOS and dash on Debian, where the file is a syntax error.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
WORK=${EDGE_WORK:-${TMPDIR:-/tmp}/spinel-edge}
VICEROY=${VICEROY:-viceroy}
RUBY=${RUBY:-ruby}
: "${LLVM_PREFIX:?set LLVM_PREFIX}" "${WASI_SYSROOT:?set WASI_SYSROOT}" "${WASI_BUILTINS:?set WASI_BUILTINS}"
: "${ZEPHYR_BASE:?set ZEPHYR_BASE}" "${ZEPHYR_SDK_INSTALL_DIR:?set ZEPHYR_SDK_INSTALL_DIR}"
for t in wrangler node west "$VICEROY" curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "edge: no '$t' on PATH" >&2; exit 2; }
done
export EDGE_TWIN_BUILD=$WORK/edge-twin
rm -rf "$WORK"; mkdir -p "$WORK"

pass=0; fail=0; failed=""
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1"; echo "     got:  $(printf '%s' "$2" | head -c 300 | tr '\n' '|')"
       echo "     want: $(printf '%s' "$3" | head -c 300 | tr '\n' '|')"
       fail=$((fail + 1)); failed="$failed $1"; fi
}
yes_() { if "$@"; then echo yes; else echo no; fi; }

# ---- servers ----------------------------------------------------------------
PIDS=""
cleanup() {
  for p in $PIDS; do pkill -INT -P "$p" 2>/dev/null; kill -INT "$p" 2>/dev/null; done
  sleep 1
  for p in $PIDS; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  PIDS=""
}
trap cleanup EXIT
# A server that does not come up is a FAILURE, counted like any other: the
# checks behind it would otherwise be skipped without a word.
wait_up() {  # url log
  for _ in $(seq 1 60); do curl -s -m 2 -o /dev/null "$1" && return 0; sleep 1; done
  echo "FAIL nothing answered at $1; see $2"; tail -5 "$2" | sed 's/^/     /'
  fail=$((fail + 1)); failed="$failed serve:$1"; return 1
}
serve_workers() {  # dir port name
  (cd "$1" && exec wrangler dev --local --port "$2" --ip 127.0.0.1 \
     --persist-to "$WORK/state-$3" > "$WORK/$3.wrangler.log" 2>&1) &
  PIDS="$PIDS $!"; wait_up "http://127.0.0.1:$2/" "$WORK/$3.wrangler.log"
}
serve_origin() {  # the local origin both fetch-kv and hello-fastly reach
  node -e '
    require("http").createServer((q, s) => {
      s.writeHead(200, { "content-type": "text/plain" });
      s.end("origin probe body\n");
    }).listen(7899, "127.0.0.1");' > "$WORK/origin.log" 2>&1 &
  PIDS="$PIDS $!"; wait_up "http://127.0.0.1:7899/probe" "$WORK/origin.log"
}
build() {  # example [args]
  local e=$1; shift
  if ! bash "$REPO/examples/$e/build.sh" "$@" > "$WORK/$e.build.log" 2>&1; then
    echo "FAIL $e builds"; tail -5 "$WORK/$e.build.log" | sed 's/^/     /'
    fail=$((fail + 1)); failed="$failed $e-build"; return 1
  fi
  echo "ok   $e builds"; pass=$((pass + 1))
}
toml_vars() {  # file, then lines to put under [vars]
  local f=$1; shift
  "$RUBY" -e 'f = ARGV.shift; s = File.read(f)
    s.sub!(/^\[vars\]\n/) { "[vars]\n" + ARGV.map { |l| l + "\n" }.join } or abort "no [vars] in #{f}"
    File.write(f, s)' "$f" "$@"
}

serve_origin || exit 1

# ---- hello-http -------------------------------------------------------------
echo "== hello-http"
if build hello-http && serve_workers "$REPO/examples/hello-http/dist" 8801 hello-http; then
  U=http://127.0.0.1:8801
  ok "hello-http /info reports path, query, params and method" \
     "$(curl -s "$U/info?a=1&b=2")" \
     "$(printf 'path=/info\nquery=a=1&b=2\nparams=a:1,b:2\nmethod=GET\ncontent_type=nil\nbody_bytes=0')"
  ok "hello-http /echo returns the body byte for byte" \
     "$(curl -s -X POST --data-binary 'héllo bytes' "$U/echo" | od -An -tx1 | tr -d ' \n')" \
     "$(printf 'héllo bytes' | od -An -tx1 | tr -d ' \n')"
  ok "hello-http /fail is a 500" "$(curl -s -o /dev/null -w '%{http_code}' "$U/fail")" "500"
  ok "hello-http the 500's body is stderr" "$(curl -s "$U/fail")" "deliberate failure from /fail"
fi
cleanup; serve_origin

# ---- fetch-kv ---------------------------------------------------------------
echo "== fetch-kv"
if build fetch-kv; then
  # The bindings are added to a COPY: spinel-wasm keeps an existing
  # wrangler.toml, so editing dist/ in place would stack the keys run on run.
  D=$WORK/fetch-kv-dist
  cp -R "$REPO/examples/fetch-kv/dist" "$D"
  toml_vars "$D/wrangler.toml" 'SPINEL_HOST_KV = "MY_KV"' 'FETCH_URL = "http://127.0.0.1:7899/probe"'
  printf '\n[[kv_namespaces]]\nbinding = "MY_KV"\nid = "e0550e0550e0550e0550e0550e0550e0"\n' >> "$D/wrangler.toml"
  if serve_workers "$D" 8802 fetch-kv; then
    U=http://127.0.0.1:8802
    ok "fetch-kv /kv counts 1 on a fresh namespace" "$(curl -s "$U/kv")" "MY_KV.hits = 1"
    ok "fetch-kv /kv counts 2 the second time" "$(curl -s "$U/kv")" "MY_KV.hits = 2"
    ok "fetch-kv fetches the origin and reports it" "$(curl -s "$U/")" \
       "$(printf 'GET http://127.0.0.1:7899/probe\nstatus: 200\ntype:   text/plain\nbytes:  18\n\norigin probe body')"
  fi
fi
cleanup; serve_origin

# ---- r2-d1 --------------------------------------------------------------------
echo "== r2-d1"
if build r2-d1 && serve_workers "$REPO/examples/r2-d1/dist" 8803 r2-d1; then
  U=http://127.0.0.1:8803
  printf 'spinel r2 bytes\n\001\002\377' > "$WORK/asset.bin"
  ok "r2-d1 an upload answers 303" \
     "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "@$WORK/asset.bin" \
        "$U/upload?name=note.bin&type=application/octet-stream")" "303"
  page=$(curl -s "$U/")
  id=$(printf '%s' "$page" | grep -oE '/a/[0-9]+' | head -1)
  ok "r2-d1 the listing (D1) names the upload" "$(yes_ grep -q 'note.bin' <<<"$page")" "yes"
  ok "r2-d1 the asset (R2) comes back byte for byte" \
     "$(curl -s "$U$id" | od -An -tx1 | tr -d ' \n')" "$(od -An -tx1 < "$WORK/asset.bin" | tr -d ' \n')"
  ok "r2-d1 /orphans answers" "$(curl -s -o /dev/null -w '%{http_code}' "$U/orphans")" "200"
  ok "r2-d1 a delete answers 303" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$U$id/delete")" "303"
  ok "r2-d1 the deleted asset is gone from the listing" "$(yes_ grep -q 'note.bin' <<<"$(curl -s "$U/")")" "no"
fi
cleanup; serve_origin

# ---- hello-fastly -----------------------------------------------------------
echo "== hello-fastly"
if build hello-fastly; then
  D=$REPO/examples/hello-fastly
  (cd "$D/dist" && exec "$VICEROY" serve -C fastly.toml --addr 127.0.0.1:7676 bin/main.wasm \
     > "$WORK/hello-fastly.viceroy.log" 2>&1) &
  PIDS="$PIDS $!"
  if wait_up http://127.0.0.1:7676/ "$WORK/hello-fastly.viceroy.log" &&
     serve_workers "$D/dist-workers" 8804 hello-fastly; then
    for r in "/echo|POST" "/info?a=1&b=2|GET" "/kv|GET"; do
      p=${r%|*}; m=${r#*|}
      # A body only on POST: a GET with a body is not a well-formed request --
      # Fastly passes it through and Workers drops it -- and the example's
      # claim is about well-formed requests.
      if [ "$m" = POST ]; then body=(--data-binary 'same bytes é'); else body=(); fi
      f=$(curl -s -X "$m" -H 'X-Spinel-Probe: 1' ${body[@]+"${body[@]}"} "http://127.0.0.1:7676$p" | od -An -tx1 | tr -d ' \n')
      w=$(curl -s -X "$m" -H 'X-Spinel-Probe: 1' ${body[@]+"${body[@]}"} "http://127.0.0.1:8804$p" | od -An -tx1 | tr -d ' \n')
      ok "hello-fastly $p is byte-identical on Fastly and Workers" "$f" "$w"
      [ -n "$f" ] || ok "hello-fastly $p answered at all" "empty" "a body"
    done
    ok "hello-fastly /echo returns the body on Fastly" \
       "$(curl -s -X POST --data-binary 'same bytes é' http://127.0.0.1:7676/echo)" "same bytes é"
  fi
fi
cleanup; serve_origin

# ---- gatekeeper -------------------------------------------------------------
echo "== gatekeeper"
if build gatekeeper && serve_workers "$REPO/examples/gatekeeper/dist" 8805 gatekeeper; then
  U=http://127.0.0.1:8805
  h=$WORK/gk.h
  code=$(curl -s -D "$h" -o /dev/null -w '%{http_code}' -A 'Mozilla/5.0 (spinel test)' \
         -H 'x-user-id: alice' -H 'accept: text/html' -H 'accept-language: en' "$U/api/me")
  ok "gatekeeper admits an ordinary request" "$code" "200"
  ok "gatekeeper an admitted request ran the Ruby module (x-spinel-exit)" \
     "$(yes_ grep -qi '^x-spinel-exit:' "$h")" "yes"
  first=""; limited=0; limited_ran=0
  for i in $(seq 1 25); do
    c=$(curl -s -D "$h" -o /dev/null -w '%{http_code}' -A 'Mozilla/5.0 (spinel test)' \
        -H 'x-user-id: flood' -H 'accept: text/html' -H 'accept-language: en' "$U/")
    if [ "$c" = 429 ]; then
      limited=$((limited + 1)); [ -n "$first" ] || first=$i
      grep -qi '^x-gate-app-run: 0' "$h" || limited_ran=$((limited_ran + 1))
      grep -qi '^retry-after:' "$h" || limited_ran=$((limited_ran + 1))
    fi
  done
  ok "gatekeeper the first 20 rapid requests of one identity pass (burst 20)" \
     "$([ -n "$first" ] && [ "$first" -gt 20 ] && echo yes || echo "no (first 429 at ${first:-never})")" "yes"
  ok "gatekeeper later rapid requests are refused 429" "$([ "$limited" -gt 0 ] && echo yes || echo no)" "yes"
  ok "gatekeeper every 429 has Retry-After and did not run the module" "$limited_ran" "0"
  # Built from kern.rb's bot_score weights, with no dependence on timing: no
  # User-Agent (+30), a path over 120 bytes (+10), a query over 512 bytes (+15)
  # and a POST (+5) make 60, the threshold. It is this identity's first
  # request, so the gap terms do not apply. 403 exactly when score >= 60.
  code=$(curl -s -D "$h" -o "$WORK/gk.bot" -w '%{http_code}' -A '' -X POST \
         -H 'x-user-id: bot' "$U/$(printf 'x%.0s' $(seq 1 200))?$(printf 'q=1&%.0s' $(seq 1 140))")
  score=$(grep -i '^x-gate-score:' "$h" | tr -dc '0-9')
  ok "gatekeeper a bot-shaped request is refused 403" "$code" "403"
  ok "gatekeeper the 403 carries a score at or above the threshold" \
     "$([ -n "$score" ] && [ "$score" -ge 60 ] && echo yes || echo "no (score '${score}')")" "yes"
  ok "gatekeeper the 403 did not run the module" "$(yes_ grep -qi '^x-gate-app-run: 0' "$h")" "yes"
fi
cleanup

# ---- edge-twin ----------------------------------------------------------------
echo "== edge-twin"
if build edge-twin && serve_workers "$REPO/examples/edge-twin/dist" 8806 edge-twin; then
  U=http://127.0.0.1:8806
  qemu_run() {  # build dir, log, sentinel
    rm -f "$1/qemu.pid"
    (west build -d "$1" -t run > "$2" 2>&1) &
    local pid=$!
    for _ in $(seq 1 240); do grep -q "$3" "$2" 2>/dev/null && break; kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    [ -f "$1/qemu.pid" ] && kill "$(cat "$1/qemu.pid")" 2>/dev/null
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$1/qemu.pid"
  }
  LOG=$WORK/audit_device.log
  qemu_run "$EDGE_TWIN_BUILD/dev-m33" "$WORK/qemu.log" '#final'
  grep '^E067	' "$WORK/qemu.log" | cut -f2- | tr -d '\r' > "$LOG"
  # 1048 data rows; the log also carries a `#edge-twin` header and a `#final` trailer.
  ok "edge-twin the device writes its 1048-row audit log" "$(grep -vc '^#' "$LOG")" "1048"
  post() { curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "@$1" "$U/audit"; }
  ok "edge-twin the edge accepts the device's log (200)" "$(post "$LOG")" "200"
  forge() { "$RUBY" "$REPO/examples/tools/forge.rb" "$LOG" "$WORK/$1.log" "$2" >/dev/null; post "$WORK/$1.log"; }
  ok "edge-twin a raised reading is caught (409)" \
     "$(forge t1 'B[500][1] = (Integer(B[500][1], 10) + 1).to_s')" "409"
  ok "edge-twin a relabelled alarm is caught (409)" \
     "$(forge t2 'i = B.each_index.select { |j| B[j][2] == "2" }[1]; B[i][2] = "0"')" "409"
  ok "edge-twin a deleted, renumbered row is caught (409)" \
     "$(forge t3 'B.delete_at(300)
(300...B.size).each { |j| B[j][0] = j.to_s }')" "409"
  ok "edge-twin a reading outside the domain is 422 at the edge" \
     "$(forge x1 'B[900][1] = "2000000000"')" "422"
  ok "edge-twin the worker is still serving after the trap" \
     "$(curl -s -o /dev/null -w '%{http_code}' "$U/probe?x=25000")" "200"
  qemu_run "$EDGE_TWIN_BUILD/dev-trap" "$WORK/qemu_trap.log" 'Faulting instruction\|PANIC\|Halting'
  ok "edge-twin the device panics on the same reading" \
     "$(yes_ grep -qE 'Faulting instruction|PANIC|Halting' "$WORK/qemu_trap.log")" "yes"
  ok "edge-twin nothing ran on the device after the trap" \
     "$(yes_ grep -q '#UNREACHABLE' "$WORK/qemu_trap.log")" "no"
fi
cleanup

echo
echo "edge: $pass passed, $fail failed"
[ "$fail" = 0 ] || { echo "edge: failed:$failed"; exit 1; }
