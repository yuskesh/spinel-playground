# generated board package: the simulators for CRuby.
require "core_app/board_host"
module Adc
  COUNT = 2
  CH0 = 0
  CH1 = 1
end
module Adc
  MILLIVOLTS = Array.new(2, 0)
  def self.latest(index) = MILLIVOLTS[index]
end
CoreApp::BoardHost.stimulus(:adc) { |channel, mv| Adc::MILLIVOLTS[channel] = mv if channel < 2 }
CoreApp::BoardHost.reset { Adc::MILLIVOLTS.fill(0) }
module Button
  COUNT = 2
  BUTTON_0 = 0
  SW0 = 0
  SPINEL_SW0 = 0
  BUTTON_1 = 1
  SW1 = 1
  SPINEL_SW1 = 1
end
module Button
  LEVEL = Array.new(2, 0)
  def self.read(index) = LEVEL[index]
end
CoreApp::BoardHost.stimulus(:gpio) { |pin, level| Button::LEVEL[pin] = level if pin < 2 }
CoreApp::BoardHost.reset { Button::LEVEL.fill(0) }
module Clock
  COUNT = 1
  TIMER_E000E010 = 0
end
module Clock
  def self.uptime_us = CoreApp::BoardHost.clock_us
  def self.cycles = CoreApp::BoardHost.clock_us
end
module Led
  COUNT = 2
  LED_0 = 0
  LED0 = 0
  USERLED0 = 0
  LED_1 = 1
  LED1 = 1
  USERLED1 = 1
end
module Led
  DUTY = Array.new(2, 0)
  def self.set(index, duty)
    DUTY[index] = duty
    0
  end
end
CoreApp::BoardHost.reset { Led::DUTY.fill(0) }
