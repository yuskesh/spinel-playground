# A refusal fixture for decision 0022 §1: a top-level definition of an intrinsic's name in the source the closure calls it from.

def core_w32_add(a, b)
  a + b
end

def r(a, b)
  core_w32_add(a, b)
end
