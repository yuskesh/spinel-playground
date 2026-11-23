# frozen_string_literal: true
#
# tests/doom-core/zone-alias.rb — the schema's array-bank `#alias` lines, on the objects a library builds.
#
#   ruby tests/doom-core/zone-alias.rb LIBDIR
#
# The schema records five array-bank aliases, each a JobExecutor ivar that is
# a Jobs bank. The executor also keeps the actual Jobs owner, whose live ring
# it reads without exporting a String. Require object identity for both
# contracts; equal bytes are insufficient. This builds only a Jobs and a
# JobExecutor, so it checks only the aliases whose ivar is JobExecutor's; the
# others (decision 0021's StatusBar@@data and Hud@@data) are checked on the
# program's own objects by state.sh's reference. The count it checks is
# printed, so an alias added to or lost from the bank changes the line.
ROOT = File.expand_path("../..", __dir__)
lib = ARGV[0] or abort("usage: zone-alias.rb LIBDIR")
%w[jobs executor].each { |f| require File.join(lib, f) }
require File.join(ROOT, "examples/doom/core/full/reference")
R = Doom::Core::Reference
jobs = Doom::Jobs.new(320, 200)
exec = Doom::JobExecutor.new(jobs, "\0".b * 8704, "".b, "".b, "".b, Array.new(50, 0), 320, 0, 0, 168)
begin
  bank = R.read_aliases(File.join(ROOT, "examples/doom/core/state.tsv")).select { |src, _, _| src.start_with?("JobExecutor@@") }
  n = R.check_aliases(bank, { "Jobs" => jobs, "JobExecutor" => exec })
  exec.instance_variable_get(:@jobs).equal?(jobs) or
    raise R::ReferenceError, "JobExecutor@@jobs is not the Jobs owner of jobs_zonebuf"
  puts "aliases #{n} identical; ring owner identical"
rescue R::ReferenceError => e
  puts "aliases refused #{e.message}"
end
