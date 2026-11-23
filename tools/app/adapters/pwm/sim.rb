# tools/app/adapters/pwm/sim.rb -- the Pwm simulator template for CRuby.
module %MODULE%
  VALUE = Array.new(%COUNT%, 0)
  def self.set(index, value)
    VALUE[index] = value > 65535 ? 65535 : value
    0
  end
end
CoreApp::BoardHost.reset { %MODULE%::VALUE.fill(0) }
