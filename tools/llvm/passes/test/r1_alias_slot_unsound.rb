# E016 -- the R1 (inert-region elision) soundness hole that the 2887-case suite
# under SPINEL_GC_STRESS=1 found.  FIXED IN E017 (this file was XFAIL); see
# r1_alias_slot_unsound.ll for the IR-level statement of the same thing and
# docs/experiments/E016_gcroots_stress_validation.md for the analysis.
#
# These two lines are the whole reproducer.  Spinel's codegen emits
#
#     sp_PolyArray *_t2 = sp_Enumerator_to_a(...); SP_GC_ROOT(_t2);
#     sp_PolyArray * _t3 = _t2;                    /* unrooted alias */
#     sp_PolyArray *_t4 = sp_PolyArray_new();      /* CAN COLLECT */
#     for (...) sp_PolyArray_get(_t3, i);
#
# and the pass USED TO elide _t2's root because it stopped following the value
# at the copy into _t3.  Under stress the array was freed at sp_PolyArray_new
# and the loop read dead memory:
#
#     plain             stock [1, 0, 2, 1, 3, 2]  pass [1, 0, 2, 1, 3, 2]
#     SPINEL_GC_STRESS  stock [1, 0, 2, 1, 3, 2]  pass [1, 0, 2, 1]
#
# Reduced from vendor/spinel/test/enum_map_chain.rb, one of the four tests the
# pass broke under stress (the other three are hash_range_enum_extensions,
# bundle_array_a, hash_predicates_merge_minby_wave10).

a = [1, 2, 3]
p a.each_with_index.flat_map { |v, i| [v, i] }
