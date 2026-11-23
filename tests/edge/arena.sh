#!/usr/bin/env bash
#
# tests/edge/arena.sh -- the arena wasm build (spinel-wasm --request-arena),
# which has no collector (upstream --gc=none).
#
#   bash tests/edge/arena.sh
#
# Needs what tests/edge/run.sh needs for spinel-wasm (LLVM_PREFIX, WASI_SYSROOT,
# WASI_BUILTINS), plus node, and wrangler and curl for the workerd rows.
#
#   1. hello-http as an arena module on local workerd: the four hello-http rows
#      of tests/edge/run.sh.
#   2. Semantics across setjmp/longjmp, under the arena's one-slot root stack:
#      catch/throw and raise/rescue that update a String local and an Integer
#      local must print Ruby's values, written here by hand. The Integer
#      catch/throw case was a known upstream defect until the 2026-11-14
#      upstream synchronisation (it printed 0 on the ordinary build too); it
#      is now an ordinary check on both builds.
#   3. Memory: hello-http, one request under node:wasi, at most MAX_PAGES pages
#      after the request, with no SPINEL_GC_SLAB in the environment (the arena
#      build turns the slab off itself). The control: SPINEL_GC_SLAB=1 must
#      exceed the bound, or the bound proves nothing.
#   4. The arena tier's GC-semantics refusal (spinel-capcheck, E093): GC.start
#      and ObjectSpace are refused at build time, through --request-arena and
#      through '# spinel-tier: arena'.
#   5. Instance reuse (decision 0039), through tests/edge/snapshot.mjs: the
#      contract in the module and its --no-snapshot control, one instance for
#      many requests and for requests arriving together, the instance let go
#      after its memory grows past 16 MiB, and a new instance for a request
#      that arrives while another waits on the host.
#
# Exit 0 when everything passed, 1 on any failure, 2 when something was skipped.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/edge-arena.XXXXXX")
DRV="$REPO/tools/wasm/spinel-wasm"
RUN=(node --experimental-wasm-exnref "$HERE/arena_run.mjs")
MAX_PAGES=8     # 512 KiB; measured 2026-11-01 at pin ed8c753a4: 7 pages before, 8 after
export BUILD_DIR="$W/build"
: "${LLVM_PREFIX:?set LLVM_PREFIX}" "${WASI_SYSROOT:?set WASI_SYSROOT}" "${WASI_BUILTINS:?set WASI_BUILTINS}"
command -v node >/dev/null 2>&1 || { echo "---- arena: SKIP (no node)"; exit 2; }

pass=0; fail=0; skip=0; known=0
PID=""
cleanup() {
  [ -z "$PID" ] || { pkill -INT -P "$PID" 2>/dev/null; kill -INT "$PID" 2>/dev/null; sleep 1
                     pkill -KILL -P "$PID" 2>/dev/null; kill -KILL "$PID" 2>/dev/null; }
  rm -rf "$W"
}
trap cleanup EXIT
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass + 1))
  else echo "FAIL  $1"; echo "      got:  $(printf '%s' "$2" | head -c 300 | tr '\n' '|')"
       echo "      want: $(printf '%s' "$3" | head -c 300 | tr '\n' '|')"; fail=$((fail + 1)); fi
}
build() {  # rb wasm [args]: 0 when it builds
  local rb=$1 out=$2; shift 2
  "$DRV" "$rb" -o "$out" "$@" > "$out.log" 2>&1
}
out_of() { "${RUN[@]}" "$@" 2>/dev/null; }
pages_after() { "${RUN[@]}" "$@" 2>&1 >/dev/null | sed -n 's/^pages before=[0-9]* after=\([0-9]*\).*/\1/p'; }

