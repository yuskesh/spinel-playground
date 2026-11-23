# frozen_string_literal: true
#
# tools/doom/nor-image.rb — one demo's board image: the program and its session, as the NOR holds them.
#
#   ruby tools/doom/nor-image.rb --firmware DIR --image DIR --out FILE [--llvm PREFIX]
#
# Decision 0021, one demo per write. --firmware is a core_session build's
# published firmware (spinel-core-app build ... --session-image), --image the
# session image it was built for. The NOR image is
#
#   the launcher's offset     launcher.bin, on a board whose application is
#                             a second core's (build.json `launcher`; the
#                             FRDM-IMXRT1186's M33 image of decision 0023,
#                             with the FlexSPI boot header);
#   CONFIG_FLASH_LOAD_OFFSET  zephyr.bin, as Zephyr's build made it (0 on the
#                             M33, with the boot header; the M7's code
#                             partition on the M7);
#   the board's session area  resources.bin, read in place;
#   + the writable offset     writable.bin, copied to RAM at boot;
#
# with every other byte 0xff, the value of erased NOR. The session area and
# the writable offset are the build's (build.json `session`), so the image is
# laid out where session.c reads it. Refused, naming the cause:
#
#   * a firmware built for another image (build.json's digests against
#     image.sha256's, file for file);
#   * a launcher that is not the one build.json records, or that reaches
#     the program;
#   * a program whose first loaded byte is not the flash base plus its load
#     offset, so that zephyr.bin would not land where it runs;
#   * a program that reaches the session area;
#   * a session that ends past the area.
#
# Writes FILE and FILE.sha256, and prints one line per region with its offset,
# length and sha256, read back from FILE.
require "digest"
require "json"
require "open3"
require "optparse"

opt = { llvm: ENV.fetch("LLVM_PREFIX", "/opt/llvm-23.1.1") }
OptionParser.new do |o|
  o.on("--firmware DIR") { |v| opt[:firmware] = v }
  o.on("--image DIR") { |v| opt[:image] = v }
  o.on("--out FILE") { |v| opt[:out] = v }
  o.on("--llvm PREFIX") { |v| opt[:llvm] = v }
end.parse!
%i[firmware image out].each { |k| opt[k] or abort("nor-image: --#{k} is required") }
fw = opt[:firmware]
build = JSON.parse(File.read(File.join(fw, "build.json")))
session = build["session"] or abort("nor-image: #{fw}/build.json has no session; this is no core_session build")
sums = File.readlines(File.join(opt[:image], "image.sha256"), chomp: true).to_h { |l| d, n = l.split(/\s+/, 2); [n, d] }
%w[resources.bin writable.bin image.tsv].each do |n|
  got = Digest::SHA256.file(File.join(opt[:image], n)).hexdigest
  abort("nor-image: #{opt[:image]}/#{n} is not what image.sha256 says") unless got == sums[n]
  abort("nor-image: the firmware was built for another image: its #{n} is #{session['image']['sha256'][n]}, this one #{got}") unless session["image"]["sha256"][n] == got
end
config = File.read(File.join(fw, "config"))
flash_base = Integer(config[/^CONFIG_FLASH_BASE_ADDRESS=(\S+)$/, 1] || abort("nor-image: no CONFIG_FLASH_BASE_ADDRESS in #{fw}/config"))
base = Integer(session["area"]["base"])
area = Integer(session["area"]["bytes"])
off = base - flash_base
prog_off = Integer(config[/^CONFIG_FLASH_LOAD_OFFSET=(\S+)$/, 1] || "0")
rw_off = Integer(session["image"]["writable_offset"])
# the lowest physical address a loaded segment has: where zephyr.bin's first byte goes
ph, st = Open3.capture2(File.join(opt[:llvm], "bin", "llvm-readelf"), "-l", "-W", File.join(fw, "zephyr.elf"))
abort("nor-image: llvm-readelf could not read #{fw}/zephyr.elf") unless st.success?
loads = ph.lines.grep(/^\s+LOAD\s/).map { |l| f = l.split; [Integer(f[3]), Integer(f[4])] }.reject { |_, filesz| filesz.zero? }
first = loads.map(&:first).min or abort("nor-image: #{fw}/zephyr.elf has no loaded segment")
abort("nor-image: the program's first loaded byte is at #{format('%#x', first)}, not the flash base #{format('%#x', flash_base)} + the load offset #{format('%#x', prog_off)}") unless first == flash_base + prog_off
prog = File.binread(File.join(fw, "zephyr.bin"))
abort("nor-image: zephyr.bin at #{format('%#x', prog_off)} is #{prog.bytesize} B and reaches the session area at offset #{format('%#x', off)}") if prog_off + prog.bytesize > off
launcher = nil
if (l = build["launcher"])
  launcher = File.binread(File.join(fw, l["file"]))
  abort("nor-image: #{fw}/#{l['file']} is not the launcher build.json records (#{l['sha256']})") unless Digest::SHA256.hexdigest(launcher) == l["sha256"]
  launcher_off = Integer(l["offset"])
  abort("nor-image: the launcher at #{format('%#x', launcher_off)} is #{launcher.bytesize} B and reaches the program at #{format('%#x', prog_off)}") if launcher_off + launcher.bytesize > prog_off
end
res = File.binread(File.join(opt[:image], "resources.bin"))
rw = File.binread(File.join(opt[:image], "writable.bin"))
abort("nor-image: the session ends at #{rw_off + rw.bytesize} B into an area of #{area}") if rw_off + rw.bytesize > area
abort("nor-image: the resources (#{res.bytesize} B) overlap the writable part at #{rw_off}") if res.bytesize > rw_off
total = off + rw_off + rw.bytesize
img = ("\xff".b * total)
img[launcher_off, launcher.bytesize] = launcher if launcher
img[prog_off, prog.bytesize] = prog
img[off, res.bytesize] = res
img[off + rw_off, rw.bytesize] = rw
File.binwrite(opt[:out], img)
back = File.binread(opt[:out])
regions = [["zephyr.bin", prog_off, prog.bytesize, prog], ["resources.bin", off, res.bytesize, res], ["writable.bin", off + rw_off, rw.bytesize, rw]]
regions.unshift(["launcher.bin", launcher_off, launcher.bytesize, launcher]) if launcher
regions.each do |name, at, len, want|
  got = back.byteslice(at, len)
  abort("nor-image: #{opt[:out]} does not hold #{name} at #{format('%#x', at)}") unless got == want
  puts "nor-image: #{name} at #{format('%#09x', at)} (#{format('%#x', flash_base + at)}), #{len} B, sha256 #{Digest::SHA256.hexdigest(got)}"
end
digest = Digest::SHA256.hexdigest(back)
File.write("#{opt[:out]}.sha256", "#{digest}  #{File.basename(opt[:out])}\n")
puts "nor-image: #{File.basename(opt[:out])} #{back.bytesize} B of the #{format('%#x', flash_base)} NOR, sha256 #{digest}"
