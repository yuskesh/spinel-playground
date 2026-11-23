# generated board package for expander (decision 0014 §3): declarations.
# Each module carries its own constants (0014 D5: Led::COUNT, Led::LED0).
module Clock
  COUNT = 1
  TIMER_E000E010 = 0
  core_extern :uptime_us, params: {}, returns: :i64, isr_ok: true,
              bound: "iterations 1", provider: "clock/adapter.c"
  core_extern :cycles, params: {}, returns: :i64, isr_ok: true,
              bound: "iterations 1", provider: "clock/adapter.c"
  core_extern :cycles32, params: {}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "clock/adapter.c"
end
module Led
  COUNT = 2
  LED_0 = 0
  LED0 = 0
  LED_1 = 1
  LED1 = 1
  core_extern :set, params: {index: :u32, duty: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "led/adapter.c", guards: ["index < 2 else bounds"]
end
module LedI2c
  COUNT = 1
  LED_EXT = 0
  LED2 = 0
  EXTLED = 0
  core_extern :set, params: {index: :u32, duty: :u32}, returns: :i32, isr_ok: false,
              bound: "iterations 1", provider: "led/adapter.c", guards: ["index < 1 else bounds"]
end
