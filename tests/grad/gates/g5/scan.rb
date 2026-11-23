# Applies spinel-gradgen's G5 scan (g5_scan) to a module and prints, per
# adjoint, the sites it counts, the int-derived nnan/ninf it sets apart, and
# the counted flags.
#
#   ruby scan.rb <spinel-gradgen> <module.ll>
load ARGV[0]

dtext = File.read(ARGV[1])
names = dtext.scan(/^define[^\n]*@((?:fwd)?diffe\w+)/).flatten
puts "function\tsites\tint_derived\tflags"
names.each do |n|
  sites, int_derived = g5_scan(dtext, [n])
  flags = sites.flat_map { |s| s[1] }.uniq
  puts [n, sites.size, int_derived.size, flags.empty? ? "-" : flags.join(",")].join("\t")
end
