; ModuleID = 'gen/enzyme.cortex-m33-zephyr.ll'
source_filename = "llvm-link"
target datalayout = "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64"
target triple = "thumbv8m.main-none-eabi"

@sp_cstr_1 = private constant [31 x i8] c"gen_row: integer overflow in +\00"
@sp_cstr_4 = private constant [37 x i8] c"gen_row: index out of bounds for dst\00"
@sp_cstr_5 = private constant [37 x i8] c"score_row: index out of bounds for w\00"
@sp_cstr_6 = private constant [39 x i8] c"score_row: index out of bounds for row\00"
@sp_cstr_7 = private constant [35 x i8] c"outcome: index out of bounds for w\00"
@sp_cstr_8 = private constant [37 x i8] c"outcome: index out of bounds for row\00"
@sp_cstr_10 = private constant [37 x i8] c"sq_hinge_loss: integer overflow in *\00"
@sp_cstr_11 = private constant [41 x i8] c"sq_hinge_loss: index out of bounds for w\00"
@sp_cstr_12 = private constant [44 x i8] c"sq_hinge_loss: index out of bounds for data\00"
@sp_cstr_13 = private constant [37 x i8] c"sq_hinge_loss: integer overflow in +\00"
@sp_cstr_14 = private constant [36 x i8] c"sgd_step: index out of bounds for w\00"
@sp_cstr_16 = private constant [32 x i8] c"sgd_step: integer overflow in +\00"
@sp_cstr_18 = private constant [57 x i8] c"spinel_gen_row: negative length for the buffer before it\00"
@sp_cstr_19 = private constant [51 x i8] c"spinel_gen_row: NULL buffer with a non-zero length\00"
@sp_cstr_21 = private constant [59 x i8] c"spinel_score_row: negative length for the buffer before it\00"
@sp_cstr_22 = private constant [53 x i8] c"spinel_score_row: NULL buffer with a non-zero length\00"
@sp_cstr_23 = private constant [57 x i8] c"spinel_outcome: negative length for the buffer before it\00"
@sp_cstr_24 = private constant [51 x i8] c"spinel_outcome: NULL buffer with a non-zero length\00"
@sp_cstr_26 = private constant [63 x i8] c"spinel_sq_hinge_loss: negative length for the buffer before it\00"
@sp_cstr_27 = private constant [57 x i8] c"spinel_sq_hinge_loss: NULL buffer with a non-zero length\00"
@sp_cstr_28 = private constant [58 x i8] c"spinel_sgd_step: negative length for the buffer before it\00"
@sp_cstr_29 = private constant [52 x i8] c"spinel_sgd_step: NULL buffer with a non-zero length\00"

; Function Attrs: nounwind
define i32 @spinel_kern_version() #0 {
  ret i32 79
}

; Function Attrs: cold noreturn nounwind
declare void @spinel_trap(i32, i64, i64, ptr) #1

; Function Attrs: nounwind
define i32 @spinel_gen_row(ptr %0, i32 %1, i32 %2) #2 {
  %4 = sext i32 %1 to i64
  %5 = icmp slt i32 %1, 0
  br i1 %5, label %83, label %6

6:                                                ; preds = %3
  %7 = icmp eq ptr %0, null
  %8 = icmp ne i32 %1, 0
  %9 = and i1 %7, %8
  br i1 %9, label %84, label %10

10:                                               ; preds = %6
  %11 = sext i32 %2 to i64
  %12 = mul nsw i64 %11, 1103515245
  %13 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %12, i64 12345)
  %14 = extractvalue { i64, i1 } %13, 1
  br i1 %14, label %76, label %15

15:                                               ; preds = %10
  %16 = extractvalue { i64, i1 } %13, 0
  %17 = mul i64 %16, 1103515245
  %18 = add i64 %17, 12345
  %19 = and i64 %18, 2147483647
  %20 = urem i64 %19, 2000
  %21 = add nsw i64 %20, -1000
  %22 = sitofp i64 %21 to double
  %23 = fdiv double %22, 1.000000e+03
  %24 = mul i64 %18, 1103515245
  %25 = add i64 %24, 12345
  %26 = and i64 %25, 2147483647
  %27 = urem i64 %26, 2000
  %28 = add nsw i64 %27, -1000
  %29 = sitofp i64 %28 to double
  %30 = fdiv double %29, 1.000000e+03
  %31 = mul i64 %25, 1103515245
  %32 = add i64 %31, 12345
  %33 = and i64 %32, 2147483647
  %34 = urem i64 %33, 2000
  %35 = add nsw i64 %34, -1000
  %36 = sitofp i64 %35 to double
  %37 = fdiv double %36, 1.000000e+03
  %38 = mul i64 %32, 1103515245
  %39 = add i64 %38, 12345
  %40 = and i64 %39, 2147483647
  %41 = urem i64 %40, 2000
  %42 = add nsw i64 %41, -1000
  %43 = sitofp i64 %42 to double
  %44 = fdiv double %43, 1.000000e+03
  %45 = icmp eq i32 %1, 0
  br i1 %45, label %77, label %46

46:                                               ; preds = %15
  store double %23, ptr %0, align 8
  %47 = icmp eq i32 %1, 1
  br i1 %47, label %78, label %48

48:                                               ; preds = %46
  %49 = getelementptr i8, ptr %0, i32 8
  store double %30, ptr %49, align 8
  %50 = icmp ult i32 %1, 3
  br i1 %50, label %79, label %51

51:                                               ; preds = %48
  %52 = getelementptr i8, ptr %0, i32 16
  store double %37, ptr %52, align 8
  %53 = icmp eq i32 %1, 3
  br i1 %53, label %80, label %54

