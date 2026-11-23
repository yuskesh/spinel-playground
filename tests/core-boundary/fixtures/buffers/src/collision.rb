# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# A buffer called `src` beside a scalar called `src_id`. The adapter used to
# put contract names straight into C, so both became a parameter named
# `src_id` and the generated header would not compile -- a valid contract that
# produced invalid C.

def collision(src, n_src, src_id)
  src_id + src[0]
end
