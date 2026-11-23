#!/bin/sh
# E456 (P013): gpu-metal codegen gate (container, text asserts — the Metal
# EXECUTION harness is run_gpu_metal_exec.sh on a macOS host). Same shape as
# run_amp_codegen.sh: build the in-process codegen, emit via SPNL_GPU_METAL=1,
# grep the positive shape, and require the negative cases to die NAMING the
# problem (ADR-003 loud failure).
set -u

METAL=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(cd "$METAL/../ebpf" && pwd)
ICC="$REPO_ROOT/build/codegen_c/spinel-ebpf-cc"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# spinel-ebpf links the in-process codegen when it first needs it.
if [ ! -x "$ICC" ]; then
  sh "$METAL/spinel-metal" compile "$METAL/examples/saxpy.rb" -o "$TMP/seed" >/dev/null || exit 1
fi
fail=0

# unit base = file basename (the host-binding accessor prefix derives from it)
emit() { SPNL_GPU_METAL=1 "$ICC" "$1" "$(basename "$1" .rb)" 2>"$TMP/err"; }

# ---- positive: the shipped example lowers to the expected MSL shape ----
if out=$(emit "$METAL/examples/saxpy.rb"); then
  for needle in "kernel void saxpy" "[[thread_position_in_grid]]" \
                "device const float \*x \[\[buffer(0)\]\]" \
                "device float \*out \[\[buffer(2)\]\]" "2.5f"; do
    if ! printf '%s' "$out" | grep -q "$needle"; then
      echo "FAIL: saxpy.metal missing: $needle"; fail=1
    fi
  done
  echo "  ok: saxpy.rb -> MSL kernel (const/written buffers, gid, float literal)"
  # E458: the .metal carries its host binding, direction-shaped -- setters only
  # for loaded slots, getters only for stored ones.
  for needle in "SPNL_GPU_HOST_BEGIN" "def saxpy_x_set" "def saxpy_y_set" \
                "def saxpy_out_get" "def saxpy_dispatch" "def saxpy_gpu_init" '"fff"'; do
    if ! printf '%s' "$out" | grep -q "$needle"; then
      echo "FAIL: host binding missing: $needle"; fail=1
    fi
  done
  for absent in "def saxpy_out_set" "def saxpy_x_get" "def saxpy_y_get"; do
    if printf '%s' "$out" | grep -q "$absent"; then
      echo "FAIL: host binding has the wrong-direction accessor: $absent"; fail=1
    fi
  done
  echo "  ok: host binding embedded, direction-shaped (in->set only, out->get only)"
else
  echo "FAIL: saxpy.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: E459 :int buffers -> device __s64, "ll" spec, _i accessor lane ----
if out=$(emit "$METAL/examples/scale.rb"); then
  for needle in "device const __s64 \*v \[\[buffer(0)\]\]" '"ll"' \
                "GPU.ogpu_write_i(0" "GPU.ogpu_read_i(1"; do
    if ! printf '%s' "$out" | grep -q "$needle"; then
      echo "FAIL: scale.metal missing: $needle"; fail=1
    fi
  done
  echo "  ok: :int buffers -> __s64 + integer FFI lane"
else
  echo "FAIL: scale.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: anonymous mode (no declarations) still works, float fixed ----
cat > "$TMP/anon.rb" <<'EOF'
def kernel__anon
  i = gpu_global_id
  gpu_store(1, i, gpu_load(0, i) * 2.0)
end
EOF
if out=$(emit "$TMP/anon.rb"); then
  printf '%s' "$out" | grep -q "device const float \*_b0" || { echo "FAIL: anonymous mode lost _b0"; fail=1; }
  echo "  ok: anonymous slot-literal mode unchanged (float, _bN)"
else
  echo "FAIL: anon.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: float local typing (the E456 delta over the integer lowering) ----
cat > "$TMP/ftyped.rb" <<'EOF'
def kernel__ft
  i = gpu_global_id
  v = gpu_load(0, i) * 2.0
  s = i + 1
  gpu_store(1, i, v + s)
end
EOF
if out=$(emit "$TMP/ftyped.rb"); then
  printf '%s' "$out" | grep -q "float v = 0.0f;" || { echo "FAIL: float local not typed float"; fail=1; }
  printf '%s' "$out" | grep -q "__s64 s = 0;"    || { echo "FAIL: int local lost __s64"; fail=1; }
  echo "  ok: locals typed by first write (float v / __s64 s)"