54:                                               ; preds = %51
  %55 = getelementptr i8, ptr %0, i32 24
  store double %44, ptr %55, align 8
  %56 = fmul double %23, 1.500000e+00
  %57 = fmul double %30, 8.000000e-01
  %58 = fadd double %56, %57
  %59 = fmul double %37, 1.200000e+00
  %60 = fsub double %58, %59
  %61 = fmul double %44, 4.000000e-01
  %62 = fadd double %60, %61
  %63 = fmul double %23, 6.000000e-01
  %64 = fmul double %63, %30
  %65 = fadd double %62, %64
  %66 = fadd double %65, -3.000000e-01
  %67 = fcmp ogt double %66, 0.000000e+00
  br i1 %67, label %68, label %72

68:                                               ; preds = %54
  %69 = icmp ult i32 %1, 5
  br i1 %69, label %81, label %70

70:                                               ; preds = %68
  %71 = getelementptr i8, ptr %0, i32 32
  store double 1.000000e+00, ptr %71, align 8
  br label %sp_gen_row.exit

72:                                               ; preds = %54
  %73 = icmp ult i32 %1, 5
  br i1 %73, label %82, label %74

74:                                               ; preds = %72
  %75 = getelementptr i8, ptr %0, i32 32
  store double -1.000000e+00, ptr %75, align 8
  br label %sp_gen_row.exit

76:                                               ; preds = %10
  call void @spinel_trap(i32 1, i64 %12, i64 12345, ptr nonnull @sp_cstr_1)
  unreachable

