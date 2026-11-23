# tests/core-bitwise/status/src/powers.rb -- decision 0042 stage 3 on the
# status lane: one kernel per method, built by run.sh from a contract that
# declares both parameters at the body width. `ab` and the constant powers
# `pkE` ignore n, so that one contract shape and one driver serve them all.

def ab(a, n)
  a.abs
end

def pw(a, n)
  a ** n
end

def pk0(a, n)
  a ** 0
end

def pk1(a, n)
  a ** 1
end

def pk2(a, n)
  a ** 2
end

def pk31(a, n)
  a ** 31
end

def pk63(a, n)
  a ** 63
end
