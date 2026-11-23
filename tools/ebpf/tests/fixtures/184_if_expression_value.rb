def spnl_emit(x)
  # placeholder; codegen replaces with ringbuf reserve/submit
end

@last = 0

# E011/E426: `if` in EXPRESSION position. E011 built the temp-variable lowering
# for exactly this ("if 式の値 は temp 変数で受け"), and the retired Ruby codegen
# documented `if_node` as the "式位置の if (`x = if ... end` 等)" path. The
# ADR-011 Stage 2 port routed IfNode through the statement lowering only, so the
# value form died while three neighbours kept working -- which is why no fixture
# noticed: the affordance line "if / elsif / else (式値も)" was 6/7 true.
def classify(a)
  n = if a > 10
    2
  elsif a > 0
    1
  else
    0
  end
  n
end

# The same node in the other two expression positions that were dead: the value
# of an ivar write, and an operand inside a larger expression.
def kprobe__do_sys_openat2(a)
  @last = if a > 0
    1
  else
    0
  end
  spnl_emit(classify(a) + (if a > 100 then 1 else 0 end))
end

# The statement form, which never broke -- kept beside the value form so the
# golden shows both lowerings of the same node in one unit.
def sign(a)
  if a > 0
    1
  else
    -1
  end
end

puts classify(42)
puts sign(-3)
