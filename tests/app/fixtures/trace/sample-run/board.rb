# generated board package for mps2_an521 (decision 0014 §3): declarations.
# Each module carries its own constants (0014 D5: Led::COUNT, Led::LED0).
module Adc
  COUNT = 2
  CH0 = 0
  CH1 = 1
  core_extern :latest, params: {index: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "adc/adapter.c", guards: ["index < 2 else bounds"]
end
module Button
  COUNT = 2
  BUTTON_0 = 0
  SW0 = 0
  SPINEL_SW0 = 0
  BUTTON_1 = 1
  SW1 = 1
  SPINEL_SW1 = 1
  core_extern :read, params: {index: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "button/adapter.c", guards: ["index < 2 else bounds"]
end
module Clock
  COUNT = 1
  TIMER_E000E010 = 0
  core_extern :uptime_us, params: {}, returns: :i64, isr_ok: true,
              bound: "iterations 1", provider: "clock/adapter.c"
  core_extern :cycles, params: {}, returns: :i64, isr_ok: true,
              bound: "iterations 1", provider: "clock/adapter.c"
end
module Led
  COUNT = 2
  LED_0 = 0
  LED0 = 0
  USERLED0 = 0
  LED_1 = 1
  LED1 = 1
  USERLED1 = 1
  core_extern :set, params: {index: :u32, duty: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "led/adapter.c", guards: ["index < 2 else bounds"]
end
