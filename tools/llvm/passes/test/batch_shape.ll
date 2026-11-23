; E016 -- shape test for R2 (batching).  safety_analysis.md §3.3 and §3.4 make
; two structural claims that nothing checked before:
;
;   1. the k slot stores are emitted BEFORE the sp_gc_nroots store, so no
;      observer can ever see a counter that covers an unwritten slot;
;   2. the capacity guard `n <= SP_GC_STACK_MAX - k` falls back to the ORIGINAL
;      per-root _sp_gc_root_push calls, so the overflow behaviour (which flag
;      ends up 0 when the shadow stack is full, sp_gc.h:85-87) is preserved bit
;      for bit rather than approximated.
;
; Elision is switched off so the run of pushes survives to be batched.
;
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-elide=false -S %s | FileCheck %s

target triple = "arm64-apple-macosx26.0.0"

@sp_gc_nroots = external global i32
@sp_gc_roots = external global [65536 x ptr]

declare i32 @_sp_gc_root_push(ptr)
declare void @_sp_gc_root_pop(ptr)
declare void @sp_use(ptr, ptr, ptr)

define void @sp_three_locals(ptr %x, ptr %y, ptr %z) {
; CHECK-LABEL: define void @sp_three_locals(
; the guard: one load of the counter, compared against MAX - k with k = 3
; CHECK: %sp.nroots = load i32, ptr @sp_gc_nroots
; CHECK: %sp.fits = icmp sle i32 %sp.nroots, 65533
; CHECK: br i1 %sp.fits, label %sp.batch.fast, label %sp.batch.slow
;
; fast path: THREE slot stores, and only then the counter store
; CHECK-LABEL: sp.batch.fast:
; CHECK: store ptr %a, ptr %{{.*}}
; CHECK: store ptr %b, ptr %{{.*}}
; CHECK: store ptr %c, ptr %{{.*}}
; CHECK: add i32 %sp.nroots, 3
; CHECK-NEXT: store i32 %{{.*}}, ptr @sp_gc_nroots
;
; slow path: the original calls, verbatim
; CHECK-LABEL: sp.batch.slow:
; CHECK: call i32 @_sp_gc_root_push(ptr %a)
; CHECK: call i32 @_sp_gc_root_push(ptr %b)
; CHECK: call i32 @_sp_gc_root_push(ptr %c)
entry:
  %a = alloca ptr, align 8
  %b = alloca ptr, align 8
  %c = alloca ptr, align 8
  %fa = alloca i32, align 4
  %fb = alloca i32, align 4
  %fc = alloca i32, align 4
  store ptr %x, ptr %a, align 8
  store ptr %y, ptr %b, align 8
  store ptr %z, ptr %c, align 8
  %r0 = call i32 @_sp_gc_root_push(ptr %a)
  store i32 %r0, ptr %fa, align 4
  %r1 = call i32 @_sp_gc_root_push(ptr %b)
  store i32 %r1, ptr %fb, align 4
  %r2 = call i32 @_sp_gc_root_push(ptr %c)
  store i32 %r2, ptr %fc, align 4
  call void @sp_use(ptr %a, ptr %b, ptr %c)
  call void @_sp_gc_root_pop(ptr %fc)
  call void @_sp_gc_root_pop(ptr %fb)
  call void @_sp_gc_root_pop(ptr %fa)
  ret void
}

; A run broken by a call is NOT a batch: an intervening call is exactly the
; window in which a collection (or another thread's STW park) could observe a
; half-written batch, which is what makes the transform safe at all.
define void @sp_split_by_call(ptr %x, ptr %y) {
; CHECK-LABEL: define void @sp_split_by_call(
; CHECK-NOT: sp.batch.fast
; CHECK: ret void
entry:
  %a = alloca ptr, align 8
  %b = alloca ptr, align 8
  %fa = alloca i32, align 4
  %fb = alloca i32, align 4
  store ptr %x, ptr %a, align 8
  store ptr %y, ptr %b, align 8
  %r0 = call i32 @_sp_gc_root_push(ptr %a)
  store i32 %r0, ptr %fa, align 4
  call void @sp_use(ptr %a, ptr %a, ptr %a)
  %r1 = call i32 @_sp_gc_root_push(ptr %b)
  store i32 %r1, ptr %fb, align 4
  call void @_sp_gc_root_pop(ptr %fb)
  call void @_sp_gc_root_pop(ptr %fa)
  ret void
}
