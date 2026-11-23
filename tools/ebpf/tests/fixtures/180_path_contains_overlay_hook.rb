# E420 negative fixture: the SUBSTRING selector, on the fexit side.
#
# The refusal is per-SEC, and fexit/dentry_open renders paths exactly the way
# fentry/dentry_open does (E418 h25/h26 are the same measurement on both sides),
# so all three selectors are refused on all four SECs. This fixture pins the
# fexit half so that a gate keyed only on `fentry/` would be caught.
@hits = 0

def fexit__dentry_open(path, flags, cred, ret)
  if path_contains(path, "/.ssh/")
    @hits = @hits + 1
  end
  0
end
