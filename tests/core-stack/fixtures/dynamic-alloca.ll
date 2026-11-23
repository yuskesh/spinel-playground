; tests/core-stack/fixtures/dynamic-alloca.ll -- decision 0010 step 2.
;
; An entry whose frame is not fixed at code generation. 0010: "The `realtime`
; profile admits no dynamic stack allocation: no dynamic `alloca` and no
; variable-length array in the final IR", and "an entry that needs one gets
; verdict `fail` under `realtime`".
;
; WHY THIS IS HAND-WRITTEN IR AND NOT A RUBY ENTRY. The CORE scalar subset
; cannot express one. Every Array, String and Hash form is refused before code
; generation (tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp) and a
; buffer parameter is an address the caller owns, so no accepted entry reaches
; this rule. It guards IR shapes other lanes already emit -- lib/Freestanding/
; GradShim.cpp builds exactly this, a VLA whose length is a runtime value --
; and the only way to exercise it is to hand the analysis IR of that shape.
;
; The shape is the emitter's: a length computed at run time, an `alloca` of
; that length, and a loop that writes through it.

define i64 @spinel_core_dyn_entry(i64 %n) {
entry:
  %len = add i64 %n, 1
  %buf = alloca i64, i64 %len, align 8
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %body ]
  %done = icmp sge i64 %i, %len
  br i1 %done, label %exit, label %body

body:
  %slot = getelementptr inbounds i64, ptr %buf, i64 %i
  store i64 %i, ptr %slot, align 8
  %next = add i64 %i, 1
  br label %loop

exit:
  %first = load i64, ptr %buf, align 8
  ret i64 %first
}
