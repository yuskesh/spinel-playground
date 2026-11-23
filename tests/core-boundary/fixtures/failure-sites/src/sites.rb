# tests/core-boundary/fixtures/failure-sites/src/sites.rb -- failure sites.
#
# Three places a call can fail, each on a line of its own: the entry's own
# `+`, the `*` of a helper it calls (whose failure the entry passes up), and
# a declared capacity failure.

def fs_scale(x, k)
  x * k
end

def fs_entry(a, k)
  if k < 0
    core_fail(:capacity)
  end
  x = a + 1
  fs_scale(x, k)
end