77:                                               ; preds = %15
  call void @spinel_trap(i32 4, i64 0, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

78:                                               ; preds = %46
  call void @spinel_trap(i32 4, i64 1, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

79:                                               ; preds = %48
  call void @spinel_trap(i32 4, i64 2, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

80:                                               ; preds = %51
  call void @spinel_trap(i32 4, i64 3, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

81:                                               ; preds = %68
  call void @spinel_trap(i32 4, i64 4, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

82:                                               ; preds = %72
  call void @spinel_trap(i32 4, i64 4, i64 %4, ptr nonnull @sp_cstr_4)
  unreachable

sp_gen_row.exit:                                  ; preds = %74, %70
  ret i32 5

83:                                               ; preds = %3
  call void @spinel_trap(i32 6, i64 %4, i64 0, ptr nonnull @sp_cstr_18)
  unreachable

84:                                               ; preds = %6
  call void @spinel_trap(i32 5, i64 %4, i64 0, ptr nonnull @sp_cstr_19)
  unreachable
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64) #3

; Function Attrs: nounwind
define double @spinel_score_row(ptr %0, i32 %1, ptr %2, i32 %3) #0 {
  %5 = sext i32 %1 to i64
  %6 = icmp slt i32 %1, 0
  br i1 %6, label %69, label %7

7:                                                ; preds = %4
  %8 = sext i32 %3 to i64
  %9 = icmp slt i32 %3, 0
  br i1 %9, label %70, label %10

10:                                               ; preds = %7
  %11 = icmp eq ptr %0, null
  %12 = icmp ne i32 %1, 0
  %13 = and i1 %11, %12
  br i1 %13, label %71, label %14

14:                                               ; preds = %10
  %15 = icmp eq ptr %2, null
  %16 = icmp ne i32 %3, 0
  %17 = and i1 %15, %16
  br i1 %17, label %72, label %18

18:                                               ; preds = %14
  %19 = icmp eq i32 %3, 0
  br i1 %19, label %46, label %20

20:                                               ; preds = %18
  %21 = icmp eq i32 %1, 0
  br i1 %21, label %47, label %22

22:                                               ; preds = %20
  %23 = load double, ptr %2, align 8
  %24 = load double, ptr %0, align 8
  %25 = icmp eq i32 %3, 1
  br i1 %25, label %48, label %26

26:                                               ; preds = %22
  %27 = icmp eq i32 %1, 1
  br i1 %27, label %49, label %28

28:                                               ; preds = %26
  %29 = getelementptr i8, ptr %2, i32 8
  %30 = load double, ptr %29, align 8
  %31 = getelementptr i8, ptr %0, i32 8
  %32 = load double, ptr %31, align 8
  %33 = icmp ult i32 %3, 3
  br i1 %33, label %50, label %34

34:                                               ; preds = %28
  %35 = icmp ult i32 %1, 3
  br i1 %35, label %51, label %36

36:                                               ; preds = %34
  %37 = getelementptr i8, ptr %2, i32 16
  %38 = load double, ptr %37, align 8
  %39 = getelementptr i8, ptr %0, i32 16
  %40 = load double, ptr %39, align 8
  %41 = icmp eq i32 %3, 3
  br i1 %41, label %52, label %42

42:                                               ; preds = %36
  %43 = icmp eq i32 %1, 3
  br i1 %43, label %53, label %44

44:                                               ; preds = %42
  %45 = icmp ult i32 %3, 5
  br i1 %45, label %54, label %sp_score_row.exit

46:                                               ; preds = %18
  call void @spinel_trap(i32 4, i64 0, i64 %8, ptr nonnull @sp_cstr_5)
  unreachable

47:                                               ; preds = %20
  call void @spinel_trap(i32 4, i64 0, i64 %5, ptr nonnull @sp_cstr_6)
  unreachable

48:                                               ; preds = %22
  call void @spinel_trap(i32 4, i64 1, i64 %8, ptr nonnull @sp_cstr_5)
  unreachable

49:                                               ; preds = %26
  call void @spinel_trap(i32 4, i64 1, i64 %5, ptr nonnull @sp_cstr_6)
  unreachable

50:                                               ; preds = %28
  call void @spinel_trap(i32 4, i64 2, i64 %8, ptr nonnull @sp_cstr_5)
  unreachable

51:                                               ; preds = %34
  call void @spinel_trap(i32 4, i64 2, i64 %5, ptr nonnull @sp_cstr_6)
  unreachable

52:                                               ; preds = %36
  call void @spinel_trap(i32 4, i64 3, i64 %8, ptr nonnull @sp_cstr_5)
  unreachable

53:                                               ; preds = %42
  call void @spinel_trap(i32 4, i64 3, i64 %5, ptr nonnull @sp_cstr_6)
  unreachable

54:                                               ; preds = %44
  call void @spinel_trap(i32 4, i64 4, i64 %8, ptr nonnull @sp_cstr_5)
  unreachable

sp_score_row.exit:                                ; preds = %44
  %55 = fmul double %23, %24
  %56 = fmul double %30, %32
  %57 = fadd double %55, %56
  %58 = fmul double %38, %40
  %59 = fadd double %57, %58
  %60 = getelementptr i8, ptr %2, i32 24
  %61 = load double, ptr %60, align 8
  %62 = getelementptr i8, ptr %0, i32 24
  %63 = load double, ptr %62, align 8
  %64 = fmul double %61, %63
  %65 = fadd double %59, %64
  %66 = getelementptr i8, ptr %2, i32 32
  %67 = load double, ptr %66, align 8
  %68 = fadd double %65, %67
  ret double %68

69:                                               ; preds = %4
  call void @spinel_trap(i32 6, i64 %5, i64 0, ptr nonnull @sp_cstr_21)
  unreachable

70:                                               ; preds = %7
  call void @spinel_trap(i32 6, i64 %8, i64 0, ptr nonnull @sp_cstr_21)
  unreachable

71:                                               ; preds = %10
  call void @spinel_trap(i32 5, i64 %5, i64 0, ptr nonnull @sp_cstr_22)
  unreachable

72:                                               ; preds = %14
  call void @spinel_trap(i32 5, i64 %8, i64 0, ptr nonnull @sp_cstr_22)
  unreachable
}

; Function Attrs: nounwind
define i32 @spinel_outcome(ptr %0, i32 %1, ptr %2, i32 %3) #0 {
  %5 = sext i32 %1 to i64
  %6 = icmp slt i32 %1, 0
  br i1 %6, label %77, label %7

7:                                                ; preds = %4
  %8 = sext i32 %3 to i64
  %9 = icmp slt i32 %3, 0
  br i1 %9, label %78, label %10

10:                                               ; preds = %7
  %11 = icmp eq ptr %0, null
  %12 = icmp ne i32 %1, 0
  %13 = and i1 %11, %12
  br i1 %13, label %79, label %14

14:                                               ; preds = %10
  %15 = icmp eq ptr %2, null
  %16 = icmp ne i32 %3, 0
  %17 = and i1 %15, %16
  br i1 %17, label %80, label %18

18:                                               ; preds = %14
  %19 = icmp eq i32 %3, 0
  br i1 %19, label %67, label %20

20:                                               ; preds = %18
  %21 = icmp eq i32 %1, 0
  br i1 %21, label %68, label %22

22:                                               ; preds = %20
  %23 = load double, ptr %2, align 8
  %24 = load double, ptr %0, align 8
  %25 = fmul double %23, %24
  %26 = icmp eq i32 %3, 1
  br i1 %26, label %69, label %27

27:                                               ; preds = %22
  %28 = icmp eq i32 %1, 1
  br i1 %28, label %70, label %29

29:                                               ; preds = %27
  %30 = getelementptr i8, ptr %2, i32 8
  %31 = load double, ptr %30, align 8
  %32 = getelementptr i8, ptr %0, i32 8
  %33 = load double, ptr %32, align 8
  %34 = fmul double %31, %33
  %35 = fadd double %25, %34
  %36 = icmp ult i32 %3, 3
  br i1 %36, label %71, label %37

37:                                               ; preds = %29
  %38 = icmp ult i32 %1, 3
  br i1 %38, label %72, label %39

39:                                               ; preds = %37
  %40 = getelementptr i8, ptr %2, i32 16
  %41 = load double, ptr %40, align 8
  %42 = getelementptr i8, ptr %0, i32 16
  %43 = load double, ptr %42, align 8
  %44 = fmul double %41, %43
  %45 = fadd double %35, %44
  %46 = icmp eq i32 %3, 3
  br i1 %46, label %73, label %47

47:                                               ; preds = %39
  %48 = icmp eq i32 %1, 3
  br i1 %48, label %74, label %49

49:                                               ; preds = %47
  %50 = icmp ult i32 %3, 5
  br i1 %50, label %75, label %51

51:                                               ; preds = %49
  %52 = icmp ult i32 %1, 5
  br i1 %52, label %76, label %sp_outcome.exit

sp_outcome.exit:                                  ; preds = %51
  %53 = getelementptr i8, ptr %2, i32 24
  %54 = load double, ptr %53, align 8
  %55 = getelementptr i8, ptr %0, i32 24
  %56 = load double, ptr %55, align 8
  %57 = fmul double %54, %56
  %58 = fadd double %45, %57
  %59 = getelementptr i8, ptr %2, i32 32
  %60 = load double, ptr %59, align 8
  %61 = fadd double %58, %60
  %62 = getelementptr i8, ptr %0, i32 32
  %63 = load double, ptr %62, align 8
  %64 = fcmp ogt double %61, 0.000000e+00
  %65 = fcmp ogt double %63, 0.000000e+00
  %.2 = select i1 %65, i32 2, i32 0
  %66 = fcmp ogt double %63, 0.000000e+00
  %. = select i1 %66, i32 3, i32 1
  %.off0 = select i1 %64, i32 %., i32 %.2
  ret i32 %.off0

67:                                               ; preds = %18
  call void @spinel_trap(i32 4, i64 0, i64 %8, ptr nonnull @sp_cstr_7)
  unreachable

68:                                               ; preds = %20
  call void @spinel_trap(i32 4, i64 0, i64 %5, ptr nonnull @sp_cstr_8)
  unreachable

69:                                               ; preds = %22
  call void @spinel_trap(i32 4, i64 1, i64 %8, ptr nonnull @sp_cstr_7)
  unreachable

70:                                               ; preds = %27
  call void @spinel_trap(i32 4, i64 1, i64 %5, ptr nonnull @sp_cstr_8)
  unreachable

71:                                               ; preds = %29
  call void @spinel_trap(i32 4, i64 2, i64 %8, ptr nonnull @sp_cstr_7)
  unreachable

72:                                               ; preds = %37
  call void @spinel_trap(i32 4, i64 2, i64 %5, ptr nonnull @sp_cstr_8)
  unreachable

73:                                               ; preds = %39
  call void @spinel_trap(i32 4, i64 3, i64 %8, ptr nonnull @sp_cstr_7)
  unreachable

74:                                               ; preds = %47
  call void @spinel_trap(i32 4, i64 3, i64 %5, ptr nonnull @sp_cstr_8)
  unreachable

75:                                               ; preds = %49
  call void @spinel_trap(i32 4, i64 4, i64 %8, ptr nonnull @sp_cstr_7)
  unreachable

76:                                               ; preds = %51
  call void @spinel_trap(i32 4, i64 4, i64 %5, ptr nonnull @sp_cstr_8)
  unreachable

77:                                               ; preds = %4
  call void @spinel_trap(i32 6, i64 %5, i64 0, ptr nonnull @sp_cstr_23)
  unreachable

78:                                               ; preds = %7
  call void @spinel_trap(i32 6, i64 %8, i64 0, ptr nonnull @sp_cstr_23)
  unreachable

79:                                               ; preds = %10
  call void @spinel_trap(i32 5, i64 %5, i64 0, ptr nonnull @sp_cstr_24)
  unreachable

80:                                               ; preds = %14
  call void @spinel_trap(i32 5, i64 %8, i64 0, ptr nonnull @sp_cstr_24)
  unreachable
}

; Function Attrs: nounwind
define double @spinel_sq_hinge_loss(ptr %0, i32 %1, ptr %2, i32 %3) #0 {
  %5 = sext i32 %1 to i64
  %6 = icmp slt i32 %1, 0
  br i1 %6, label %120, label %7

7:                                                ; preds = %4
  %8 = sext i32 %3 to i64
  %9 = icmp slt i32 %3, 0
  br i1 %9, label %121, label %10

10:                                               ; preds = %7
  %11 = icmp eq ptr %0, null
  %12 = icmp ne i32 %1, 0
  %13 = and i1 %11, %12
  br i1 %13, label %122, label %14

14:                                               ; preds = %10
  %15 = icmp eq ptr %2, null
  %16 = icmp ne i32 %3, 0
  %17 = and i1 %15, %16
  br i1 %17, label %123, label %18

18:                                               ; preds = %14
  %19 = udiv i64 %5, 5
  br label %20

20:                                               ; preds = %100, %18
  %21 = phi i64 [ %101, %100 ], [ 0, %18 ]
  %22 = phi double [ %97, %100 ], [ 0.000000e+00, %18 ]
  %23 = icmp slt i64 %21, %19
  br i1 %23, label %24, label %sp_sq_hinge_loss.exit

24:                                               ; preds = %20
  %25 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %21, i64 5)
  %26 = extractvalue { i64, i1 } %25, 1
  br i1 %26, label %102, label %27

27:                                               ; preds = %24
  %28 = extractvalue { i64, i1 } %25, 0
  %29 = icmp eq i32 %3, 0
  br i1 %29, label %103, label %30

30:                                               ; preds = %27
  %.not = icmp ult i64 %28, %5
  br i1 %.not, label %31, label %104

31:                                               ; preds = %30
  %32 = load double, ptr %2, align 8
  %33 = trunc i64 %28 to i32
  %34 = getelementptr double, ptr %0, i32 %33
  %35 = load double, ptr %34, align 8
  %36 = fmul double %32, %35
  %37 = icmp eq i32 %3, 1
  br i1 %37, label %105, label %38

38:                                               ; preds = %31
  %39 = getelementptr i8, ptr %2, i32 8
  %40 = load double, ptr %39, align 8
  %41 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %28, i64 1)
  %42 = extractvalue { i64, i1 } %41, 1
  br i1 %42, label %106, label %43

