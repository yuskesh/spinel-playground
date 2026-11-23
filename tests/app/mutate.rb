#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tests/app/mutate.rb -- the mutation controls of decision 0014 §10, applied
# to a verification run's text trace (verify/trace.txt): each mutation
# plants one of the defects the checks must catch, and
# `spinel-core-app verify --trace-text` must fail it with the check's own
# diagnostic. The sequence numbers are renumbered after a mutation that is
# not about the sequence itself, so the check named catches it, not the
# gap check.
#
#   ruby tests/app/mutate.rb <mutation> in.txt out.txt
#
# The mutations, by name:
#   drop-inbound-silent     an inbound message's ENQ and RX removed: the item appears nowhere
#   drop-inbound-counted    an inbound message's ENQ and RX replaced by a DROP channel_full at an occupancy below depth
#   full-drop-below-depth   a DROP channel_full inserted while the channel's occupancy is below depth
#   duplicate-message       an ENQ record duplicated (the same message enqueued twice)
#   corrupt-payload         one byte of a DEQ's payload changed
#   load-older-value        a LOAD's value replaced by an older store's
#   load-regresses          a later LOAD replaced by an earlier value after a newer one was observed
#   truncate                the trace cut before its end marker
#   no-end-marker           the end marker removed
#   drain-timed-out         the end marker's drained flag cleared
#   overflow                an OVERFLOW record inserted
#   select-older-release    a SELECT's release lowered below what its clock reading allows
#   unjustified-skip        a SELECT's skipped range widened past what its clock reading justifies
#   release-unclassified    an invocation's SELECT, START and END removed, leaving its release with no class
#   cancel-without-fail     a CANCEL inserted naming a sequence number that is no FAIL
#   selected-never-started  a selection kept, its invocation's START, END and body removed: selected, never run
#   sequence-gap            one interior record removed with the numbering kept
require_relative "../../tools/app/lib/core_app/trace"

name, inp, outp = ARGV
abort "usage: mutate.rb <mutation> in.txt out.txt" unless name && inp && outp
recs = CoreApp::Trace.from_text_file(inp)
find = ->(kind, &blk) { recs.find { |r| r.kind == kind && (blk.nil? || blk.call(r)) } or abort "#{inp}: no #{kind} record to mutate" }
renumber = true

case name
when "drop-inbound-silent"
  rx = find.call("RX")
  enq = recs.reverse.find { |r| r.kind == "ENQ" && r.seq < rx.seq && r[:channel] == rx[:channel] } or abort "no ENQ before the RX"
  recs.delete(rx); recs.delete(enq)
when "drop-inbound-counted"
  rx = find.call("RX")
  enq = recs.reverse.find { |r| r.kind == "ENQ" && r.seq < rx.seq && r[:channel] == rx[:channel] } or abort "no ENQ before the RX"
  recs.delete(enq)
  rx.kind = "DROP"
  rx.fields.delete(:length)
  rx.fields[:reason] = CoreApp::Trace::DROP_CHANNEL_FULL
when "full-drop-below-depth"
  rx = find.call("RX")
  # one defect only: the same item as the RX, so the occupancy rule is what names it
  d = CoreApp::Trace::Record.new(seq: 0, kind: "DROP", context: rx.context, entry: rx.entry, fields: { channel: rx[:channel], stimulus_id: rx[:stimulus_id], reason: CoreApp::Trace::DROP_CHANNEL_FULL })
  recs.insert(recs.index(rx) + 1, d)
when "duplicate-message"
  enq = find.call("ENQ") { |r| r[:result] == CoreApp::Trace::ENQ_QUEUED }
  recs.insert(recs.index(enq) + 1, CoreApp::Trace::Record.new(seq: 0, kind: "ENQ", context: enq.context, entry: enq.entry, fields: enq.fields.dup))
when "corrupt-payload"
  deq = find.call("DEQ") { |r| r[:result] == CoreApp::Trace::DEQ_DEQUEUED && r[:length] > 0 }
  deq.fields[:payload] = deq[:payload].dup.tap { |p| p[0] ^= 0x5a }
