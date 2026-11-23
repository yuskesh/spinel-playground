# tests/compute/plant_unsigned.rb HOST.rb -- plant a fault in a generated WebGPU host.
#
# Puts back what naga writes without the SPIR-V exit's signed casts: division
# and arithmetic shift on u32. The suite requires the host to notice.
path = ARGV.fetch(0)
s = File.read(path)
n = 0
s.gsub!(/bitcast<u32>\(\(bitcast<i32>\((\w+)\) \/ bitcast<i32>\((\w+)\)\)\)/) { n += 1; "(#{$1} / #{$2})" }
s.gsub!(/bitcast<u32>\(\(bitcast<i32>\((\w+)\) >> bitcast<u32>\((\w+)\)\)\)/) { n += 1; "(#{$1} >> bitcast<u32>(#{$2}))" }
abort "plant_unsigned: nothing to plant in #{path}" if n.zero?
File.write(path, s)
