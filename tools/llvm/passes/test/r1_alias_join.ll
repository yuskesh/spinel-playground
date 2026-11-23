; E017 -- the two halves of the R1 fix, and the line between them.
;
; E016 §4c: the GEN closure follows POINTER DERIVATIONS of a load, so a
; `store ptr %v, ptr %other` ended the live range while the object stayed
; reachable through %other.  E017 closes that.  There are two settings:
;
;   -spinel-gc-alias-join=false  (variant b, "the conservative cut")
;       any store of the loaded value gives up on the root.
;   -spinel-gc-alias-join        (variant a, the default)
;       if the destination is a NON-ESCAPING alloca, that alloca is a second
;       home for the same object: its loads join the live range, and the root
;       survives or dies on whether a collection sits inside the JOINED range.
;
; This file pins three things:
;   sp_join_keeps   -- alias used after a may-GC call: BOTH settings keep it
;                      (that is r1_alias_slot_unsound.ll's shape, restated).
;   sp_join_elides  -- alias dead before the may-GC call: join still ELIDES,
;                      the conservative cut does not.  Without this case the
;                      two settings would be indistinguishable and the join
;                      would be pointless complexity.
;   sp_alias_escapes -- destination is a heap field, not a plain local: no
;                      join is possible, so both settings keep the root.
;
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -S %s | FileCheck %s --check-prefixes=CHECK,JOIN
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -spinel-gc-alias-join=false -S %s | FileCheck %s --check-prefixes=CHECK,CUT

target triple = "arm64-apple-macosx26.0.0"

%struct.box = type { ptr, i64 }

@sp_gc_nroots = external global i32
@sp_gc_roots = external global [65536 x ptr]
@g_slot = external global ptr

declare ptr @sp_gc_alloc(i64)
declare i32 @_sp_gc_root_push(ptr)
declare void @_sp_gc_root_pop(ptr)
declare ptr @sp_Enumerator_to_a(ptr)

; a consumer that provably cannot collect, so the ONLY may-GC call in these
; functions is sp_PolyArray_new and the tests measure liveness, not the may-GC set.
define i64 @sp_nogc_len(ptr %p) {
entry:
  ret i64 7
}

; may-GC-and-return
define ptr @sp_PolyArray_new() {
entry:
  %p = call ptr @sp_gc_alloc(i64 64)
  ret ptr %p
}

; --- the alias outlives the collection: keep, under both settings ------------
define i64 @sp_join_keeps(ptr %src) {
; CHECK-LABEL: define i64 @sp_join_keeps(
; CHECK: call i32 @_sp_gc_root_push(ptr %t2)
entry:
  %t2 = alloca ptr, align 8
  %t3 = alloca ptr, align 8
  %f2 = alloca i32, align 4
  %a = call ptr @sp_Enumerator_to_a(ptr %src)
  store ptr %a, ptr %t2, align 8
  %r2 = call i32 @_sp_gc_root_push(ptr %t2)
  store i32 %r2, ptr %f2, align 4
  %v = load ptr, ptr %t2, align 8
  store ptr %v, ptr %t3, align 8
  %new = call ptr @sp_PolyArray_new()
  %alias = load ptr, ptr %t3, align 8
  %n = call i64 @sp_nogc_len(ptr %alias)
  call void @_sp_gc_root_pop(ptr %f2)
  ret i64 %n
}

; --- the alias is dead before the collection: the join can still elide -------
define i64 @sp_join_elides(ptr %src) {
; CHECK-LABEL: define i64 @sp_join_elides(
; JOIN-NOT: call i32 @_sp_gc_root_push(ptr %t2)
; CUT: call i32 @_sp_gc_root_push(ptr %t2)
entry:
  %t2 = alloca ptr, align 8
  %t3 = alloca ptr, align 8
  %f2 = alloca i32, align 4
  %a = call ptr @sp_Enumerator_to_a(ptr %src)
  store ptr %a, ptr %t2, align 8
  %r2 = call i32 @_sp_gc_root_push(ptr %t2)
  store i32 %r2, ptr %f2, align 4
  %v = load ptr, ptr %t2, align 8
  store ptr %v, ptr %t3, align 8
  ; every use of the object -- through either name -- happens HERE ...
  %alias = load ptr, ptr %t3, align 8
  %n = call i64 @sp_nogc_len(ptr %alias)
  ; ... and only then can a collection run.  Nothing reads the object after it.
  %new = call ptr @sp_PolyArray_new()
  call void @_sp_gc_root_pop(ptr %f2)
  ret i64 %n
}

; --- destination is not a plain local: no join, both settings keep -----------
define i64 @sp_alias_escapes(ptr %src, ptr %box) {
; CHECK-LABEL: define i64 @sp_alias_escapes(
; CHECK: call i32 @_sp_gc_root_push(ptr %t2)
entry:
  %t2 = alloca ptr, align 8
  %f2 = alloca i32, align 4
  %a = call ptr @sp_Enumerator_to_a(ptr %src)
  store ptr %a, ptr %t2, align 8
  %r2 = call i32 @_sp_gc_root_push(ptr %t2)
  store i32 %r2, ptr %f2, align 4
  %v = load ptr, ptr %t2, align 8
  %fld = getelementptr inbounds %struct.box, ptr %box, i32 0, i32 0
  store ptr %v, ptr %fld, align 8          ; into a heap object, not an alloca
  %new = call ptr @sp_PolyArray_new()
  %alias = load ptr, ptr %fld, align 8
  %n = call i64 @sp_nogc_len(ptr %alias)
  call void @_sp_gc_root_pop(ptr %f2)
  ret i64 %n
}

; --- destination is a global: no join either ---------------------------------
define i64 @sp_alias_global(ptr %src) {
; CHECK-LABEL: define i64 @sp_alias_global(
; CHECK: call i32 @_sp_gc_root_push(ptr %t2)
entry:
  %t2 = alloca ptr, align 8
  %f2 = alloca i32, align 4
  %a = call ptr @sp_Enumerator_to_a(ptr %src)
  store ptr %a, ptr %t2, align 8
  %r2 = call i32 @_sp_gc_root_push(ptr %t2)
  store i32 %r2, ptr %f2, align 4
  %v = load ptr, ptr %t2, align 8
  store ptr %v, ptr @g_slot, align 8
  %new = call ptr @sp_PolyArray_new()
  %alias = load ptr, ptr @g_slot, align 8
  %n = call i64 @sp_nogc_len(ptr %alias)
  call void @_sp_gc_root_pop(ptr %f2)
  ret i64 %n
}
