# The synthetic board package (decision 0014 plan, Task 6): what Task 7's
# generator will write for a real DTS, hand-written for the host fixtures.
# One module per device class; `index` is the instance in board.tsv.
module Adc
  core_extern :latest, params: {index: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "adapters/adc/adc.c"
end
module Button
  # 0014 D5: the constants a generated package carries, in their own module
  COUNT = 2
  SW0 = 0
  SW1 = 1
  core_extern :read, params: {index: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "adapters/button/button.c"
end
module Led
  COUNT = 2
  LED0 = 0
  LED1 = 1
  core_extern :set, params: {index: :u32, duty: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "adapters/led/led.c"
end
module Pwm
  core_extern :set, params: {index: :u32, value: :u32}, returns: :i32, isr_ok: false,
              bound: "iterations 1", provider: "adapters/pwm/pwm.c"
end
module Flash
  core_extern :erase, params: {index: :u32}, returns: :i32, isr_ok: false,
              bound: "iterations 1", provider: "adapters/flash/flash.c"
end
