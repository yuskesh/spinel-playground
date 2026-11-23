# A refusal fixture for decision 0022 §1: the intrinsic given a Boolean.

def r(a, b)
  core_w32_add(a, b == 0)
end
