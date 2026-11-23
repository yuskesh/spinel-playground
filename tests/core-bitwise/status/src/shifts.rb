# tests/core-bitwise/status/src/shifts.rb -- decision 0042 stage 2 on the
# status lane: one kernel per method, built by run.sh from a contract that
# declares both parameters at the body width.

def shl(a, n)
  a << n
end

def shr(a, n)
  a >> n
end
