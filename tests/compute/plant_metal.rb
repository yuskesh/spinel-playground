# tests/compute/plant_metal.rb -- plant a fault in a generated Metal host.
#
#   plant_metal.rb bindings HOST.rb
#       puts back what naga writes: no buffer has a binding of its own.
#   plant_metal.rb shared HOST.rb SOURCE.m COPY.m
#       points HOST.rb at a copy of the host that sets no shared memory length.
#
# The suite requires the kernels that depend on each to notice. The fault is in
# the copy, so the product carries no test switch.
mode = ARGV.fetch(0)
path = ARGV.fetch(1)
s = File.read(path)
case mode
when "bindings"
  abort "plant_metal: nothing to plant in #{path}" unless s.gsub!(/\[\[buffer\(\d+\)\]\]/, "[[user(fake0)]]")
when "shared"
  source = ARGV.fetch(2)
  copy = ARGV.fetch(3)
  kept = File.readlines(source).reject { |l| l.include?("setThreadgroupMemoryLength") && l.include?("encoder") }
  abort "plant_metal: nothing to remove from #{source}" if kept.size == File.readlines(source).size
  abort "plant_metal: #{path} does not name #{source}" unless s.sub!(source, copy)
  File.write(copy, kept.join)
else
  abort "plant_metal: unknown mode #{mode}"
end
File.write(path, s)
