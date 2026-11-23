# tools/gcmon/gcmon_stub.rb — the CRuby face of gcmon_begin / gcmon_end.
#
# Under Spinel, vendor Patch 1 (SPINEL_EXTERN_METHODS) replaces these two
# methods with external symbols. CRuby has no such thing, so a differential run
# of the same subject program under CRuby requires this file to get no-ops:
#
#   require_relative "../../tools/gcmon/gcmon_stub"
#
# They return their argument, the same shape as the canonical value ABI
# (sp_int(sp_int)), so a subject that uses the return value behaves the same on
# both.
#
# That differential run is an ORACLE (AGENTS.md). This file is kept, and nothing
# in this repository runs it; only the owner starts an oracle.

def gcmon_begin(id)
  id
end

def gcmon_end(id)
  id
end
