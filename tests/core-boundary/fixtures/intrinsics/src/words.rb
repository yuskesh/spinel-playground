# The entries of decision 0022's acceptance table: one per intrinsic, each
# taking its operands as parameters so every value arrives at run time. The
# comparisons are taken in a real branch, and their answer is 1 or 0.

def w_add(a, b)
  core_w32_add(a, b)
end

# The intrinsic and an ordinary `+` in one body: with plain == 0 the wrapping
# sum, otherwise the checked one, which at 32 bits is ARITHMETIC for MAX + 1.
def w_add_or_plain(a, b, plain)
  if plain == 0
    core_w32_add(a, b)
  else
    a + b
  end
end

def w_sub(a, b)
  core_w32_sub(a, b)
end

def w_mul(a, b)
  core_w32_mul(a, b)
end

def w_neg(a)
  core_w32_neg(a)
end

def u_lt(a, b)
  if core_u32_lt(a, b)
    1
  else
    0
  end
end

def u_le(a, b)
  if core_u32_le(a, b)
    1
  else
    0
  end
end

def u_gt(a, b)
  if core_u32_gt(a, b)
    1
  else
    0
  end
end

def u_ge(a, b)
  if core_u32_ge(a, b)
    1
  else
    0
  end
end

def u_shr(a, n)
  core_u32_shr(a, n)
end

def f_mul(a, b)
  core_fixed_mul(a, b)
end

def f_div(a, b)
  core_fixed_div(a, b)
end

# The intrinsic one call down, so that inlining the helper into the entry is
# what the build does; the answer must not change.
def add_helper(a, b)
  core_w32_add(a, b)
end

def w_add_inlined(a, b)
  add_helper(a, b)
end
