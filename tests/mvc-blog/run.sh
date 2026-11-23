#!/usr/bin/env bash
#
# tests/mvc-blog/run.sh — examples/mvc-blog, native and on local workerd.
#
#   bash tests/mvc-blog/run.sh
#
# Needs LLVM_PREFIX, vendor/spinel built, and for the Workers half what
# tests/edge/run.sh needs for spinel-wasm (WASI_SYSROOT, WASI_BUILTINS) plus
# wrangler, node and curl on PATH. Without wrangler the Workers half SKIPs.
#
#   native   the program is a CGI executable: ARGV = path and query, stdin =
#            the form body, ENV = the CGI variables. MVC_NATIVE_KV turns on the
#            example's KV test double, so posts persist across processes.
#   workerd  the same app.rb through spinel-wasm --emit-worker --host-api,
#            served by `wrangler dev --local`: once with a KV binding (posts
#            persist across requests, which are separate instances) and once
#            without (each request starts empty, and the footer says so).
#
# The expectations are the app's documented behaviour. Exit 0 when everything
# passed, 1 on any failure, 2 when nothing failed but something was skipped.
set -u

REPO=$(cd -- "$(dirname -- "$0")/../.." && pwd)
APP="$REPO/examples/mvc-blog"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mvc-blog-test.XXXXXX")
RUBY=${RUBY:-ruby}
pass=0; fail=0; skip=0
PIDS=""
cleanup() {
  for p in $PIDS; do pkill -INT -P "$p" 2>/dev/null; kill -INT "$p" 2>/dev/null; done
  sleep 1
  for p in $PIDS; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  PIDS=""
}
trap 'cleanup; rm -rf "$WORK"' EXIT

ok() {  # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then echo "PASS  $name"; pass=$((pass + 1))
  else echo "FAIL  $name"; fail=$((fail + 1)); fi
}
has() { grep -qiF -- "$2" <<<"$1"; }   # header names are case-insensitive
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
TITLE='日本語 <script>alert(1)</script>'
TITLE_ENC='%E6%97%A5%E6%9C%AC%E8%AA%9E+%3Cscript%3Ealert%281%29%3C%2Fscript%3E'
ESCAPED='日本語 &lt;script&gt;alert(1)&lt;/script&gt;'
LONG=$(printf 'a%.0s' $(seq 1 81))

echo "== native"
[ -x "$REPO/vendor/spinel/bin/spinel" ] || { echo "---- mvc-blog: SKIP (build vendor/spinel first)"; exit 2; }
if "$REPO/vendor/spinel/bin/spinel" "$APP/app.rb" -I "$APP/native" -o "$WORK/mvc" >"$WORK/native.log" 2>&1; then
  echo "PASS  app.rb builds natively"; pass=$((pass + 1))
  export SPINEL_CGI_HEADERS=1 MVC_NATIVE_KV="$WORK/kv.txt" SPINEL_HOST_KV=MY_KV
  get()  { REQUEST_METHOD=GET "$WORK/mvc" "$1" ''; }
  post() { printf '%s' "$2" | REQUEST_METHOD=POST CONTENT_TYPE=application/x-www-form-urlencoded "$WORK/mvc" "$1" ''; }
  r=$(get /);                                ok "GET / redirects to /posts" has "$r" $'Status: 303'
                                             ok "  with Location: /posts" has "$r" 'Location: /posts'
  r=$(post /posts "title=$TITLE_ENC&body=line1%0Aline2"); ok "POST /posts creates post 1" has "$r" 'Location: /posts/1'
  r=$(post /posts 'title=second&body=hello'); ok "a second POST gets id 2" has "$r" 'Location: /posts/2'
  r=$(get /posts);                           ok "GET /posts lists both, the title escaped" has "$r" "$ESCAPED"
                                             ok "  and never raw" hasnt "$r" '<script>alert'
                                             ok "  the footer counts 2 in the KV store" has "$r" 'store: kv:MY_KV / posts: 2'
  r=$(get /posts/1);                         ok "GET /posts/1 turns the newline into <br>" has "$r" 'line1<br>'
  r=$(post /posts '');                       ok "an empty POST is refused with 422" has "$r" 'Status: 422'
  r=$(post /posts "title=$LONG&body=x");     ok "an 81-character title is refused with 422" has "$r" 'Status: 422'
  r=$(post /posts/1/delete '');              ok "POST /posts/1/delete redirects to /posts" has "$r" 'Location: /posts'
  r=$(get /posts);                           ok "  and the list counts 1" has "$r" 'store: kv:MY_KV / posts: 1'
  r=$(get /posts/1);                         ok "the deleted post is 404" has "$r" 'Status: 404'
  get /nope >"$WORK/nope.out"; rc=$?
  ok "an unknown path is 404 with exit 0" test "$rc" = 0 -a -n "$(grep -F 'Status: 404' "$WORK/nope.out")"
  ok "the KV double holds the record encoding" grep -qF $'MY_KV\tposts:2\ttitle=second%0Abody=hello%0A' "$WORK/kv.txt"
  unset MVC_NATIVE_KV SPINEL_HOST_KV
