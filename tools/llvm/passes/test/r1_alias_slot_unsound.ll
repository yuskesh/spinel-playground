; E016 -- the R1 (inert-region elision) soundness hole found by running the
; 2887-case suite under SPINEL_GC_STRESS=1.  FIXED IN E017 (was XFAIL).
;
; Minimal Ruby that produces this IR (tools/llvm/passes/test/r1_alias_slot_unsound.rb):
;
;     a = [1, 2, 3]
;     p a.each_with_index.flat_map { |v, i| [v, i] }
;
; Spinel's codegen emits an UNROOTED alias for the rooted temp:
;
;     sp_PolyArray *_t2 = sp_Enumerator_to_a(...); SP_GC_ROOT(_t2);
;     sp_PolyArray *_t3 = _t2;                     /* no root of its own */
;     sp_PolyArray *_t4 = sp_PolyArray_new();      /* CAN COLLECT */
;     for (...) sp_PolyArray_get(_t3, i);          /* _t3 used much later */
;
; which is correct C: the object is kept alive by _t2's root, and the GC is
; precise and NON-MOVING, so the second name is fine.
;
; The pass's liveness GEN closes over POINTER DERIVATIONS of a load only
; (gep/bitcast/phi/select -- safety_analysis.md §2 R1, deliberately narrow so a
; getter's `double` result does not drag later allocations into the window).  A
; `store ptr %v, ptr %other` is not a pointer derivation, so the closure stops
; there: the live range of the rooted value ends at the copy, sp_PolyArray_new
; is no longer "live across", and the root is elided -- while %other still
; points at the object.  `Escapes` does not save us either: it only fires when
; the SLOT ADDRESS is stored, never when the slot's VALUE is.
;
; Measured end to end (2-line Ruby above, pass build, ThinLTO):
;   plain             stock [1, 0, 2, 1, 3, 2]   pass [1, 0, 2, 1, 3, 2]
;   SPINEL_GC_STRESS  stock [1, 0, 2, 1, 3, 2]   pass [1, 0, 2, 1]   <-- freed
;
; E017 fixes it two ways, both of which must keep this root:
;   -spinel-gc-alias-join (default on): %t3 is a non-escaping alloca, so it is
;      a second home for the same object and its loads join the live range;
;   -spinel-gc-alias-join=false: any store of the loaded value gives up.
; See r1_alias_join.ll for the case that separates the two.
;
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -S %s | FileCheck %s
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -spinel-gc-alias-join=false -S %s | FileCheck %s

target triple = "arm64-apple-macosx26.0.0"

@sp_gc_nroots = external global i32
@sp_gc_roots = external global [65536 x ptr]

declare ptr @sp_gc_alloc(i64)
declare i32 @_sp_gc_root_push(ptr)
declare void @_sp_gc_root_pop(ptr)
declare i64 @sp_PolyArray_length(ptr)
declare ptr @sp_Enumerator_to_a(ptr)

; may-GC-and-return
define ptr @sp_PolyArray_new() {
entry:
  %p = call ptr @sp_gc_alloc(i64 64)
  ret ptr %p
}

define i64 @sp_flat_map(ptr %src) {
; CHECK-LABEL: define i64 @sp_flat_map(
; CHECK: call i32 @_sp_gc_root_push(ptr %t2)
entry:
  %t2 = alloca ptr, align 8           ; the rooted temp
  %t3 = alloca ptr, align 8           ; the unrooted alias codegen emits
  %t4 = alloca ptr, align 8
  %f2 = alloca i32, align 4
  %f4 = alloca i32, align 4
  %a = call ptr @sp_Enumerator_to_a(ptr %src)
  store ptr %a, ptr %t2, align 8
  %r2 = call i32 @_sp_gc_root_push(ptr %t2)
  store i32 %r2, ptr %f2, align 4
  ; the copy: the value leaves the analysed slot through MEMORY
  %v = load ptr, ptr %t2, align 8
  store ptr %v, ptr %t3, align 8
  ; and a collection happens after it
  %new = call ptr @sp_PolyArray_new()
  store ptr %new, ptr %t4, align 8
  %r4 = call i32 @_sp_gc_root_push(ptr %t4)
  store i32 %r4, ptr %f4, align 4
  ; ... which the alias outlives
  %alias = load ptr, ptr %t3, align 8
  %n = call i64 @sp_PolyArray_length(ptr %alias)
  call void @_sp_gc_root_pop(ptr %f4)
  call void @_sp_gc_root_pop(ptr %f2)
  ret i64 %n
}
