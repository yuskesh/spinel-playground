# tools/app/adapters/adc/sim.rb -- the Adc simulator template for CRuby.
# The `adc` stimulus publishes a channel's millivolts; `latest` reads it.
module %MODULE%
  MILLIVOLTS = Array.new(%COUNT%, 0)
  def self.latest(index) = MILLIVOLTS[index]
end
CoreApp::BoardHost.stimulus(:adc) { |channel, mv| %MODULE%::MILLIVOLTS[channel] = mv if channel < %COUNT% }
CoreApp::BoardHost.reset { %MODULE%::MILLIVOLTS.fill(0) }
