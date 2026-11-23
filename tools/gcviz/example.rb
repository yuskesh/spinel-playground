# tools/gcviz/example.rb -- the program the GC animation replays.
#
# Each round makes short-lived objects (a batch of particles and a label
# string) that die young, and every third round keeps one particle in a
# small registry. A kept particle survives a minor collection and is
# promoted to old; when the registry drops it, only a major collection
# frees it. gcviz_mark(n) records "round n ended" in the event file.

def gcviz_mark(id)
  id
end

class Particle
  attr_reader :x, :y

  def initialize(x, y)
    @x = x
    @y = y
  end
end

keep = []
gcviz_mark(0)
40.times do |round|
  batch = []
  60.times { |i| batch << Particle.new(i, round) }
  label = "round-" + round.to_s
  keep << Particle.new(round, label.size) if round % 3 == 0
  keep.shift if keep.size > 6
  gcviz_mark(round + 1)
end
puts keep.size
