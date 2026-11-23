# tests/app/fixtures/lowering/body.rb -- the entries of Task 5's lowering
# fixture. lowering.sh prepends tools/app/lib/spinel/net.rb, so put_str and
# put_dec below are the real helpers.

module Adc
end
module Telemetry
end
module Log
end

# A helper reached with one cross argument and one private argument: both of
# its parameters are in the atomic closure, so both accesses are atomic.
def mixed(dst, src)
  dst[0] = src[0]
  0
end

# A helper reached only with private arguments: nothing here is atomic.
def plain(dst, src)
  dst[1] = src[1]
  0
end

def tick(reading, frame, shared, priv, small)
  v = Adc.latest(0)
  reading[0] = v
  n = put_str(frame, 0, "temp=", 5)
  n = put_dec(frame, n, v)
  Telemetry.put(frame, n)
  mixed(shared, priv)
  plain(priv, small)
  Log.write("tick", 4)
  0
end

# A constant-invalid send: n = 0 fails the first guard at run time.
def send_zero(frame)
  Telemetry.put(frame, 0)
  0
end

# n read from state: the same guard, decided at run time.
def send_n(frame, ctl)
  frame[0] = 7
  Telemetry.put(frame, ctl[0])
  0
end

# A constant-invalid send on an untaken path builds, and runs to OK.
def untaken(frame, ctl)
  if ctl[0] == 1
    Telemetry.put(frame, 0)
  end
  0
end

# Writes past a short buffer's end, through the helpers: BOUNDS, and nothing
# written outside the buffer.
def oob_str(small)
  put_str(small, 0, "abcdefgh", 8)
  0
end

def oob_dec(small)
  put_dec(small, 0, 123456789)
  0
end

# Every buffer access here is a cross access: the object for thumbv8m must
# show one LDRB/STRB per element and no LDRD, STRD, LDM or STM outside the
# stack frame.
def cross_only(a, b)
  i = 0
  while i < 8
    a[i] = b[i]
    i += 1
  end
  0
end

# A 64-bit cross element: refused for a 32-bit target, built for the host.
def wide(w)
  w[0] = w[0] + 1
  0
end

# The final D1 probe (Task 5): the net.rb helpers with string literals, now
# that literals lower, and decision 0022's core_fixed_div, whose 64-bit
# division may call the helper; at the target's 32 bits nothing else does
# (decision 0019, revised 2026-10-21; an `int64` body's `/` and `%` did). The
# union of the undefined symbols of these objects for thumbv8m, less the
# declared externs, is the helper list D1 rests on.
def lit_str(out)
  put_str(out, 0, "hello world", 11)
  0
end

def lit_dec(out, w64)
  n = put_dec(out, 0, w64[0])
  put_dec(out, n, -1234567)
  0
end

def fixdiv(w32)
  w32[0] = core_fixed_div(w32[0], w32[1])
  0
end