43:                                               ; preds = %38
  %44 = extractvalue { i64, i1 } %41, 0
  %.not1 = icmp ult i64 %44, %5
  br i1 %.not1, label %45, label %107

45:                                               ; preds = %43
  %46 = trunc i64 %44 to i32
  %47 = getelementptr double, ptr %0, i32 %46
  %48 = load double, ptr %47, align 8
  %49 = fmul double %40, %48
  %50 = fadd double %36, %49
  %51 = icmp ult i32 %3, 3
  br i1 %51, label %108, label %52

52:                                               ; preds = %45
  %53 = getelementptr i8, ptr %2, i32 16
  %54 = load double, ptr %53, align 8
  %55 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %28, i64 2)
  %56 = extractvalue { i64, i1 } %55, 1
  br i1 %56, label %109, label %57

57:                                               ; preds = %52
  %58 = extractvalue { i64, i1 } %55, 0
  %.not2 = icmp ult i64 %58, %5
  br i1 %.not2, label %59, label %110

59:                                               ; preds = %57
  %60 = trunc i64 %58 to i32
  %61 = getelementptr double, ptr %0, i32 %60
  %62 = load double, ptr %61, align 8
  %63 = fmul double %54, %62
  %64 = fadd double %50, %63
  %65 = icmp eq i32 %3, 3
  br i1 %65, label %111, label %66

66:                                               ; preds = %59
  %67 = getelementptr i8, ptr %2, i32 24
  %68 = load double, ptr %67, align 8
  %69 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %28, i64 3)
  %70 = extractvalue { i64, i1 } %69, 1
  br i1 %70, label %112, label %71

