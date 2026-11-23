# frozen_string_literal: true
# tests/gcviz/plant.rb KIND IN OUT -- writes a copy of an events file with one
# planted defect, for tests/gcviz/run.sh's controls.
#   orphan-sweep   the first sweep record (a slab sweep, else a list sweep)
#                  names a slot nothing allocated
#   no-census      the census records at exit are removed
#   double-alloc   the first object allocation is recorded twice
#   no-site        the first allocation loses the stack frames recorded with it
#   no-pool        the first header taken back from a pool goes unrecorded,
#                  with its stack frames
require_relative '../../tools/gcviz/gcviz-events'

kind, src, dst = ARGV
abort 'usage: plant.rb orphan-sweep|no-census|double-alloc|no-site|no-pool IN OUT' unless dst
data = File.binread(src)
head = data.byteslice(0, 32)
recs = Array.new(data.unpack1('Q<', offset: 16)) { |i| data.byteslice(32 + i * 32, 32) }
what = ->(r) { r.unpack1('S<', offset: 28) }
case kind
when 'orphan-sweep'
  i = (recs.index { |r| what.(r) == 7 } || recs.index { |r| what.(r) == 17 }) or abort 'no sweep record'
  r = recs[i].dup
  r[8, 8] = [0x10].pack('Q<')
  recs[i] = r
when 'no-census'
  recs.reject! { |r| what.(r) == 200 }
when 'double-alloc'
  i = recs.index { |r| [1, 11].include?(what.(r)) } or abort 'no allocation record'
  recs.insert(i + 1, recs[i])
when 'no-site', 'no-pool'
  codes = kind == 'no-pool' ? [14] : [1, 11]
  i = recs.index { |r| codes.include?(what.(r)) } or abort 'no allocation record'
  j = i + 1
  j += 1 while j < recs.size && what.(recs[j]) == 400
  abort 'the first allocation has no stack frames' if j == i + 1
  recs.slice!((kind == 'no-pool' ? i : i + 1)...j)
else
  abort "unknown kind #{kind}"
end
head = head.dup
head[16, 8] = [recs.size].pack('Q<')
File.binwrite(dst, head + recs.join)
