# frozen_string_literal: true
#
# tools/test/source-stamp.rb — whether a built tool was built from this tree's source.
#
#   ruby tools/test/source-stamp.rb write kernel BIN_DIR
#   ruby tools/test/source-stamp.rb write reader BINARY --vendor DIR
#   ruby tools/test/source-stamp.rb check kernel|reader BINARY
#
# A lane reads the kernel (tools/mlir/native's build) and the contract reader
# (tools/contract's spinel-typedump) as binaries, often copied from another
# worktree so a long run does not see a rebuild. A copy can be older than the
# source it is used with: on 2026-10-21 a kernel built before a kernel change
# landed ran the M7 board lane, and the frames were all right while the time
# was 7 ms per tic slower than the source's. Nothing in the lane could see it.
#
# THE SOURCE STAMP. Each build script calls `write` after it builds, and it
# writes source-stamp.tsv beside the binary: one row per input the build
# compiles, its path and a digest of its content. `check` computes the same
# rows from the tree this script is in and compares: a binary with no stamp,
# or with a row that differs, is refused, naming the inputs. Content, not a
# commit, so a build from an uncommitted edit is stamped as what it compiled.
# Copy the stamp with the binary (`cp -a` of the directory keeps it).
#
# The inputs, one list per tool, kept here so `write` and `check` agree:
#   kernel  the tracked and untracked (not ignored) files under
#           tools/mlir/native but its lit tests (test/), and the two files
#           CMakeLists.txt embeds, tools/realtime/alloc_vocabulary.tsv and
#           tools/core/hosted-prelude.rb (decision 0042); sha256 each.
#           Since decision 0045 the kernel links the vendored Prism
#           (vendor/spinel/build/libprism.a), so it also carries the
#           vendor Makefile, which names the Prism version `make deps`
#           fetches (a blob id, against the pin's at check), and one
#           digest of the Prism sources and headers that were extracted
#           (vendor/spinel/vendor/prism/{src,include}). A pin move, or a
#           Prism fetched again, with an unrebuilt kernel is refused.
#   reader  the same under tools/contract (its build/ is ignored), and the
#           vendor compiler's src/, Makefile and common.mk as the checkout it
#           linked (`--vendor`) holds them, as git blob ids, against the
#           blobs of the commit the tree pins vendor/spinel at -- read from
#           the repository's submodule store, since a worktree's vendor/spinel
#           is a copy with no git of its own. The vendor objects themselves
#           are not checked: tools/contract/build.sh makes them only when they
#           are missing.
#
# A lane that runs another kernel on purpose (loop-reports.sh's
# BASELINE_KERNEL) does not check that one.
require "digest"
require "open3"

ROOT = File.expand_path("../..", __dir__)
STAMP = "source-stamp.tsv"
KINDS = {
  "kernel" => { dirs: ["tools/mlir/native"], skip: %r{\Atools/mlir/native/test/},
                files: ["tools/realtime/alloc_vocabulary.tsv", "tools/core/hosted-prelude.rb"],
                build: "tools/mlir/native/build.sh" },
  "reader" => { dirs: ["tools/contract"], skip: nil, files: [], build: "tools/contract/build.sh" },
}.freeze
VENDOR_INPUTS = %r{\A(src/.+|Makefile|common\.mk)\z}
PRISM_ROW = "vendor/spinel/vendor/prism/{src,include}"

def die(msg, code = 2)
  warn("source-stamp: #{msg}")
  exit(code)
end

def git(*args, dir: ROOT)
  out, err, st = Open3.capture3("git", "-C", dir, *args)
  st.success? or die("git #{args.join(' ')} in #{dir}: #{err.strip}")
  out
end

# path => digest for this tree's own inputs, merged with the vendor rows
def inputs(kind, vendor)
  k = KINDS.fetch(kind)
  paths = k[:dirs].flat_map do |d|
    git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", d).split("\0")
  end
  paths = paths.reject { |p| k[:skip]&.match?(p) } + k[:files]
  rows = paths.uniq.sort.to_h do |p|
    f = File.join(ROOT, p)
    File.file?(f) or die("#{kind}: input #{p} is not a file in #{ROOT}")
    [p, "sha256:#{Digest::SHA256.file(f).hexdigest}"]
  end
  rows.merge(vendor)
end

def blob(path)
  data = File.binread(path)
  "blob:#{Digest::SHA1.hexdigest("blob #{data.bytesize}\0#{data}")}"
end