71:                                               ; preds = %66
  %72 = extractvalue { i64, i1 } %69, 0
  %.not3 = icmp ult i64 %72, %5
  br i1 %.not3, label %73, label %113

73:                                               ; preds = %71
  %74 = icmp ult i32 %3, 5
  br i1 %74, label %114, label %75

75:                                               ; preds = %73
  %76 = trunc i64 %72 to i32
  %77 = getelementptr double, ptr %0, i32 %76
  %78 = load double, ptr %77, align 8
  %79 = fmul double %68, %78
  %80 = fadd double %64, %79
  %81 = getelementptr i8, ptr %2, i32 32
  %82 = load double, ptr %81, align 8
  %83 = fadd double %80, %82
  %84 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %28, i64 4)
  %85 = extractvalue { i64, i1 } %84, 1
  br i1 %85, label %115, label %86

86:                                               ; preds = %75
  %87 = extractvalue { i64, i1 } %84, 0
  %.not4 = icmp ult i64 %87, %5
  br i1 %.not4, label %88, label %116

88:                                               ; preds = %86
  %89 = trunc i64 %87 to i32
  %90 = getelementptr double, ptr %0, i32 %89
  %91 = load double, ptr %90, align 8
  %92 = fmul double %91, %83
  %93 = fsub double 1.000000e+00, %92
  %94 = fcmp ogt double %93, 0.000000e+00
  %95 = fmul double %93, %93
  %96 = fadd double %22, %95
  %97 = select i1 %94, double %96, double %22
  %98 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %21, i64 1)
  %99 = extractvalue { i64, i1 } %98, 1
  br i1 %99, label %117, label %100

100:                                              ; preds = %88
  %101 = extractvalue { i64, i1 } %98, 0
  br label %20

102:                                              ; preds = %24
  call void @spinel_trap(i32 1, i64 %21, i64 5, ptr nonnull @sp_cstr_10)
  unreachable

103:                                              ; preds = %27
  call void @spinel_trap(i32 4, i64 0, i64 %8, ptr nonnull @sp_cstr_11)
  unreachable

104:                                              ; preds = %30
  call void @spinel_trap(i32 4, i64 %28, i64 %5, ptr nonnull @sp_cstr_12)
  unreachable

105:                                              ; preds = %31
  call void @spinel_trap(i32 4, i64 1, i64 %8, ptr nonnull @sp_cstr_11)
  unreachable

106:                                              ; preds = %38
  call void @spinel_trap(i32 1, i64 %28, i64 1, ptr nonnull @sp_cstr_13)
  unreachable

107:                                              ; preds = %43
  call void @spinel_trap(i32 4, i64 %44, i64 %5, ptr nonnull @sp_cstr_12)
  unreachable

108:                                              ; preds = %45
  call void @spinel_trap(i32 4, i64 2, i64 %8, ptr nonnull @sp_cstr_11)
  unreachable

109:                                              ; preds = %52
  call void @spinel_trap(i32 1, i64 %28, i64 2, ptr nonnull @sp_cstr_13)
  unreachable

110:                                              ; preds = %57
  call void @spinel_trap(i32 4, i64 %58, i64 %5, ptr nonnull @sp_cstr_12)
  unreachable

111:                                              ; preds = %59
  call void @spinel_trap(i32 4, i64 3, i64 %8, ptr nonnull @sp_cstr_11)
  unreachable

112:                                              ; preds = %66
  call void @spinel_trap(i32 1, i64 %28, i64 3, ptr nonnull @sp_cstr_13)
  unreachable

113:                                              ; preds = %71
  call void @spinel_trap(i32 4, i64 %72, i64 %5, ptr nonnull @sp_cstr_12)
  unreachable

114:                                              ; preds = %73
  call void @spinel_trap(i32 4, i64 4, i64 %8, ptr nonnull @sp_cstr_11)
  unreachable

115:                                              ; preds = %75
  call void @spinel_trap(i32 1, i64 %28, i64 4, ptr nonnull @sp_cstr_13)
  unreachable

116:                                              ; preds = %86
  call void @spinel_trap(i32 4, i64 %87, i64 %5, ptr nonnull @sp_cstr_12)
  unreachable

117:                                              ; preds = %88
  call void @spinel_trap(i32 1, i64 %21, i64 1, ptr nonnull @sp_cstr_13)
  unreachable

sp_sq_hinge_loss.exit:                            ; preds = %20
  %118 = uitofp nneg i64 %19 to double
  %119 = fdiv double %22, %118
  ret double %119

120:                                              ; preds = %4
  call void @spinel_trap(i32 6, i64 %5, i64 0, ptr nonnull @sp_cstr_26)
  unreachable

121:                                              ; preds = %7
  call void @spinel_trap(i32 6, i64 %8, i64 0, ptr nonnull @sp_cstr_26)
  unreachable

122:                                              ; preds = %10
  call void @spinel_trap(i32 5, i64 %5, i64 0, ptr nonnull @sp_cstr_27)
  unreachable

123:                                              ; preds = %14
  call void @spinel_trap(i32 5, i64 %8, i64 0, ptr nonnull @sp_cstr_27)
  unreachable
}

; Function Attrs: nounwind
define i32 @spinel_sgd_step(ptr %0, ptr %1, i32 %2, double %3) #2 {
  %5 = sext i32 %2 to i64
  %6 = icmp slt i32 %2, 0
  br i1 %6, label %37, label %7

7:                                                ; preds = %4
  %8 = icmp eq ptr %0, null
  %9 = icmp ne i32 %2, 0
  %10 = and i1 %8, %9
  br i1 %10, label %38, label %11

11:                                               ; preds = %7
  %12 = icmp eq ptr %1, null
  %13 = and i1 %12, %9
  br i1 %13, label %39, label %14

14:                                               ; preds = %11
  %15 = fcmp ogt double %3, 0.000000e+00
  %16 = fcmp ole double %3, 1.000000e+00
  %17 = select i1 %15, i1 %16, i1 false
  br i1 %17, label %18, label %sp_sgd_step.exit

