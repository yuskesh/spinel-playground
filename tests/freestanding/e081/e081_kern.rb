# spinel: int64
# E081 -- P003 Phase 4: a freestanding kernel that CALLS platform intrinsics.
#
# The externs (uptime_ms / sleep_ms / print_i64 / gpio_set / gpio_get /
# sense_scale / checksum32) are declared in the PROFILE, not here: they are
# facts about the platform surface, and the same yaml already tells the
# undefined-symbol gate what the object may import (R006 H7's single source of
# truth).  This file only USES them, exactly as it would use another top-level
# method.
#
# Who supplies them is layer 3's business and differs per leg of the
# differential:
#   native   Ruby stubs appended by mkcases.py (bin/spinel's C back end)
#   M33/RV32 zephyr/src/spinel_zephyr.c (k_uptime_get / k_msleep / printk /
#            the GPIO driver where the board has one)
#   wasm32   JS functions handed to WebAssembly.Instance as env.* imports

require_relative "spinel/freestanding"

# -- A. gpio: a set/get contract that is deterministic on every leg ---------
freestanding_def :toggle_count, params: [:i32], returns: :i32
def toggle_count(n)
  acc = 0
  i = 0
  while i < n
    gpio_set(0, i % 2)
    acc = acc + gpio_get(0)
    i += 1
  end
  acc
end

# -- B. the extern-argument boundary (D-8), trap vs declared wrap -----------
# The same body under two overflow policies: E040's mulwide/mulnarrow pair,
# replayed at an extern ARGUMENT instead of a return value.
freestanding_def :pin_probe, params: [:i64], returns: :i32
def pin_probe(pin)
  gpio_set(pin, 1)
end

freestanding_def :pin_wrap, params: [:i64], returns: :i32, overflow: :wrap
def pin_wrap(pin)
  gpio_set(pin, 1)
end

# -- C. uptime + sleep: a deterministic VERDICT over nondeterministic values
freestanding_def :wait_check, params: [:i32], returns: :i32
def wait_check(d)
  t0 = uptime_ms()
  r = sleep_ms(d)
  t1 = uptime_ms()
  if t1 >= t0 && r == 0
    1
  else
    0
  end
end

# -- D. print: the value flows on, the side effect is the platform's --------
freestanding_def :chirp, params: [:i32, :i32], returns: :i64
def chirp(a, b)
  v = a * 100 + b
  s = print_i64(v)
  v + s
end

# -- E. float externs (f32 narrows by ROUNDING on the way out -- D-4) -------
freestanding_def :fsense, params: [:f64, :f64], returns: :f64
def fsense(a, b)
  sense_scale(a, b)
end

# -- F. u32 extern (unsigned fit check at the argument) ---------------------
freestanding_def :csum, params: [:i64], returns: :i64
def csum(v)
  checksum32(v)
end

# -- G. extern + internal call + floored division in one body ---------------
# `tag` is an ordinary internal method (not an entry) that itself calls an
# extern: the extern surface has to work from anywhere in the call-graph
# closure, not only from the declared boundaries.
def tag(x)
  checksum32(x % 256 + 128)
end

freestanding_def :mix, params: [:i32, :i32], returns: :i64
def mix(a, b)
  q = a / b
  c = tag(q)
  q * 1000 + c % 1000
end
