# A refusal fixture for decision 0022 §1: the intrinsic renamed by alias.

alias w_plus core_w32_add

def r(a, b)
  w_plus(a, b)
end