else
  echo "FAIL: ftyped.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: the loop kernel (E466) -- n.times lowers to a plain MSL for,
# for both spellings (literal and computed bound); the block param is the
# scoped loop variable and reads type as an integer inside float expressions ----
if out=$(emit "$METAL/examples/poly.rb"); then
  printf '%s' "$out" | grep -q "for (__s64 j = 0; j < (__s64)(8); j++) {" \
    || { echo "FAIL: poly.metal: literal 8.times did not lower to an MSL for"; fail=1; }
  printf '%s' "$out" | grep -q "bpf_loop" && { echo "FAIL: poly.metal contains bpf_loop -- the linux lowering leaked"; fail=1; }
  echo "  ok: poly.rb -> MSL for loop (no callback machinery)"
else
  echo "FAIL: poly.rb did not emit"; cat "$TMP/err"; fail=1
fi
cat > "$TMP/varloop.rb" <<'EOF'
gpu_buffer :x, :float, 0
gpu_buffer :y, :float, 1

def kernel__vl
  i = gpu_global_id
  n = 3 + 2
  acc = 0.0
  n.times do |j|
    acc = acc + j
  end
  gpu_store(:y, i, acc + gpu_load(:x, i))
end
EOF
if out=$(emit "$TMP/varloop.rb"); then
  printf '%s' "$out" | grep -q "for (__s64 j = 0; j < (__s64)(n); j++) {" \
    || { echo "FAIL: varloop: computed bound did not lower to an MSL for"; fail=1; }
  echo "  ok: computed-bound n.times -> the same MSL for (no callback split)"
else
  echo "FAIL: varloop.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: the cooperation kernel (E467) -- threadgroup array, barrier,
# coordinates only where used ----
if out=$(emit "$METAL/examples/reduce.rb"); then
  for needle in "threadgroup float _sh_acc\[256\];" \
                "threadgroup_barrier(mem_flags::mem_threadgroup);" \
                "uint _lid \[\[thread_position_in_threadgroup\]\]" \
                "uint _grp \[\[threadgroup_position_in_grid\]\]"; do
    if ! printf '%s' "$out" | grep -q "$needle"; then
      echo "FAIL: reduce.metal missing: $needle"; fail=1
    fi
  done
  printf '%s' "$out" | grep -q "_lsz" && { echo "FAIL: reduce.metal carries an unused _lsz attribute"; fail=1; }
  printf '%s' "$out" | grep -q "def reduce_acc" && { echo "FAIL: host binding grew an accessor for threadgroup memory"; fail=1; }
  echo "  ok: reduce.rb -> shared array + barrier + only the coordinates it reads"
else
  echo "FAIL: reduce.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- positive: the atomic kernel (E469) ----
if out=$(emit "$METAL/examples/histogram.rb"); then
  for needle in "device atomic_int \*h \[\[buffer(1)\]\]" \
                "atomic_fetch_add_explicit" '"la"' \
                "def histogram_h_set" "def histogram_h_get"; do
    if ! printf '%s' "$out" | grep -q "$needle"; then
      echo "FAIL: histogram.metal missing: $needle"; fail=1
    fi
  done
  echo "  ok: histogram.rb -> atomic_int buffer + fetch_add + both host accessors"
else
  echo "FAIL: histogram.rb did not emit"; cat "$TMP/err"; fail=1
fi

# ---- negatives: die naming the problem ----
cat > "$TMP/atload.rb" <<'EOF'
gpu_buffer :h, :atomic, 0
gpu_buffer :y, :float, 1

def kernel__b
  gpu_store(:y, gpu_global_id, gpu_load(:h, 0))
end
EOF
if emit "$TMP/atload.rb" >/dev/null; then
  echo "FAIL: gpu_load on an :atomic buffer accepted"; fail=1
else
  grep -q "cannot be gpu_load" "$TMP/err" || { echo "FAIL: wrong error for atomic load"; fail=1; }
  echo "  ok: gpu_load on :atomic -> die naming the race"
fi
cat > "$TMP/atplain.rb" <<'EOF'
gpu_buffer :h, :int, 0

def kernel__b
  gpu_atomic_add(:h, 0, 1)
end
EOF
if emit "$TMP/atplain.rb" >/dev/null; then
  echo "FAIL: gpu_atomic_add on a non-atomic buffer accepted"; fail=1
else
  grep -q "needs an :atomic buffer" "$TMP/err" || { echo "FAIL: wrong error for non-atomic target"; fail=1; }
  echo "  ok: gpu_atomic_add on :int -> die naming the declaration to change"
