; E017 -- R2 (batching) must keep the PER-SLOT low-bit tag of every root in a
; mixed-tag run.
;
; sp_gc.h gives three root macros that differ only in the address they hand to
; _sp_gc_root_push:
;   SP_GC_ROOT(v)        push((void**)&v)                       tag 0
;   SP_GC_ROOT_RBVAL(v)  push((void**)((uintptr_t)&v | 1))      tag 1
;   SP_GC_ROOT_STR(v)    push((void**)((uintptr_t)&v | 2))      tag 2
; and sp_gc_mark_all reads the low bits back to decide how to scan the entry
; (sp_gc.h:378).  A batch replaces the k calls with k stores into sp_gc_roots,
; so it must store the SAME tagged address the call would have received --
; per slot, not once for the run.  E016 §7 listed "the tag of each slot address
; surviving a mixed-tag batch" as one of four unverified candidates for the
; literal_string_markers failure; this test settles that one (it survives).
;
; RUN: %opt -passes=spinel-gc-roots -spinel-gc-elide=false -S %s | FileCheck %s

target triple = "arm64-apple-macosx26.0.0"

@sp_gc_nroots = external global i32
@sp_gc_roots = external global [65536 x ptr]

declare i32 @_sp_gc_root_push(ptr)
declare void @_sp_gc_root_pop(ptr)
declare ptr @sp_sink(ptr, ptr, ptr)

define void @sp_mixed() {
; The run is three pushes with no call in between, so it batches.  Each store
; into sp_gc_roots must carry that slot's own tag: %plain untagged, %rbval
; or'd with 1, %str or'd with 2.
;
; CHECK-LABEL: define void @sp_mixed(
; CHECK:        %rbo = or i64 %{{.*}}, 1
; CHECK:        %rbt = inttoptr i64 %rbo to ptr
; CHECK:        %sto = or i64 %{{.*}}, 2
; CHECK:        %stt = inttoptr i64 %sto to ptr
; CHECK:      sp.batch.fast:
; CHECK:        store ptr %plain, ptr %{{.*}}
; CHECK:        store ptr %rbt, ptr %{{.*}}
; CHECK:        store ptr %stt, ptr %{{.*}}
; CHECK:        store i32 %{{.*}}, ptr @sp_gc_nroots
;
; The fallback keeps the original three calls verbatim, tags and all.
; CHECK:      sp.batch.slow:
; CHECK:        call i32 @_sp_gc_root_push(ptr %plain)
; CHECK:        call i32 @_sp_gc_root_push(ptr %rbt)
; CHECK:        call i32 @_sp_gc_root_push(ptr %stt)
entry:
  %plain = alloca ptr, align 8
  %rbval = alloca ptr, align 8
  %str = alloca ptr, align 8
  %f0 = alloca i32, align 4
  %f1 = alloca i32, align 4
  %f2 = alloca i32, align 4
  store ptr null, ptr %plain, align 8
  store ptr null, ptr %rbval, align 8
  store ptr null, ptr %str, align 8
  %rbi = ptrtoint ptr %rbval to i64
  %rbo = or i64 %rbi, 1
  %rbt = inttoptr i64 %rbo to ptr
  %sti = ptrtoint ptr %str to i64
  %sto = or i64 %sti, 2
  %stt = inttoptr i64 %sto to ptr
  %r0 = call i32 @_sp_gc_root_push(ptr %plain)
  store i32 %r0, ptr %f0, align 4
  %r1 = call i32 @_sp_gc_root_push(ptr %rbt)
  store i32 %r1, ptr %f1, align 4
  %r2 = call i32 @_sp_gc_root_push(ptr %stt)
  store i32 %r2, ptr %f2, align 4
  %a = load ptr, ptr %plain, align 8
  %b = load ptr, ptr %rbval, align 8
  %c = load ptr, ptr %str, align 8
  %v = call ptr @sp_sink(ptr %a, ptr %b, ptr %c)
  call void @_sp_gc_root_pop(ptr %f2)
  call void @_sp_gc_root_pop(ptr %f1)
  call void @_sp_gc_root_pop(ptr %f0)
  ret void
}
