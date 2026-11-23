# The index check of a 32-bit body (decision 0022 section 3, decision 0007):
# the one fixture here that reads an element, so its admitted cases keep the
# element inside the module's memory, and the count is never read as a value.
def at_u8(src, n_src, i)
  src[i]
end