fi
cat > "$TMP/atfloat.rb" <<'EOF'
gpu_buffer :h, :atomic, 0

def kernel__b
  gpu_atomic_add(:h, 0, 1.5)
end
EOF
if emit "$TMP/atfloat.rb" >/dev/null; then
  echo "FAIL: float value into gpu_atomic_add accepted"; fail=1
else
  grep -q "silently truncate" "$TMP/err" || { echo "FAIL: wrong error for float atomic add"; fail=1; }
  echo "  ok: float value into gpu_atomic_add -> die naming the truncation"
fi

cat > "$TMP/shbad.rb" <<'EOF'
gpu_shared :acc, :float, 256

def kernel__b
  gpu_shared_store(:missing, 0, 1.0)
end
EOF
if emit "$TMP/shbad.rb" >/dev/null; then
  echo "FAIL: undeclared gpu_shared name accepted"; fail=1
else
  grep -q "no \`gpu_shared\` declaration" "$TMP/err" || { echo "FAIL: wrong error for undeclared shared name"; fail=1; }
  echo "  ok: undeclared shared name -> die naming it"
fi
cat > "$TMP/shint.rb" <<'EOF'
gpu_shared :acc, :int, 8

def kernel__b
  gpu_shared_store(:acc, 0, 1.5)
end
EOF
if emit "$TMP/shint.rb" >/dev/null; then
  echo "FAIL: float store into :int shared array accepted"; fail=1
else
  grep -q "silently" "$TMP/err" || { echo "FAIL: wrong error for float->:int shared store"; fail=1; }
  echo "  ok: float store into :int shared -> die naming the truncation"
fi
cat > "$TMP/barg.rb" <<'EOF'
def kernel__b
  gpu_barrier(1)
end
EOF
if emit "$TMP/barg.rb" >/dev/null; then
  echo "FAIL: gpu_barrier with an argument accepted"; fail=1
else
  grep -q "takes no arguments" "$TMP/err" || { echo "FAIL: wrong error for gpu_barrier(1)"; fail=1; }
  echo "  ok: gpu_barrier(1) -> die naming the arity"
fi

neg() {  # neg <label> <needle> <<EOF source
  cat > "$TMP/neg.rb"
  if emit "$TMP/neg.rb" >/dev/null; then
    echo "FAIL: $1 was accepted"; fail=1
  elif ! grep -q "$2" "$TMP/err"; then
    echo "FAIL: $1 died but without naming it (wanted: $2)"; cat "$TMP/err"; fail=1
  else
    echo "  ok: $1 -> die naming it"
  fi
}

neg "unsupported builtin" "does not support 'hist_observe'" <<'EOF'
def kernel__a
  hist_observe(1)
end
EOF

neg "ivar (data race)" "data race" <<'EOF'
def kernel__b
  @x += 1
end
EOF

neg "non-literal slot" "must be a declared name" <<'EOF'
def kernel__c
  i = gpu_global_id
  gpu_store(i, 0, 1.5)
end
EOF

neg "unprefixed def" "kernel__<name>" <<'EOF'
def not_a_kernel
  gpu_store(0, 0, 1.5)
end
EOF

neg "float retype" "assigned both float and integer" <<'EOF'
def kernel__d
  i = gpu_global_id
  v = 1.5
  v = i + 1
  gpu_store(0, i, v)
end
EOF

neg "duplicate slot" "slot declared twice" <<'EOF'
gpu_buffer :a, :float, 0
gpu_buffer :b, :int, 0
def kernel__e
  gpu_store(:a, 0, 1.0)
end
EOF

neg "unknown buffer name" "no gpu_buffer named :zz" <<'EOF'
gpu_buffer :a, :float, 0
def kernel__f
  gpu_store(:zz, 0, 1.0)
end
EOF

neg "slot literal in declared unit" "refer to them by name" <<'EOF'
gpu_buffer :a, :float, 0
def kernel__g
  gpu_store(0, 0, 1.0)
end
EOF

neg "float store into :int buffer" "would silently truncate" <<'EOF'
gpu_buffer :m, :int, 0
def kernel__h
  i = gpu_global_id
  gpu_store(:m, i, 1.5)
end
EOF

if [ "$fail" -eq 0 ]; then
  echo "PASS: gpu-metal codegen supported/unsupported gate"
else
  echo "FAIL: gpu-metal codegen gate"; exit 1
fi