18:                                               ; preds = %14, %33
  %19 = phi i64 [ %34, %33 ], [ 0, %14 ]
  %20 = icmp slt i64 %19, %5
  br i1 %20, label %21, label %sp_sgd_step.exit

21:                                               ; preds = %18
  %.not = icmp ult i64 %19, %5
  br i1 %.not, label %22, label %35

22:                                               ; preds = %21
  %23 = trunc i64 %19 to i32
  %24 = getelementptr double, ptr %0, i32 %23
  %25 = load double, ptr %24, align 8
  %26 = trunc i64 %19 to i32
  %27 = getelementptr double, ptr %1, i32 %26
  %28 = load double, ptr %27, align 8
  %29 = fmul double %3, %28
  %30 = fsub double %25, %29
  store double %30, ptr %24, align 8
  %31 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %19, i64 1)
  %32 = extractvalue { i64, i1 } %31, 1
  br i1 %32, label %36, label %33

33:                                               ; preds = %22
  %34 = extractvalue { i64, i1 } %31, 0
  br label %18

35:                                               ; preds = %21
  call void @spinel_trap(i32 4, i64 %19, i64 %5, ptr nonnull @sp_cstr_14)
  unreachable

36:                                               ; preds = %22
  call void @spinel_trap(i32 1, i64 %19, i64 1, ptr nonnull @sp_cstr_16)
  unreachable

sp_sgd_step.exit:                                 ; preds = %18, %14
  %.off0 = phi i32 [ %2, %18 ], [ -1, %14 ]
  ret i32 %.off0

37:                                               ; preds = %4
  call void @spinel_trap(i32 6, i64 %5, i64 0, ptr nonnull @sp_cstr_28)
  unreachable

38:                                               ; preds = %7
  call void @spinel_trap(i32 5, i64 %5, i64 0, ptr nonnull @sp_cstr_29)
  unreachable

39:                                               ; preds = %11
  call void @spinel_trap(i32 5, i64 %5, i64 0, ptr nonnull @sp_cstr_29)
  unreachable
}

; Function Attrs: nounwind optsize
define dso_local double @spinel_grad_sq_hinge_loss(ptr noundef %0, i32 noundef %1, ptr noundef %2, ptr noundef %3, i32 noundef %4) local_unnamed_addr #4 {
  %6 = icmp sgt i32 %4, 0
  br i1 %6, label %9, label %7

7:                                                ; preds = %9, %5
  %8 = tail call double @spinel_sq_hinge_loss(ptr noundef %0, i32 noundef %1, ptr noundef %2, i32 noundef %4) #7
  call void @diffespinel_sq_hinge_loss(ptr %0, i32 %1, ptr %2, ptr %3, i32 %4, double 1.000000e+00)
  ret double %8

9:                                                ; preds = %9, %5
  %10 = phi i32 [ %12, %9 ], [ 0, %5 ]
  %11 = getelementptr inbounds nuw double, ptr %3, i32 %10
  store double 0.000000e+00, ptr %11, align 8, !tbaa !8
  %12 = add nuw nsw i32 %10, 1
  %13 = icmp eq i32 %12, %4
  br i1 %13, label %7, label %9, !llvm.loop !10
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #5

; Function Attrs: mustprogress nounwind
define internal void @diffespinel_sq_hinge_loss(ptr %0, i32 %1, ptr %2, ptr %"'", i32 %3, double %differeturn) #6 {
invert:
  %4 = zext nneg i32 %1 to i64
  %5 = icmp sgt i32 %1, -1
  call void @llvm.assume(i1 %5)
  %6 = icmp sgt i32 %3, -1
  call void @llvm.assume(i1 %6)
  %7 = icmp ne ptr %0, null
  %8 = icmp eq i32 %1, 0
  %.not2 = or i1 %7, %8
  call void @llvm.assume(i1 %.not2)
  %9 = icmp ne ptr %2, null
  %10 = icmp eq i32 %3, 0
  %.not4 = or i1 %9, %10
  call void @llvm.assume(i1 %.not4)
  %11 = udiv i64 %4, 5
  br label %12

12:                                               ; preds = %14, %invert
  %iv.i = phi i64 [ %iv.next.i, %14 ], [ 0, %invert ]
  %iv.next.i = add nuw nsw i64 %iv.i, 1
  %13 = icmp samesign ult i64 %iv.i, %11
  br i1 %13, label %14, label %59

