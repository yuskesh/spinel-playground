; G5 controls: hand-written adjoints, one shape per function. expect.tsv names
; what G5 must count in each. Only the scan reads this file; it is never
; compiled.

; Both operands converted from integers: nnan is a fact, not a licence.
define double @diffe_int_int(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fmul nnan double %a, %b
  ret double %c
}

; The same with uitofp and ninf.
define double @diffe_uint_uint(i64 %n) {
  %a = uitofp i64 %n to double
  %c = fmul ninf double %a, %a
  ret double %c
}

; A unary operation on one conversion.
define double @diffe_fneg_int(i64 %n) {
  %a = sitofp i64 %n to double
  %c = fneg nnan double %a
  ret double %c
}

; A comparison of two conversions.
define i1 @diffe_fcmp_int(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fcmp nnan ogt double %a, %b
  ret i1 %c
}

; Two double arguments: nothing proves them free of NaN.
define double @diffe_arg_arg(double %x, double %y) {
  %c = fmul nnan double %x, %y
  ret double %c
}

; One conversion and one argument.
define double @diffe_int_arg(i64 %n, double %y) {
  %a = sitofp i64 %n to double
  %c = fmul nnan double %a, %y
  ret double %c
}

; One conversion and a constant.
define double @diffe_int_const(i64 %n) {
  %a = sitofp i64 %n to double
  %c = fdiv nnan double %a, 2.000000e+00
  ret double %c
}

; An operand that is a conversion in another function only: the name is local.
define double @diffe_other_fn(double %a, double %b) {
  %c = fmul nnan double %a, %b
  ret double %c
}

; nsz on conversions is still a site: it is not a fact about the operands.
define double @diffe_nsz(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fmul nsz double %a, %b
  ret double %c
}

; fast on conversions is still a site.
define double @diffe_fast(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fadd fast double %a, %b
  ret double %c
}

; contract on conversions is still a site.
define double @diffe_contract(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fmul contract double %a, %b
  ret double %c
}

; nnan together with another flag is a site.
define double @diffe_nnan_reassoc(i64 %n, i64 %m) {
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  %c = fadd nnan reassoc double %a, %b
  ret double %c
}

; A phi of conversions is not one of the exempt shapes.
define double @fwddiffe_phi_int(i1 %p, i64 %n, i64 %m) {
entry:
  %a = sitofp i64 %n to double
  %b = sitofp i64 %m to double
  br i1 %p, label %l, label %r
l:
  br label %j
r:
  br label %j
j:
  %c = phi nnan double [ %a, %l ], [ %b, %r ]
  ret double %c
}

; No flag at all.
define double @fwddiffe_plain(double %x, double %y) {
  %c = fmul double %x, %y
  ret double %c
}
