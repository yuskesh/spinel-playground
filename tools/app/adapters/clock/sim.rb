# tools/app/adapters/clock/sim.rb -- the Clock simulator template for CRuby:
# the runner's virtual clock, read through the board-host clock hook.
module %MODULE%
  def self.uptime_us = CoreApp::BoardHost.clock_us
  def self.cycles = CoreApp::BoardHost.clock_us
  # the low 32 bits of the same count, as a signed i32 pattern
  def self.cycles32 = ((CoreApp::BoardHost.clock_us + 2_147_483_648) % 4_294_967_296) - 2_147_483_648
end