14:                                               ; preds = %12
  %15 = mul nuw nsw i64 %iv.i, 5
  %16 = icmp ne i32 %3, 0
  call void @llvm.assume(i1 %16)
  %17 = load double, ptr %2, align 8, !alias.scope !12, !noalias !15, !invariant.group !17
  %.not = icmp samesign ult i64 %15, %4
  call void @llvm.assume(i1 %.not)
  %18 = trunc i64 %15 to i32
  %19 = getelementptr double, ptr %0, i32 %18
  %20 = load double, ptr %19, align 8, !alias.scope !18, !noalias !21, !invariant.group !23
  %21 = fmul double %17, %20
  %22 = icmp samesign ugt i32 %3, 1
  call void @llvm.assume(i1 %22)
  %23 = getelementptr i8, ptr %2, i32 8
  %24 = load double, ptr %23, align 8, !alias.scope !12, !noalias !15, !invariant.group !24
  %25 = add nuw nsw i64 %15, 1
  %.not5 = icmp samesign ult i64 %25, %4
  call void @llvm.assume(i1 %.not5)
  %26 = trunc i64 %25 to i32
  %27 = getelementptr double, ptr %0, i32 %26
  %28 = load double, ptr %27, align 8, !alias.scope !18, !noalias !21, !invariant.group !25
  %29 = fmul double %24, %28
  %30 = fadd double %21, %29
  %31 = icmp samesign ugt i32 %3, 2
  call void @llvm.assume(i1 %31)
  %32 = getelementptr i8, ptr %2, i32 16
  %33 = load double, ptr %32, align 8, !alias.scope !12, !noalias !15, !invariant.group !26
  %34 = add nuw nsw i64 %15, 2
  %.not6 = icmp samesign ult i64 %34, %4
  call void @llvm.assume(i1 %.not6)
  %35 = trunc i64 %34 to i32
  %36 = getelementptr double, ptr %0, i32 %35
  %37 = load double, ptr %36, align 8, !alias.scope !18, !noalias !21, !invariant.group !27
  %38 = fmul double %33, %37
  %39 = fadd double %30, %38
  %40 = icmp samesign ugt i32 %3, 3
  call void @llvm.assume(i1 %40)
  %41 = getelementptr i8, ptr %2, i32 24
  %42 = load double, ptr %41, align 8, !alias.scope !12, !noalias !15, !invariant.group !28
  %43 = add nuw nsw i64 %15, 3
  %.not7 = icmp samesign ult i64 %43, %4
  call void @llvm.assume(i1 %.not7)
  %44 = trunc i64 %43 to i32
  %45 = getelementptr double, ptr %0, i32 %44
  %46 = load double, ptr %45, align 8, !alias.scope !18, !noalias !21, !invariant.group !29
  %47 = fmul double %42, %46
  %48 = fadd double %39, %47
  %49 = icmp samesign ugt i32 %3, 4
  call void @llvm.assume(i1 %49)
  %50 = getelementptr i8, ptr %2, i32 32
  %51 = load double, ptr %50, align 8, !alias.scope !12, !noalias !15, !invariant.group !30
  %52 = fadd double %48, %51
  %53 = add nuw nsw i64 %15, 4
  %.not8 = icmp samesign ult i64 %53, %4
  call void @llvm.assume(i1 %.not8)
  %54 = trunc i64 %53 to i32
  %55 = getelementptr double, ptr %0, i32 %54
  %56 = load double, ptr %55, align 8, !alias.scope !18, !noalias !21, !invariant.group !31
  %57 = fmul double %56, %52
  %58 = fcmp olt double %57, 1.000000e+00
  br label %12

59:                                               ; preds = %12
  %60 = uitofp nneg i64 %11 to double
  %61 = fdiv double %differeturn, %60
  %62 = fadd double %61, 0.000000e+00
  br label %invert1.i

invert1.i:                                        ; preds = %59, %invert2.i
  %"'de45.i.0" = phi double [ 0.000000e+00, %59 ], [ %"'de45.i.1", %invert2.i ]
  %"'de9.i.0" = phi double [ %62, %59 ], [ %"'de9.i.1", %invert2.i ]
  %"iv'ac.i.0" = phi i64 [ %11, %59 ], [ %65, %invert2.i ]
  %63 = icmp eq i64 %"iv'ac.i.0", 0
  br i1 %63, label %diffesp_sq_hinge_loss.exit, label %incinvert1.i

incinvert1.i:                                     ; preds = %invert1.i
  %64 = fadd double %"'de9.i.0", 0.000000e+00
  %65 = add nsw i64 %"iv'ac.i.0", -1
  %_unwrap86.i = mul i64 %65, 5
  %66 = trunc i64 %_unwrap86.i to i32
  %67 = getelementptr double, ptr %0, i32 %66
  %_unwrap88.i = getelementptr i8, ptr %67, i32 32
  %_unwrap89.i = load double, ptr %_unwrap88.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !31
  %_unwrap91.i = load double, ptr %2, align 8, !alias.scope !12, !noalias !15, !invariant.group !17
  %68 = trunc i64 %_unwrap86.i to i32
  %_unwrap92.i = getelementptr double, ptr %0, i32 %68
  %_unwrap93.i = load double, ptr %_unwrap92.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !23
  %_unwrap94.i = fmul double %_unwrap91.i, %_unwrap93.i
  %_unwrap95.i = getelementptr i8, ptr %2, i32 8
  %_unwrap96.i = load double, ptr %_unwrap95.i, align 8, !alias.scope !12, !noalias !15, !invariant.group !24
  %69 = trunc i64 %_unwrap86.i to i32
  %70 = getelementptr double, ptr %0, i32 %69
  %_unwrap98.i = getelementptr i8, ptr %70, i32 8
  %_unwrap99.i = load double, ptr %_unwrap98.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !25
  %_unwrap100.i = fmul double %_unwrap96.i, %_unwrap99.i
  %_unwrap101.i = fadd double %_unwrap94.i, %_unwrap100.i
  %_unwrap102.i = getelementptr i8, ptr %2, i32 16
  %_unwrap103.i = load double, ptr %_unwrap102.i, align 8, !alias.scope !12, !noalias !15, !invariant.group !26
  %71 = trunc i64 %_unwrap86.i to i32
  %72 = getelementptr double, ptr %0, i32 %71
  %_unwrap105.i = getelementptr i8, ptr %72, i32 16
  %_unwrap106.i = load double, ptr %_unwrap105.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !27
  %_unwrap107.i = fmul double %_unwrap103.i, %_unwrap106.i
  %_unwrap108.i = fadd double %_unwrap101.i, %_unwrap107.i
  %_unwrap109.i = getelementptr i8, ptr %2, i32 24
  %_unwrap110.i = load double, ptr %_unwrap109.i, align 8, !alias.scope !12, !noalias !15, !invariant.group !28
  %73 = trunc i64 %_unwrap86.i to i32
  %74 = getelementptr double, ptr %0, i32 %73
  %_unwrap112.i = getelementptr i8, ptr %74, i32 24
  %_unwrap113.i = load double, ptr %_unwrap112.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !29
  %_unwrap114.i = fmul double %_unwrap110.i, %_unwrap113.i
  %_unwrap115.i = fadd double %_unwrap108.i, %_unwrap114.i
  %_unwrap116.i = getelementptr i8, ptr %2, i32 32
  %_unwrap117.i = load double, ptr %_unwrap116.i, align 8, !alias.scope !12, !noalias !15, !invariant.group !30
  %_unwrap118.i = fadd double %_unwrap115.i, %_unwrap117.i
  %_unwrap119.i = fmul double %_unwrap89.i, %_unwrap118.i
  %_unwrap120.i = fsub double 1.000000e+00, %_unwrap119.i
  %_unwrap121.i = fcmp ogt double %_unwrap120.i, 0.000000e+00
  %75 = select i1 %_unwrap121.i, double 0.000000e+00, double %64
  %76 = fadd double %"'de45.i.0", %64
  %77 = select i1 %_unwrap121.i, double %76, double %"'de45.i.0"
  br i1 %_unwrap121.i, label %invert3.i, label %invert2.i

