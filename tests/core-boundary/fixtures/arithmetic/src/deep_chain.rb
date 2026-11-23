# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls, and no caller anywhere:
# the contract declares each parameter's domain and the checker derives the
# rest of the closure from those facts.

# Seventy helpers deep. The derivation learns one link per round in the
# worst order, so this is what says the round bound is computed from the
# lattice rather than picked: a chain this long converges and is accepted.

def link70(x)
  x + 1
end

def link69(x)
  link70(x)
end

def link68(x)
  link69(x)
end

def link67(x)
  link68(x)
end

def link66(x)
  link67(x)
end

def link65(x)
  link66(x)
end

def link64(x)
  link65(x)
end

def link63(x)
  link64(x)
end

def link62(x)
  link63(x)
end

def link61(x)
  link62(x)
end

def link60(x)
  link61(x)
end

def link59(x)
  link60(x)
end

def link58(x)
  link59(x)
end

def link57(x)
  link58(x)
end

def link56(x)
  link57(x)
end

def link55(x)
  link56(x)
end

def link54(x)
  link55(x)
end

def link53(x)
  link54(x)
end

def link52(x)
  link53(x)
end

def link51(x)
  link52(x)
end

def link50(x)
  link51(x)
end

def link49(x)
  link50(x)
end

def link48(x)
  link49(x)
end

def link47(x)
  link48(x)
end

def link46(x)
  link47(x)
end

def link45(x)
  link46(x)
end

def link44(x)
  link45(x)
end

def link43(x)
  link44(x)
end

def link42(x)
  link43(x)
end

def link41(x)
  link42(x)
end

def link40(x)
  link41(x)
end

def link39(x)
  link40(x)
end

def link38(x)
  link39(x)
end

def link37(x)
  link38(x)
end

def link36(x)
  link37(x)
end

def link35(x)
  link36(x)
end

def link34(x)
  link35(x)
end

def link33(x)
  link34(x)
end

def link32(x)
  link33(x)
end

def link31(x)
  link32(x)
end

def link30(x)
  link31(x)
end

def link29(x)
  link30(x)
end

def link28(x)
  link29(x)
end

def link27(x)
  link28(x)
end

def link26(x)
  link27(x)
end

def link25(x)
  link26(x)
end

def link24(x)
  link25(x)
end

def link23(x)
  link24(x)
end

def link22(x)
  link23(x)
end

def link21(x)
  link22(x)
end

def link20(x)
  link21(x)
end

def link19(x)
  link20(x)
end

def link18(x)
  link19(x)
end

def link17(x)
  link18(x)
end

def link16(x)
  link17(x)
end

def link15(x)
  link16(x)
end

def link14(x)
  link15(x)
end

def link13(x)
  link14(x)
end

def link12(x)
  link13(x)
end

def link11(x)
  link12(x)
end

def link10(x)
  link11(x)
end

def link9(x)
  link10(x)
end

def link8(x)
  link9(x)
end

def link7(x)
  link8(x)
end

def link6(x)
  link7(x)
end

def link5(x)
  link6(x)
end

def link4(x)
  link5(x)
end

def link3(x)
  link4(x)
end

def link2(x)
  link3(x)
end

def link1(x)
  link2(x)
end

def deep_chain(a, b)
  link1(a) + b
end