echo "== semantics under the arena's one-slot root stack"
printf 's = "a"\ncatch(:done) { s = s + "b"; throw :done }\np s\n' > "$W/catch_str.rb"
printf 's = "a"\nbegin\n  s = s + "b"\n  raise "x"\nrescue\n  s = s + "c"\nend\np s\n' > "$W/rescue_str.rb"
printf 'i = 0\nbegin\n  i += 1\n  raise "x"\nrescue\n  i += 1\nend\np i\n' > "$W/rescue_int.rb"
printf 'i = 0\ncatch(:done) { i += 1; throw :done }\np i\n' > "$W/catch_int.rb"
for c in 'catch_str:"ab"' 'rescue_str:"abc"' 'rescue_int:2'; do
  n=${c%%:*}; want=${c#*:}
  if build "$W/$n.rb" "$W/$n.wasm" --request-arena; then
    ok "arena: $n prints $want" "$(out_of "$W/$n.wasm")" "$want"
  else
    ok "arena: $n builds" "$(tail -3 "$W/$n.wasm.log")" "(built)"
  fi
done
# An Integer local updated inside catch and read after throw: until the
# 2026-11-14 upstream synchronisation the generated C set the non-volatile lv_i
# after setjmp and read it after longjmp, and it printed 0 on both builds (a
# known upstream defect). Upstream f8ff01939 prints Ruby's 1 on both, so it is
# now checked like the cases above, on the arena build and the ordinary one.
if build "$W/catch_int.rb" "$W/catch_int.wasm" --request-arena; then
  ok "arena: catch_int prints 1" "$(out_of "$W/catch_int.wasm")" 1
else
  ok "arena: catch_int builds" "$(tail -3 "$W/catch_int.wasm.log")" "(built)"
fi
if build "$W/catch_int.rb" "$W/catch_int_full.wasm"; then
  ok "ordinary build: catch_int prints 1" "$(out_of "$W/catch_int_full.wasm")" 1
else
  ok "ordinary build: catch_int builds" "$(tail -3 "$W/catch_int_full.wasm.log")" "(built)"
fi

echo "== memory"
if build "$REPO/examples/hello-http/app.rb" "$W/hh.wasm" --request-arena; then
  a=$(pages_after "$W/hh.wasm" /info 'a=1&b=2')
  ok "hello-http arena: at most $MAX_PAGES pages after one request (got ${a:-none})" \
     "$([ -n "$a" ] && [ "$a" -le "$MAX_PAGES" ] && echo yes || echo no)" yes
  c=$(SPINEL_GC_SLAB=1 pages_after "$W/hh.wasm" /info 'a=1&b=2')
  ok "control: SPINEL_GC_SLAB=1 overrides the default and exceeds the bound (got ${c:-none})" \
     "$([ -n "$c" ] && [ "$c" -gt "$MAX_PAGES" ] && echo yes || echo no)" yes
else
  ok "hello-http builds as an arena module" "$(tail -3 "$W/hh.wasm.log")" "(built)"
fi

echo "== instance reuse (decision 0039)"
mkdir -p "$W/snap"
printf 'puts ("x" * ARGV[1].to_i).bytesize\n' > "$W/big.rb"
printf 'require "edge/http"\nr = Edge::HTTP.get(ENV["FETCH_URL"].to_s)\nputs "#{ARGV[0]} #{r.status} #{r.body}"\n' > "$W/wait.rb"
ok "--no-snapshot without the arena tier is refused" \
   "$("$DRV" "$W/big.rb" -o "$W/no.wasm" --no-snapshot 2>&1 >/dev/null | grep -c 'applies to an arena build only')" 1
if build "$REPO/examples/hello-http/app.rb" "$W/snap/hh.wasm" --request-arena \
   && build "$REPO/examples/hello-http/app.rb" "$W/snap/hh-no.wasm" --request-arena --no-snapshot \
   && build "$W/big.rb" "$W/snap/big.wasm" --request-arena \
   && build "$W/wait.rb" "$W/snap/wait.wasm" --request-arena --host-api; then
  node --experimental-wasm-exnref "$HERE/snapshot.mjs" "$W/snap" > "$W/snap.txt" 2>&1
  grep -v 'ExperimentalWarning\|--trace-warnings' "$W/snap.txt" | grep -v '^---- snapshot:'
  pass=$((pass + $(grep -c '^PASS' "$W/snap.txt"))); fail=$((fail + $(grep -c '^FAIL' "$W/snap.txt")))
  grep -q '^---- snapshot: ' "$W/snap.txt" || { echo "FAIL  snapshot.mjs ran to its end"; tail -5 "$W/snap.txt"; fail=$((fail + 1)); }
else
  ok "the reuse test programs build" "$(tail -3 "$W"/snap/*.log 2>/dev/null)" "(built)"
fi

echo "== GC-semantics refusal (E093)"
printf 'GC.start\nputs "ran"\n' > "$W/gc.rb"
printf 'puts ObjectSpace.count_objects.size\n' > "$W/os.rb"
printf '# spinel-tier: arena\nGC.start\nputs "ran"\n' > "$W/gc_tier.rb"
for n in gc os gc_tier; do
  args=(--request-arena); [ "$n" = gc_tier ] && args=()
  build "$W/$n.rb" "$W/$n.wasm" "${args[@]}"; rc=$?
  r=$(grep -c '^spinel-capcheck: REJECT arena-gc-semantics' "$W/$n.wasm.log")
  ok "$n.rb is refused at build time (rc=$rc, REJECT lines=$r)" \
     "$([ "$rc" != 0 ] && [ "$r" -ge 1 ] && [ ! -f "$W/$n.wasm" ] && echo yes || echo no)" yes
done

echo "== hello-http on workerd, as an arena module"
if ! command -v wrangler >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "SKIP  workerd rows: no wrangler or curl"; skip=$((skip + 1))
elif ! "$DRV" "$REPO/examples/hello-http/app.rb" --emit-worker "$W/dist" --request-arena > "$W/dist.log" 2>&1; then
  ok "hello-http --emit-worker --request-arena" "$(tail -3 "$W/dist.log")" "(built)"
else
  (cd "$W/dist" && exec wrangler dev --local --port 8831 --ip 127.0.0.1 --persist-to "$W/state" > "$W/wrangler.log" 2>&1) &
  PID=$!
  U=http://127.0.0.1:8831; up=0
  for _ in $(seq 1 60); do curl -s -m 2 -o /dev/null "$U/" && { up=1; break; }; sleep 1; done
  if [ "$up" = 1 ]; then
    ok "hello-http /info reports path, query, params and method" "$(curl -s "$U/info?a=1&b=2")" \
       "$(printf 'path=/info\nquery=a=1&b=2\nparams=a:1,b:2\nmethod=GET\ncontent_type=nil\nbody_bytes=0')"
    ok "hello-http /echo returns the body byte for byte" \
       "$(curl -s -X POST --data-binary 'héllo bytes' "$U/echo" | od -An -tx1 | tr -d ' \n')" \
       "$(printf 'héllo bytes' | od -An -tx1 | tr -d ' \n')"
    ok "hello-http /fail is a 500" "$(curl -s -o /dev/null -w '%{http_code}' "$U/fail")" "500"
    ok "hello-http the 500's body is stderr" "$(curl -s "$U/fail")" "deliberate failure from /fail"
  else
    ok "workerd answers" "$(tail -3 "$W/wrangler.log")" "(up)"
  fi
fi

echo "---- arena: $pass passed, $fail failed, $known known defect(s), $skip skipped"
[ "$fail" = 0 ] || exit 1
[ "$skip" = 0 ] || exit 2
