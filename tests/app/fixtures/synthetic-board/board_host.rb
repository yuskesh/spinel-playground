# The synthetic board under CRuby: the same modules with simulator bodies.
# The stimulus reaches Adc and Button through CoreApp::BoardHost; Led and Pwm
# keep what was last set, for the trace's extern records to show.
require "core_app/board_host"

module Adc
  VALUES = [0, 0]
  def self.latest(index) = VALUES.fetch(index)
end
module Button
  COUNT = 2
  SW0 = 0
  SW1 = 1
  LEVELS = [0, 0]
  def self.read(index) = LEVELS.fetch(index)
end
module Led
  COUNT = 2
  LED0 = 0
  LED1 = 1
  DUTY = [0, 0]
  def self.set(index, duty)
    DUTY[index] = duty
    0
  end
end
module Pwm
  VALUE = [0]
  def self.set(index, value)
    VALUE[index] = value
    0
  end
end
module Flash
  def self.erase(_index) = 0
end
CoreApp::BoardHost.stimulus(:adc) { |channel, mv| Adc::VALUES[channel] = mv }
CoreApp::BoardHost.stimulus(:gpio) { |pin, level| Button::LEVELS[pin] = level }
CoreApp::BoardHost.reset do
  Adc::VALUES.fill(0)
  Button::LEVELS.fill(0)
  Led::DUTY.fill(0)
  Pwm::VALUE.fill(0)
end
