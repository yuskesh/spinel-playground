define internal void @diffesp_oint(i64 noundef %0, i64 noundef %1) #48 {
invert:
  %2 = icmp ne i64 %1, -9223372036854775808
  %3 = icmp ne i64 %0, -9223372036854775808
  call void @llvm.assume(i1 %3)
  call void @llvm.assume(i1 %2)
  %4 = mul nsw i64 %1, %0
  %5 = icmp ne i64 %4, -9223372036854775808
  call void @llvm.assume(i1 %5)
  ret void
}