else
  echo "FAIL  app.rb builds natively"; sed 's/^/      /' "$WORK/native.log" | tail -5; fail=$((fail + 1))
fi

echo "== workerd"
missing=""
for t in wrangler node curl; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  echo "SKIP  workerd: not on PATH:$missing"; skip=$((skip + 1))
elif ! bash "$APP/build.sh" >"$WORK/wasm.log" 2>&1; then
  echo "FAIL  app.rb builds for Workers"; sed 's/^/      /' "$WORK/wasm.log" | tail -5; fail=$((fail + 1))
else
  echo "PASS  app.rb builds for Workers (spinel-wasm --emit-worker --host-api)"; pass=$((pass + 1))
  wait_up() {  # url log
    for _ in $(seq 1 60); do curl -s -m 2 -o /dev/null "$1" && return 0; sleep 1; done
    echo "FAIL  nothing answered at $1"; tail -5 "$2" | sed 's/^/      /'; fail=$((fail + 1)); return 1
  }
  serve() {  # dir port name
    (cd "$1" && exec wrangler dev --local --port "$2" --ip 127.0.0.1 \
       --persist-to "$WORK/state-$3" > "$WORK/$3.log" 2>&1) &
    PIDS="$PIDS $!"; wait_up "http://127.0.0.1:$2/" "$WORK/$3.log"
  }
  # Bindings go into COPIES of dist/, so the tracked wrangler.toml never changes.
  D="$WORK/kv-dist"; cp -R "$APP/dist" "$D"
  "$RUBY" -e 'f = ARGV[0]; s = File.read(f)
    s.sub!(/^\[vars\]\n/) { "[vars]\nSPINEL_HOST_KV = \"MVC_KV\"\n" } or abort "no [vars]"
    File.write(f, s + "\n[[kv_namespaces]]\nbinding = \"MVC_KV\"\nid = \"mvc_local\"\n")' "$D/wrangler.toml"
  if serve "$D" 8811 kv; then
    U=http://127.0.0.1:8811
    r=$(curl -s -i "$U/");                  ok "workerd: GET / is 303 to /posts" has "$r" 'location: /posts'
    r=$(curl -s -i -X POST "$U/posts" -H 'content-type: application/x-www-form-urlencoded' \
         --data-raw "title=$TITLE_ENC&body=line1%0Aline2")
                                             ok "workerd: POST creates post 1" has "$r" 'location: /posts/1'
    r=$(curl -s -i -X POST "$U/posts" -H 'content-type: application/x-www-form-urlencoded' --data-raw 'title=second&body=x')
                                             ok "workerd: a second POST gets id 2" has "$r" 'location: /posts/2'
    r=$(curl -s "$U/posts");                ok "workerd: a later request sees both posts (KV persists)" has "$r" 'store: kv:MVC_KV / posts: 2'
                                             ok "workerd: the title is escaped" has "$r" "$ESCAPED"
    r=$(curl -s "$U/posts/1");              ok "workerd: GET /posts/1 turns the newline into <br>" has "$r" 'line1<br>'
    r=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$U/posts" -H 'content-type: application/x-www-form-urlencoded' --data-raw '')
                                             ok "workerd: an empty POST is 422" test "$r" = 422
    r=$(curl -s -o /dev/null -w '%{http_code}' "$U/nope"); ok "workerd: an unknown path is 404" test "$r" = 404
    r=$(curl -s -i -X POST "$U/posts/1/delete"); ok "workerd: delete redirects to /posts" has "$r" 'location: /posts'
    r=$(curl -s "$U/posts");                ok "workerd: the list then counts 1" has "$r" 'store: kv:MVC_KV / posts: 1'
    r=$(curl -s -o /dev/null -w '%{http_code}' -I "$U/posts"); ok "workerd: HEAD /posts is 200" test "$r" = 200
  fi
  cleanup
  if serve "$APP/dist" 8812 nokv; then
    U=http://127.0.0.1:8812
    for n in 1 2; do
      r=$(curl -s -i -X POST "$U/posts" -H 'content-type: application/x-www-form-urlencoded' --data-raw 'title=t&body=b')
      ok "workerd without KV: POST $n gets id 1 again (nothing persists)" has "$r" 'location: /posts/1'
    done
    r=$(curl -s "$U/posts");                ok "workerd without KV: the footer says memory, 0 posts" has "$r" 'store: memory / posts: 0'
  fi
  cleanup
fi

echo "---- mvc-blog: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
[ "$skip" = 0 ] || exit 2
