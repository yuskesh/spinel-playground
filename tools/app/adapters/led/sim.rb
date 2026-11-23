# tools/app/adapters/led/sim.rb -- the Led simulator template for CRuby.
# %MODULE% and %COUNT% are filled by the board generator; the module keeps
# what each LED was last set to, for the trace's extern records and the
# fixtures to read.
module %MODULE%
  DUTY = Array.new(%COUNT%, 0)
  def self.set(index, duty)
    DUTY[index] = duty
    0
  end
end
CoreApp::BoardHost.reset { %MODULE%::DUTY.fill(0) }
