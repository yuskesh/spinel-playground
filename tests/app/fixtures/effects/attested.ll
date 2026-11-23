; tests/app/fixtures/effects/attested.ll -- a defined entry with an 8-byte
; frame that calls a function this IR only declares: an extern, whose frame
; is bound evidence or nothing.
declare i32 @spc_board_adc_latest(i32) nounwind

define i32 @spinel_core_probe(i32 %ch) nounwind {
  %slot = alloca i64, align 8
  store volatile i64 0, ptr %slot
  %v = call i32 @spc_board_adc_latest(i32 %ch)
  ret i32 %v
}