when "load-older-value"
  ld = find.call("LOAD") { |r| recs.count { |s| s.kind == "STORE" && s.seq < r.seq && s[:state] == r[:state] && s[:index] == r[:index] && s[:value] != r[:value] } > 0 }
  older = recs.select { |s| s.kind == "STORE" && s.seq < ld.seq && s[:state] == ld[:state] && s[:index] == ld[:index] && s[:value] != ld[:value] }.last
  ld.fields[:value] = older[:value]
when "load-regresses"
  # the last such pair, so this control and load-older-value touch different records
  loads = recs.select { |r| r.kind == "LOAD" }
  pair = loads.each_cons(2).select { |a, b| a[:state] == b[:state] && a[:index] == b[:index] && a[:value] != b[:value] }.last or abort "no two loads of one element with different values"
  pair[1].fields[:value] = pair[0][:value]
when "truncate"
  recs = recs[0, recs.size - 5]
  renumber = false
when "no-end-marker"
  recs.delete(find.call("ENDMARK"))
when "drain-timed-out"
  find.call("ENDMARK").fields[:drained] = 0
when "overflow"
  e = find.call("ENDMARK")
  recs.insert(recs.index(e), CoreApp::Trace::Record.new(seq: 0, kind: "OVERFLOW", context: 1, entry: 255, fields: { context: 5 }))
when "select-older-release"
  sel = find.call("SELECT") { |r| r[:release] > 1 }
  sel.fields[:release] -= 1
when "unjustified-skip"
  sel = find.call("SELECT") { |r| r[:release] > 1 && r[:skipped_from].zero? }
  sel.fields[:skipped_from] = 1
  sel.fields[:skipped_to] = sel[:release] - 1
when "release-unclassified"
  # the entry's last run: no later selection recomputes it, so its class is simply missing
  sel = recs.select { |r| r.kind == "SELECT" && r[:release] > 0 }.max_by { |r| [r[:release], r.seq] }
  st = recs.find { |r| r.kind == "START" && r.seq > sel.seq && r.context == sel.context && r.entry == sel.entry }
  en = recs.find { |r| r.kind == "END" && r.seq > st.seq && r.context == sel.context && r.entry == sel.entry }
  inside = recs.select { |r| r.seq > st.seq && r.seq < en.seq && r.context == sel.context && r.entry == sel.entry }
  ([sel, st, en] + inside).each { |r| recs.delete(r) }
  # the entry's later selections would name this release as run; lower nothing: the class is simply missing
when "selected-never-started"
  # the entry's last selection kept, its START, END and everything between removed
  sel = recs.select { |r| r.kind == "SELECT" && r[:release] > 0 }.max_by { |r| [r[:release], r.seq] }
  st = recs.find { |r| r.kind == "START" && r.seq > sel.seq && r.context == sel.context && r.entry == sel.entry }
  en = recs.find { |r| r.kind == "END" && r.seq > st.seq && r.context == sel.context && r.entry == sel.entry }
  inside = recs.select { |r| r.seq > st.seq && r.seq < en.seq && r.context == sel.context && r.entry == sel.entry }
  ([st, en] + inside).each { |r| recs.delete(r) }
when "sequence-gap"
  # one interior record removed and the numbering kept: the gap itself
  recs.delete_at(recs.size / 2)
  renumber = false
when "cancel-without-fail"
  e = find.call("ENDMARK")
  sel = find.call("SELECT") { |r| r[:release] > 0 }
  recs.insert(recs.index(e), CoreApp::Trace::Record.new(seq: 0, kind: "CANCEL", context: sel.context, entry: sel.entry, fields: { entry: sel.entry, from: sel[:release] + 1000, to: sel[:release] + 1001, fail_seq: 7 }))
else
  abort "unknown mutation #{name}"
end
recs.each_with_index { |r, i| r.seq = i } if renumber
File.write(outp, recs.map(&:line).join("\n") + "\n")
