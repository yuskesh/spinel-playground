# tests/app/fixtures/cross/probe.rb -- the D1 runtime-helper probe (0014, Task 2).
#
# Wrapper entries under core-contract 1 for what a Cortex-M33 build of CORE
# code may lower to compiler runtime helpers: checked `+ - * / %` and shifts at
# the target's 32 bits, with variable and with constant operands, the real
# bodies of tools/app/lib/spinel/net.rb, which tests/app/cross.sh prepends to
# this file, and decision 0022's `core_fixed_div`, the one CORE operation that
# may still call the 64-bit division helper. The undefined symbols of the
# objects are the helper list D1 rests on. Before decision 0019's 2026-10-21
# revision the file declared `# spinel: int64`, and its 64-bit `/` and `%`
# called the helper.

def p_add(a, b)
  a + b
end

def p_sub(a, b)
  a - b
end

def p_mul(a, b)
  a * b
end

def p_div(a, b)
  a / b
end

def p_mod(a, b)
  a % b
end

def p_shl(a, b)
  a << b
end

def p_shr(a, b)
  a >> b
end

def p_mul_c(a)
  a * 1000003
end

def p_div_c(a)
  a / 10
end

def p_mod_c(a)
  a % 10
end

def p_shl_c(a)
  a << 7
end

def p_shr_c(a)
  a >> 7
end

def p_fixed_div(a, b)
  core_fixed_div(a, b)
end

def p_put_u8(out, n_out, pos, v)
  put_u8(out, pos, v)
end

def p_put_u16(out, n_out, pos, v)
  put_u16(out, pos, v)
end

def p_put_i32(out, n_out, pos, v)
  put_i32(out, pos, v)
end

def p_put_dec(out, n_out, pos, v)
  put_dec(out, pos, v)
end

def p_put_str(out, n_out, pos, s, n_s)
  put_str(out, pos, s, n_s)
end