# the vendor sources the tree pins, from the submodule store
def tree_vendor
  line = git("ls-files", "-s", "--", "vendor/spinel").split("\n").first or die("the tree has no vendor/spinel gitlink")
  commit = line.split[1]
  # The store is the vendor checkout's own git directory when it has one (a
  # worktree's submodule), then the shared store under the common directory.
  stores = []
  own, _, ost = Open3.capture3("git", "-C", File.join(ROOT, "vendor", "spinel"), "rev-parse", "--absolute-git-dir")
  stores << own.strip if ost.success? && !own.strip.empty?
  stores << File.join(File.expand_path(git("rev-parse", "--git-common-dir").strip, ROOT), "modules", "vendor", "spinel")
  stores = stores.uniq.select { |s| File.directory?(s) }
  stores.empty? and die("no submodule store to read vendor/spinel #{commit} from")
  out = err = st = nil
  stores.each do |store|
    out, err, st = Open3.capture3("git", "--git-dir=#{store}", "ls-tree", "-r", commit)
    break if st.success?
  end
  st.success? or die("vendor/spinel #{commit} is not in #{stores.join(' or ')}: #{err.strip}")
  out.split("\n").filter_map do |l|
    meta, path = l.split("\t", 2)
    _, type, id = meta.split
    ["vendor/spinel/#{path}", "blob:#{id}"] if type == "blob" && VENDOR_INPUTS.match?(path)
  end.to_h
end

# Decision 0045: the kernel's Prism rows. `makefile` is the vendor
# Makefile's blob id (the built checkout's at write, the pin's at check);
# the other row digests every file Prism's extraction left under src/ and
# include/, path and content, as this tree's vendor/spinel holds them.
def prism_rows(makefile)
  dir = File.join(ROOT, "vendor", "spinel", "vendor", "prism")
  files = %w[src include].flat_map { |d| Dir.glob("#{d}/**/*", base: dir) }
                         .select { |p| File.file?(File.join(dir, p)) }.sort
  files.empty? and die("no Prism sources at #{dir}; run make -C vendor/spinel deps")
  d = Digest::SHA256.new
  files.each { |p| d << p << "# the vendor sources the build linked, as that checkout holds them
" << Digest::SHA256.file(File.join(dir, p)).hexdigest << "\n" }
  { "vendor/spinel/Makefile" => makefile, PRISM_ROW => "sha256:#{d.hexdigest}" }
end

# the vendor sources the build linked, as that checkout holds them
def built_vendor(dir)
  File.directory?(File.join(dir, "src")) or die("no vendor sources at #{dir}/src")
  Dir.glob("**/*", base: dir).select { |p| VENDOR_INPUTS.match?(p) && File.file?(File.join(dir, p)) }
     .sort.to_h { |p| ["vendor/spinel/#{p}", blob(File.join(dir, p))] }
end

def read_stamp(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.to_h do |l|
    f = l.chomp.split("\t")
    f.length == 2 or die("#{path}: a row is not a path and a digest: #{l.chomp.inspect}")
    f
  end
end

USAGE = "usage: source-stamp.rb write kernel BIN_DIR | write reader BINARY --vendor DIR | check kernel|reader BINARY"
cmd, kind, target, *rest = ARGV
KINDS.key?(kind.to_s) && target or die(USAGE)
case cmd
when "write"
  if kind == "kernel"
    dir = target
    File.directory?(dir) or die("write kernel: #{dir} is not the build's bin directory")
    vendor = prism_rows(blob(File.join(ROOT, "vendor", "spinel", "Makefile")))
  else
    dir = File.dirname(target)
    rest[0] == "--vendor" && rest[1] or die("write reader: --vendor DIR names the vendor checkout it linked")
    vendor = built_vendor(rest[1])
  end
  rows = inputs(kind, vendor)
  File.write(File.join(dir, STAMP),
             "# #{STAMP} -- the #{kind}'s inputs as built (tools/test/source-stamp.rb)\n" \
             "#path\tdigest\n" + rows.map { |p, d| "#{p}\t#{d}\n" }.join)
  puts "source-stamp: #{kind}: #{rows.length} input(s) -> #{File.join(dir, STAMP)}"
when "check"
  File.file?(target) or die("check #{kind}: no #{kind} at #{target}", 1)
  stamp = File.join(File.dirname(target), STAMP)
  File.exist?(stamp) or
    die("#{kind} #{target} has no source stamp beside it (#{stamp}); rebuild it with #{KINDS[kind][:build]}", 1)
  built = read_stamp(stamp)
  now = inputs(kind, kind == "reader" ? tree_vendor : prism_rows(tree_vendor.fetch("vendor/spinel/Makefile")))
  diff = (built.keys | now.keys).sort.filter_map do |p|
    if !now.key?(p) then "#{p} (only in the build)"
    elsif !built.key?(p) then "#{p} (only in the tree)"
    elsif built[p] != now[p] then p
    end
  end
  unless diff.empty?
    die("#{kind} #{target} was built from other source than this tree's: #{diff.length} input(s) differ: " \
        "#{diff.first(5).join(', ')}#{diff.length > 5 ? ', ...' : ''}; rebuild it with #{KINDS[kind][:build]}", 1)
  end
  puts "source-stamp: #{kind} #{target}: built from this tree's source " \
       "(#{now.length} input(s); the binary's sha256 #{Digest::SHA256.file(target).hexdigest[0, 16]})"
else
  die(USAGE)
end
