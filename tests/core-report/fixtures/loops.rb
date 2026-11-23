# tests/core-report/fixtures/loops.rb -- decision 0010 step 1 fixtures.
#
# One entry per static_proof form and per unknown reason. Every loop body
# starts by counting itself into its own cell of `cnt`, so running an entry
# under CRuby says how many times each loop ran. That count is the independent
# check on a derived bound: tests/core-report/oracle.rb compares it with the
# bound the kernel reported, evaluated for the same arguments.
#
# The run.sh contract for an entry is generated from its signature: `cnt` is an
# inout i64 buffer counted by `n_cnt`, `buf` an in i64 buffer counted by
# `n_buf`, and every other parameter an i64 scalar. The entries never call one
# another's helpers, because each is compiled as its own closure and a call
# from outside a closure into it is refused.

LB_LIMIT = 5

# ---- static_proof forms ----------------------------------------------------

def lb_lt(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_le(cnt, n_cnt, n)
  i = 1
  while i <= n
    cnt[0] += 1
    i = i + 1
  end
  0
end

def lb_gt(cnt, n_cnt, n, lo)
  i = n
  while i > lo
    cnt[0] += 1
    i -= 1
  end
  0
end

def lb_ge(cnt, n_cnt, hi, lo)
  i = hi
  while i >= lo
    cnt[0] += 1
    i = i - 1
  end
  0
end

def lb_reversed(cnt, n_cnt, n, s)
  i = s
  while n > i
    cnt[0] += 1
    i = 1 + i
  end
  0
end

def lb_step(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    i += 3
  end
  0
end

def lb_count(cnt, n_cnt)
  i = 0
  while i < n_cnt
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_constant(cnt, n_cnt)
  i = 0
  while i < LB_LIMIT
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_local(cnt, n_cnt, n)
  m = n - 2
  h = n / 2
  i = 0
  while i < m
    cnt[0] += 1
    i += 1
  end
  j = 0
  while j <= h
    cnt[1] += 1
    j += 1
  end
  0
end

def lb_expression(cnt, n_cnt, n)
  i = 0
  while i < n * 2 + 1
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_break(cnt, n_cnt, n, stop)
  i = 0
  while i < n
    cnt[0] += 1
    break if i == stop
    i += 1
  end
  0
end

def lb_return(cnt, n_cnt, n, stop)
  i = 0
  while i < n
    cnt[0] += 1
    return 1 if i == stop
    i += 1
  end
  0
end

def lb_next_after_step(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    i += 1
    next if i == 2
    cnt[1] += 1
  end
  0
end

def lb_both_arms(cnt, n_cnt, n, c)
  i = 0
  while i < n
    cnt[0] += 1
    if c > 0
      i += 1
    else
      i = i + 1
    end
  end
  0
end

def lb_min_step(cnt, n_cnt, n, c)
  i = 0
  while i < n
    cnt[0] += 1
    if i < c
      i += 1
    else
      i += 2
    end
  end
  0
end

def lb_nested(cnt, n_cnt, n, m)
  i = 0
  while i < n
    cnt[0] += 1
    j = 0
    while j < m
      cnt[1] += 1
      j += 1
    end
    i += 1
  end
  0
end

def lb_siblings(cnt, n_cnt, n, m)
  i = 0
  while i < n
    cnt[0] += 1
    i += 1
  end
  j = m
  while j > 0
    cnt[1] += 1
    j -= 1
  end
  0
end

def lb_h_in_loop(cnt, len)
  k = 0
  while k < len
    cnt[1] += 1
    k += 1
  end
  0
end

def lb_callee_in_loop(cnt, n_cnt, n, m)
  i = 0
  while i < n
    cnt[0] += 1
    lb_h_in_loop(cnt, m + 1)
    i += 1
  end
  0
end

def lb_h_twice(cnt, len)
  k = 0
  while k < len
    cnt[0] += 1
    k += 1
  end
  0
end

def lb_callee_twice(cnt, n_cnt, n)
  lb_h_twice(cnt, n)
  lb_h_twice(cnt, 3)
  0
end

def lb_h_more(cnt, m)
  k = 0
  while k < m
    cnt[1] += 1
    k += 1
  end
  true
end

def lb_predicate_call(cnt, n_cnt, n, m)
  i = 0
  while i < n && lb_h_more(cnt, m)
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_conjunct(cnt, n_cnt, n, x)
  i = 0
  while x != 99 && i < n
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_start_param(cnt, n_cnt, s, n)
  i = s
  while i < n
    cnt[0] += 1
    i += 1
  end
  0
end

# ---- unknown, one entry per reason ------------------------------------------

def lb_ne(cnt, n_cnt, n)
  i = 0
  while i != n
    cnt[0] += 1
    break if i > n
    i += 1
  end
  0
end

def lb_or(cnt, n_cnt, n, m)
  i = 0
  j = 0
  while i < n || j < m
    cnt[0] += 1
    i += 1
    j += 1
  end
  0
end

def lb_h_go(i, n)
  i < n
end

def lb_boolean_call(cnt, n_cnt, n)
  i = 0
  while lb_h_go(i, n)
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_offset_side(cnt, n_cnt, n)
  i = 0
  while i + 1 < n
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_true(cnt, n_cnt, n)
  i = 0
  while true
    cnt[0] += 1
    break if i >= n
    i += 1
  end
  0
end

def lb_step_param(cnt, n_cnt, n, k)
  i = 0
  while i < n
    cnt[0] += 1
    break if k <= 0
    i += k
  end
  0
end

def lb_step_mul(cnt, n_cnt, n)
  i = 1
  while i < n
    cnt[0] += 1
    i = i * 2
  end
  0
end

def lb_skipped_by_next(cnt, n_cnt, n)
  i = 0
  j = 0
  while i < n
    cnt[0] += 1
    j += 1
    next if j == 2
    i += 1
  end
  0
end

def lb_step_one_arm(cnt, n_cnt, n)
  i = 0
  j = 0
  while i < n
    cnt[0] += 1
    j += 1
    if j > 2
      i += 1
    end
  end
  0
end

def lb_step_twice(cnt, n_cnt, n, c)
  i = 0
  while i < n
    cnt[0] += 1
    i += 1
    if c > 0
      i += 1
    end
  end
  0
end

def lb_step_nested(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    j = 0
    while j < 1
      cnt[1] += 1
      i += 1
      j += 1
    end
  end
  0
end

def lb_away(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    break if i < -3
    i -= 1
  end
  0
end

def lb_reassigned(cnt, n_cnt, n, s)
  i = 0
  while i < n
    cnt[0] += 1
    i = s + 1
    break if i >= n
  end
  0
end

def lb_bound_varies(cnt, n_cnt, n)
  i = 0
  m = n
  while i < m * 2
    cnt[0] += 1
    m -= 1
    i += 1
  end
  0
end

def lb_both_vary(cnt, n_cnt, n)
  i = 0
  j = n
  while i < j
    cnt[0] += 1
    i += 1
    j -= 1
  end
  0
end

def lb_buffer_bound(cnt, n_cnt, buf, n_buf)
  i = 0
  while i < buf[0]
    cnt[0] += 1
    i += 1
  end
  k = buf[1]
  j = 0
  while j < k
    cnt[1] += 1
    j += 1
  end
  0
end

def lb_h_limit(cnt, n)
  n + 1
end

def lb_call_bound(cnt, n_cnt, n)
  i = 0
  while i < lb_h_limit(cnt, n)
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_enclosing_bound(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    j = 0
    while j < i
      cnt[1] += 1
      j += 1
    end
    i += 1
  end
  0
end

def lb_after_loop_bound(cnt, n_cnt, n)
  i = 0
  m = 0
  while i < n
    cnt[0] += 1
    m += 1
    i += 1
  end
  j = 0
  while j < m
    cnt[1] += 1
    j += 1
  end
  0
end

def lb_buffer_start(cnt, n_cnt, buf, n_buf, n)
  i = buf[0]
  while i < n
    cnt[0] += 1
    i += 1
  end
  0
end

def lb_enclosing_start(cnt, n_cnt, n)
  a = 0
  while a < n
    cnt[0] += 1
    b = a + 1
    while b < n
      cnt[1] += 1
      b += 1
    end
    a += 1
  end
  0
end

def lb_merged_start(cnt, n_cnt, n, c)
  if c > 0
    i = 0
  else
    i = 1
  end
  while i < n
    cnt[0] += 1
    i += 1
  end
  0
end

# ---- composition: reasons that belong to an occurrence ---------------------

def lb_h_arg(cnt, len)
  k = 0
  while k < len
    cnt[1] += 1
    k += 1
  end
  0
end

def lb_argument(cnt, n_cnt, buf, n_buf, n)
  i = 0
  while i < n
    cnt[0] += 1
    lb_h_arg(cnt, buf[0])
    i += 1
  end
  0
end

def lb_h_var(cnt, len)
  k = 0
  while k < len
    cnt[1] += 1
    k += 1
  end
  0
end

def lb_argument_varies(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    lb_h_var(cnt, i)
    i += 1
  end
  0
end

def lb_enclosing_unknown(cnt, n_cnt, buf, n_buf, m)
  i = 0
  while i < buf[0]
    cnt[0] += 1
    j = 0
    while j < m
      cnt[1] += 1
      j += 1
    end
    i += 1
  end
  0
end

# ---- evaluation order, and the two limits -----------------------------------

# `m -= e` reads m BEFORE evaluating e, so this leaves m at n, and the loop
# runs n times. Deriving the right-hand side first made the bound 0.
def lb_opassign_order(cnt, n_cnt, n)
  m = n
  m -= (m = 0)
  i = 0
  while i < m
    cnt[0] += 1
    i += 1
  end
  0
end

# Thirteen doublings are 8191 terms written out, over the limit, although the
# expression graph itself is tiny.
def lb_expr_too_large(cnt, n_cnt, n)
  m = n
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  m = m + m
  i = 0
  while i < m
    cnt[0] += 1
    i += 1
  end
  0
end

# Each level calls the one below it twice, so the entry's expansion reaches
# 8192 occurrences of one loop and stops at the limit.
def lb_fan0(cnt, n)
  k = 0
  while k < n
    cnt[0] += 1
    k += 1
  end
  0
end
def lb_fan1(cnt, n)
  lb_fan0(cnt, n)
  lb_fan0(cnt, n)
  0
end

def lb_fan2(cnt, n)
  lb_fan1(cnt, n)
  lb_fan1(cnt, n)
  0
end

def lb_fan3(cnt, n)
  lb_fan2(cnt, n)
  lb_fan2(cnt, n)
  0
end

def lb_fan4(cnt, n)
  lb_fan3(cnt, n)
  lb_fan3(cnt, n)
  0
end

def lb_fan5(cnt, n)
  lb_fan4(cnt, n)
  lb_fan4(cnt, n)
  0
end

def lb_fan6(cnt, n)
  lb_fan5(cnt, n)
  lb_fan5(cnt, n)
  0
end

def lb_fan7(cnt, n)
  lb_fan6(cnt, n)
  lb_fan6(cnt, n)
  0
end

def lb_fan8(cnt, n)
  lb_fan7(cnt, n)
  lb_fan7(cnt, n)
  0
end

def lb_fan9(cnt, n)
  lb_fan8(cnt, n)
  lb_fan8(cnt, n)
  0
end

def lb_fan10(cnt, n)
  lb_fan9(cnt, n)
  lb_fan9(cnt, n)
  0
end

def lb_fan11(cnt, n)
  lb_fan10(cnt, n)
  lb_fan10(cnt, n)
  0
end

def lb_fan12(cnt, n)
  lb_fan11(cnt, n)
  lb_fan11(cnt, n)
  0
end

def lb_fan13(cnt, n)
  lb_fan12(cnt, n)
  lb_fan12(cnt, n)
  0
end

def lb_too_many_terms(cnt, n_cnt, n)
  lb_fan13(cnt, n)
  0
end

# ---- decision 0041 stage 1: loops with a literal block ----------------------
#
# The receiver and the argument are read once, before the first iteration, so
# a bound is expressed in what they were at the loop's entry. Block loops are
# counted in the same per-method sequence as `while` loops.

def lb_times(cnt, n_cnt, n)
  n.times { |i| cnt[0] += 1 }
  0
end

def lb_upto(cnt, n_cnt, a, b)
  a.upto(b) { |j| cnt[0] += 1 }
  0
end

def lb_downto(cnt, n_cnt, a, b)
  a.downto(b) do |j|
    cnt[0] += 1
  end
  0
end

def lb_each(cnt, n_cnt, buf, n_buf)
  buf.each { |x| cnt[0] += 1 }
  0
end

def lb_each_with_index(cnt, n_cnt, buf, n_buf)
  buf.each_with_index { |x, k| cnt[0] += 1 }
  0
end

def lb_times_after_while(cnt, n_cnt, n, m)
  i = 0
  while i < n
    cnt[0] += 1
    i += 1
  end
  m.times { |k| cnt[1] += 1 }
  0
end

def lb_times_receiver_assigned(cnt, n_cnt, n)
  n.times do |i|
    cnt[0] += 1
    n = n - 1
  end
  0
end

def lb_times_enclosing(cnt, n_cnt, n)
  i = 0
  while i < n
    cnt[0] += 1
    i.times { |k| cnt[1] += 1 }
    i += 1
  end
  0
end

def lb_h_each(cnt, buf)
  buf.each { |x| cnt[1] += 1 }
  0
end

def lb_each_in_helper(cnt, n_cnt, buf, n_buf)
  cnt[0] += 1
  lb_h_each(cnt, buf)
  lb_h_each(cnt, buf)
  0
end

# A receiver or limit with a side effect (the review of stage 1): each
# is read once, in Ruby's order, so the bound is the receiver's value at the
# call and the limit's value after the receiver ran. Reading them again after
# both ran counted the assignment twice.
def lb_times_effect(cnt, n_cnt, n)
  (n -= 1).times { |i| cnt[0] += 1 }
  0
end

def lb_upto_effect(cnt, n_cnt, a, b)
  a.upto((b -= 1)) { |j| cnt[0] += 1 }
  0
end

def lb_downto_effect(cnt, n_cnt, a, b)
  a.downto((b += 1)) { |j| cnt[0] += 1 }
  0
end

def lb_upto_reassign(cnt, n_cnt, a, b)
  a.upto(a = 0) { |j| cnt[0] += 1 }
  0
end
