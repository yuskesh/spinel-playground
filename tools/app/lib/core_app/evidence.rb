# frozen_string_literal: true
#
# tools/app/lib/core_app/evidence.rb -- provider evidence files (the plan's
# "Provider evidence") and the provider screen (decision 0014 §6).
#
# An evidence file binds one provider object to one configuration: the
# symbol, the object's digest, the target triple, the board, the release, the
# three configuration digests (DTS, .config, flags), the stack figure with its
# method, and the effect row. The kernel accepts it only when the symbol, the
# target and the three digests match its --config-binding; `bound?` applies
# the same rule on the tool's side so a stale file is named before the kernel
# sees it.
#
# The screen reads the object's undefined symbols through
# tools/core/object-symbols and refuses the object when one is a listed
# allocating, blocking or interrupt-configuring primitive
# (tools/app/zephyr/<release>/screen.tsv), or a CORE entry export
# (`spinel_core_*`), a generated entry wrapper (`spc_entry_*`, the name Task
# 10's glue gives them) or any name passed as an entry symbol -- a call back
# into CORE. Direct calls only: a call through a
# function pointer is not seen, so passing the screen is evidence, not proof.
require "json"
require "digest"
require "open3"

module CoreApp
  module Evidence
    FORMAT = "spinel-provider-evidence"
    VERSION = 1

    module_function

    def write(path, symbol:, object:, target:, board:, release:, dts_sha256:, config_sha256:, flags_sha256:,
              stack_bytes:, stack_method:, effects:, provenance: "attested")
      doc = {
        "format" => FORMAT, "version" => VERSION, "symbol" => symbol,
        "object" => { "file" => object, "sha256" => Digest::SHA256.file(object).hexdigest },
        "target" => target, "board" => board, "zephyr_release" => release,
        "dts_sha256" => dts_sha256, "config_sha256" => config_sha256, "flags_sha256" => flags_sha256,
        "stack" => { "bytes" => stack_bytes, "method" => stack_method },
        "effects" => effects, "provenance" => provenance,
      }
      File.write(path, JSON.pretty_generate(doc) + "\n")
      doc
    end

    def read(path)
      doc = JSON.parse(File.read(path))
      raise "#{path}: not a #{FORMAT} version #{VERSION} file" unless doc["format"] == FORMAT && doc["version"] == VERSION
      doc
    end

    # [bound, reason]: whether `doc` is evidence for `symbol` under this
    # configuration; the reason names the first mismatch.
    def bound?(doc, symbol:, target:, dts_sha256:, config_sha256:, flags_sha256:)
      { "symbol" => symbol, "target" => target, "dts_sha256" => dts_sha256,
        "config_sha256" => config_sha256, "flags_sha256" => flags_sha256 }.each do |k, v|
        return [false, "#{k} is #{doc[k].inspect}, this build's is #{v.inspect}"] unless doc[k] == v
      end
      return [false, "the object at #{doc['object']['file']} is missing"] unless File.file?(doc["object"]["file"])
      got = Digest::SHA256.file(doc["object"]["file"]).hexdigest
      return [false, "the object's sha256 is #{got}, the evidence says #{doc['object']['sha256']}"] unless got == doc["object"]["sha256"]
      [true, nil]
    end

    ScreenRow = Struct.new(:set, :symbol, :reason, keyword_init: true)

    def read_screen(path)
      rows = []
      File.foreach(path).with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        f = ln.chomp.split("\t", -1)
        raise "#{path}:#{i}: #{f.size} column(s), want 3" unless f.size == 3
        rows << ScreenRow.new(set: f[0], symbol: f[1], reason: f[2])
      end
      rows
    end

    # The undefined symbols of `object`, by name, through object-symbols.
    def undefined(object, symbols_tool:, env: {})
      text, status = Open3.capture2e(env, symbols_tool, "--undefined", object)
      raise "#{symbols_tool} failed on #{object}: #{text.strip}" unless status.success?
      text.lines.map { |l| l.chomp.split("\t", 2).last }.compact.uniq
    end

    # Refusals as [{symbol, set, reason}]; empty when the object passes.
    # `entry_symbols` are the application's CORE exports and generated entry
    # wrappers, refused as the `entry` set.
    # `exempt` names the CORE entry symbols this one object may call: the
    # three DOOM entries, for the providers core_session generates (decision
    # 0021) and for no other object.
    def screen(object, screen_rows, entry_symbols, symbols_tool:, env: {}, exempt: [])
      listed = screen_rows.to_h { |r| [r.symbol, r] }
      undefined(object, symbols_tool: symbols_tool, env: env).filter_map do |u|
        next if exempt.include?(u)
        if (r = listed[u])
          { "symbol" => u, "set" => r.set, "reason" => r.reason }
        elsif entry_symbols.include?(u) || u.start_with?("spinel_core_") || u.start_with?("spc_entry_")
          { "symbol" => u, "set" => "entry", "reason" => "a call back into CORE: an entry export or a generated entry wrapper" }
        end
      end
    end
  end
end
