# tests/doom-core/fixtures/state/slots/add_entry.rb
#
# `dc_add_thinker` lives in its OWN unit rather than beside the other
# wrappers: the kernel compiles one closure per file, and `dc_take` and
# `dc_link` call helpers that are inside this entry's closure -- which it
# refuses as `unaccounted-ingress`, correctly. Packing them together and
# compiling this entry gave exactly that diagnostic.
#
# `P_AddThinker` AS ONE PUBLIC ENTRY, which is what makes the migration row
# for `Game#add_thinker` true rather than a pair of names.
#
# Mac review of 33da4d9: mapping `add_thinker` to `dc_take_slot,dc_link_slot`
# left out two things the original does. The FUNC AND DATA STORE happens
# between taking and linking -- it lived in the test, not in CORE source. And
# the OVERFLOW PATH was a -1 sentinel nobody read; the original raises
# LevelError, and the public CORE spelling of "the arena is full" is the
# CAPACITY status, not a magic return value.
def dc_add_thinker(th_free, n_th_free, th_prev, n_th_prev, th_alloc, n_th_alloc,
                   th_func, n_th_func, th_data, n_th_data, th_next, n_th_next,
                   cap, func, data)
  t = dc_take_slot(th_free, th_prev, th_alloc, cap)
  # `core_fail` IS A RETURN, not a value -- the kernel refuses it in
  # expression position by name, and `return core_fail(:capacity) if ...`
  # is exactly that. Measured: "call to 'core_fail', which is not in the
  # selected closure". Statement position is the spelling.
  core_fail(:capacity) if t < 0
  dc_store_thinker(th_func, th_data, t, func, data)
  dc_link_slot(th_next, th_prev, t)
  t
end
