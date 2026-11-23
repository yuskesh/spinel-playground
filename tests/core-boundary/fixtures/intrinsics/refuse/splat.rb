# A refusal fixture for decision 0022 §1: the intrinsic with a splat argument.

def r(a, b)
  xs = [a, b]
  core_w32_add(*xs)
end
