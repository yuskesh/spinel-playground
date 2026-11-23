; E016 -- regression test for the R3 (callee-roots) soundness hole that E015
; found and fixed DURING the PoC, with no test covering it afterwards
; (E015 Honest boundary #2; safety_analysis.md §2 R3).
;
; THE RULE.  A may-GC call that only consumes the rooted value as an argument
; does not need the CALLER's root when the callee roots that parameter itself
; before it can collect.  Such a call stops VETOING the elision.
;
; THE HOLE.  The exemption must NOT also remove the call from the caller's
; PROTECT set (the GEN of the liveness analysis).  Arguments are evaluated left
; to right, so the shape
;
;     %v    = load ptr, ptr %slot          ; the rooted local
;     %new  = call @sp_Vec_new(...)        ; may-GC, NOT exempt
;     %d    = call @sp_Basis_compute(%v, %new)   ; may-GC, exempt (roots its arg)
;
; puts a collection point BETWEEN the load and the exempt call.  If the exempt
; call is dropped from PROTECT, the value's live range ends at the load, the
; intervening sp_Vec_new is no longer "live across", and the root is elided --
; leaving %v unrooted across a real collection.  The callee's own root does not
; help: it is only installed after sp_Vec_new has already run.
;
; The first function below is that shape and its root MUST survive.  The second
; is the same shape WITHOUT the intervening allocation and its root must still
; be elided -- otherwise this file would pass merely by disabling R3.
;
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -S %s | FileCheck %s
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -S %s | FileCheck --check-prefix=OK %s
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-batch=false -spinel-gc-callee-roots=false -S %s | FileCheck --check-prefix=NOR3 %s

target triple = "arm64-apple-macosx26.0.0"

@sp_gc_nroots = external global i32
@sp_gc_roots = external global [65536 x ptr]

declare ptr @sp_gc_alloc(i64)
declare i32 @_sp_gc_root_push(ptr)
declare void @_sp_gc_root_pop(ptr)

; NOGC: no calls at all.
define double @sp_Vec_x(ptr %p) {
entry:
  %d = load double, ptr %p, align 8
  ret double %d
}

; may-GC-and-return: reaches an allocator and comes back.
define ptr @sp_Vec_new(double %x) {
entry:
  %p = call ptr @sp_gc_alloc(i64 32)
  store double %x, ptr %p, align 8
  ret ptr %p
}

; may-GC, and roots parameter 0 (and 1) in its entry block before it can
; collect -- exactly what Spinel's codegen emits for every reference parameter.
; Its own roots have to survive the pass (the value is used after the
; allocation), otherwise the caller-side check would see a rootless callee.
define double @sp_Basis_compute(ptr %a, ptr %b) {
entry:
  %a.addr = alloca ptr, align 8
  %b.addr = alloca ptr, align 8
  %fa = alloca i32, align 4
  %fb = alloca i32, align 4
  store ptr %a, ptr %a.addr, align 8
  store ptr %b, ptr %b.addr, align 8
  %r0 = call i32 @_sp_gc_root_push(ptr %a.addr)
  store i32 %r0, ptr %fa, align 4
  %r1 = call i32 @_sp_gc_root_push(ptr %b.addr)
  store i32 %r1, ptr %fb, align 4
  %t = call ptr @sp_Vec_new(double 1.000000e+00)
  %av = load ptr, ptr %a.addr, align 8
  %bv = load ptr, ptr %b.addr, align 8
  %d0 = call double @sp_Vec_x(ptr %av)
  %d1 = call double @sp_Vec_x(ptr %bv)
  %s = fadd double %d0, %d1
  call void @_sp_gc_root_pop(ptr %fb)
  call void @_sp_gc_root_pop(ptr %fa)
  ret double %s
}

; ---------------------------------------------------------------------------
; THE HOLE.  A may-GC call sits between the load of the rooted value and the
; exempt call that consumes it.  The root must be KEPT.
; ---------------------------------------------------------------------------
define double @sp_Scene_hole() {
; CHECK-LABEL: define double @sp_Scene_hole(
; CHECK: call i32 @_sp_gc_root_push(ptr %slot)
; CHECK: call void @_sp_gc_root_pop(ptr %flag)
entry:
  %slot = alloca ptr, align 8
  %flag = alloca i32, align 4
  ; a LOCAL temp, deliberately not a parameter home: E017 pins parameter roots
  ; (see @sp_Scene_param below) and this file must keep testing R3 itself.
  %seed = call ptr @sp_Vec_new(double 0.000000e+00)
  store ptr %seed, ptr %slot, align 8
  %r = call i32 @_sp_gc_root_push(ptr %slot)
  store i32 %r, ptr %flag, align 4
  %v = load ptr, ptr %slot, align 8
  %fresh = call ptr @sp_Vec_new(double 2.000000e+00)
  %d = call double @sp_Basis_compute(ptr %v, ptr %fresh)
  call void @_sp_gc_root_pop(ptr %flag)
  ret double %d
}

; ---------------------------------------------------------------------------
; R3 STILL WORKS.  Same shape with nothing between the load and the exempt
; call: the callee's own root covers the whole call, so the caller's root goes.
; Without this the file would also pass with R3 switched off entirely.
; ---------------------------------------------------------------------------
define double @sp_Scene_ok() {
; OK-LABEL: define double @sp_Scene_ok(
; OK-NOT: _sp_gc_root_push
; OK: ret double
; NOR3-LABEL: define double @sp_Scene_ok(
; NOR3: call i32 @_sp_gc_root_push(ptr %slot)
entry:
  %slot = alloca ptr, align 8
  %flag = alloca i32, align 4
  %seed = call ptr @sp_Vec_new(double 0.000000e+00)
  store ptr %seed, ptr %slot, align 8
  %r = call i32 @_sp_gc_root_push(ptr %slot)
  store i32 %r, ptr %flag, align 4
  %v = load ptr, ptr %slot, align 8
  %d = call double @sp_Basis_compute(ptr %v, ptr %v)
  call void @_sp_gc_root_pop(ptr %flag)
  ret double %d
}

; ---------------------------------------------------------------------------
; E017.  R3's SECOND hole: the exemption is a CONTRACT with the callee, and the
; pass used to break it in the callee's own turn.  @sp_Basis_compute above is
; only "a callee that roots its parameters" while its parameter roots are still
; there -- and inside it, each parameter's only use is another exempt call, so
; the old pass elided them.  Both ends elided = no root anywhere.
;
; Measured end to end on bm_spectral_norm (frozen benchmark, argv 300):
;   only main's `u` root elided          -> 1274223985  (correct)
;   only sp_multiply's `lv_u` root       -> 1274223985  (correct)
;   BOTH                                 -> nan (FloatDomainError)
;
; So a parameter's entry-block root is PINNED while -spinel-gc-callee-roots is
; on, and only then may it go.
;
; The body below has NO may-GC call at all, so nothing vetoes: the only reason
; to keep this root is the pin.  With -spinel-gc-callee-roots=false there is no
; R3 contract to protect and the root goes -- which is what separates "pinned"
; from "vetoed".
; ---------------------------------------------------------------------------
define double @sp_Scene_param(ptr %seed) {
; CHECK-LABEL: define double @sp_Scene_param(
; CHECK: call i32 @_sp_gc_root_push(ptr %slot)
; NOR3-LABEL: define double @sp_Scene_param(
; NOR3-NOT: _sp_gc_root_push
; NOR3: ret double
entry:
  %slot = alloca ptr, align 8
  %flag = alloca i32, align 4
  store ptr %seed, ptr %slot, align 8      ; the parameter's home alloca
  %r = call i32 @_sp_gc_root_push(ptr %slot)
  store i32 %r, ptr %flag, align 4
  %v = load ptr, ptr %slot, align 8
  %d = call double @sp_Vec_x(ptr %v)       ; NOGC: nothing here vetoes
  call void @_sp_gc_root_pop(ptr %flag)
  ret double %d
}
