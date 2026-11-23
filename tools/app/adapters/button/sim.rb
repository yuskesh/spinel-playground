# tools/app/adapters/button/sim.rb -- the Button simulator template for CRuby.
# The `gpio` stimulus sets a button's level; `read` returns it.
module %MODULE%
  LEVEL = Array.new(%COUNT%, 0)
  def self.read(index) = LEVEL[index]
end
CoreApp::BoardHost.stimulus(:gpio) { |pin, level| %MODULE%::LEVEL[pin] = level if pin < %COUNT% }
CoreApp::BoardHost.reset { %MODULE%::LEVEL.fill(0) }