invert2.i:                                        ; preds = %incinvert1.i, %invert3.i
  %"'de45.i.1" = phi double [ 0.000000e+00, %invert3.i ], [ %77, %incinvert1.i ]
  %"'de11.i.1" = phi double [ %103, %invert3.i ], [ 0.000000e+00, %incinvert1.i ]
  %"'de9.i.1" = phi double [ %99, %invert3.i ], [ %75, %incinvert1.i ]
  %78 = fsub double 0.000000e+00, %"'de11.i.1"
  %_unwrap15.i = load double, ptr %_unwrap88.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !31
  %79 = fmul double %78, %_unwrap15.i
  %80 = fadd double %79, 0.000000e+00
  %"'ipg_unwrap.i" = getelementptr i8, ptr %"'", i32 32
  %81 = load double, ptr %"'ipg_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %82 = fadd double %81, %80
  store double %82, ptr %"'ipg_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %_unwrap23.i = load double, ptr %_unwrap112.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !29
  %83 = fmul double %80, %_unwrap23.i
  %84 = fadd double %83, 0.000000e+00
  %"'ipg25_unwrap.i" = getelementptr i8, ptr %"'", i32 24
  %85 = load double, ptr %"'ipg25_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %86 = fadd double %85, %84
  store double %86, ptr %"'ipg25_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %_unwrap30.i = load double, ptr %_unwrap105.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !27
  %87 = fmul double %80, %_unwrap30.i
  %88 = fadd double %87, 0.000000e+00
  %"'ipg32_unwrap.i" = getelementptr i8, ptr %"'", i32 16
  %89 = load double, ptr %"'ipg32_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %90 = fadd double %89, %88
  store double %90, ptr %"'ipg32_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %_unwrap37.i = load double, ptr %_unwrap98.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !25
  %91 = fmul double %80, %_unwrap37.i
  %92 = fadd double %91, 0.000000e+00
  %"'ipg39_unwrap.i" = getelementptr i8, ptr %"'", i32 8
  %93 = load double, ptr %"'ipg39_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %94 = fadd double %93, %92
  store double %94, ptr %"'ipg39_unwrap.i", align 8, !alias.scope !15, !noalias !12
  %_unwrap41.i = load double, ptr %_unwrap92.i, align 8, !alias.scope !18, !noalias !21, !invariant.group !23
  %95 = fmul double %80, %_unwrap41.i
  %96 = fadd double %95, 0.000000e+00
  %97 = load double, ptr %"'", align 8, !alias.scope !15, !noalias !12
  %98 = fadd double %97, %96
  store double %98, ptr %"'", align 8, !alias.scope !15, !noalias !12
  br label %invert1.i

invert3.i:                                        ; preds = %incinvert1.i
  %99 = fadd double %75, %77
  %100 = fadd double %77, 0.000000e+00
  %101 = fmul double %100, %_unwrap120.i
  %102 = fadd double %101, 0.000000e+00
  %103 = fadd double %102, %101
  br label %invert2.i

diffesp_sq_hinge_loss.exit:                       ; preds = %invert1.i
  ret void
}

attributes #0 = { nounwind "enzyme_ReadOnlyOrThrow" }
attributes #1 = { cold noreturn nounwind }
attributes #2 = { nounwind }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind optsize "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m33" "target-features"="+armv8-m.main,+hwdiv,+soft-float,+thumb-mode,-aes,-bf16,-cdecp0,-cdecp1,-cdecp2,-cdecp3,-cdecp4,-cdecp5,-cdecp6,-cdecp7,-crc,-crypto,-d32,-dotprod,-dsp,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-hwdiv-arm,-i8mm,-lob,-mve,-mve.fp,-neon,-pacbti,-ras,-sb,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" "use-soft-float"="true" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #6 = { mustprogress nounwind }
attributes #7 = { nobuiltin nounwind optsize "no-builtins" }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 1, !"min_enum_size", i32 1}
!3 = !{!"Homebrew clang version 22.1.8"}
!4 = !{!5, !5, i64 0}
!5 = !{!"int", !6, i64 0}
!6 = !{!"omnipotent char", !7, i64 0}
!7 = !{!"Simple C/C++ TBAA"}
!8 = !{!9, !9, i64 0}
!9 = !{!"double", !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!13}
!13 = distinct !{!13, !14, !"primal"}
!14 = distinct !{!14, !" diff: %"}
!15 = !{!16}
!16 = distinct !{!16, !14, !"shadow_0"}
!17 = distinct !{}
!18 = !{!19}
!19 = distinct !{!19, !20, !"primal"}
!20 = distinct !{!20, !" diff: %"}
!21 = !{!22}
!22 = distinct !{!22, !20, !"shadow_0"}
!23 = distinct !{}
!24 = distinct !{}
!25 = distinct !{}
!26 = distinct !{}
!27 = distinct !{}
!28 = distinct !{}
!29 = distinct !{}
!30 = distinct !{}
!31 = distinct !{}
