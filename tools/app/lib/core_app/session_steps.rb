# frozen_string_literal: true
#
# tools/app/lib/core_app/session_steps.rb -- the core_session part of the
# build (decision 0021, Clarification of 2026-10-20), mixed into Pipeline.
#
# Each method is called from its step of 0014 §8 and does nothing for an
# application without a core_session:
#
#   1  the session read and checked (session.rb): the image, the entries'
#      contracts, and the objects built apart for this target, whose contracts
#      must be the entries directory's byte for byte; each entry parameter that
#      names no declared state becomes a session state, or is refused;
#   4  the package core_session generates (DoomCore's three members, Slot,
#      Image), read like the board's with origin `session`. DoomCore.input
#      carries the bound its report derives; step and render, whose reports
#      leave loops without a derived bound, carry `iterations unknown` with
#      that reason (the owner's decision of 2026-10-20);
#   5  session.c generated for the board's session area and compiled; its
#      three providers call CORE, which the screen refuses for every other
#      provider: they alone are exempt, by name. Each DoomCore member's stack
#      is its provider's frame, the entry's kernel_stack from its report, and
#      the deepest compiler runtime helper its object calls (helpers.tsv);
#   7  one writing context for the session: every entry that calls DoomCore
#      or names a session state is in one context. A resource state an entry
#      writes is refused, by its report's write set. A loop_bound unknown is
#      admitted only through DoomCore, and recorded;
#   9  the entries' objects linked with the rest;
#   10 the image's code ends below the session area, the session fits the
#      area, and the helpers came from the archive helpers.tsv names.
#
# THE BOARD APPLICATION MAKES NO REALTIME CLAIM. Its entries that call
# DoomCore are built under the realtime profile with loop_bound unknown
# through DoomCore, and build.json says so in those words.
require "json"
require "digest"
require "fileutils"
require_relative "session"

module CoreApp
  module SessionSteps
    NOT_REALTIME = "realtime profile, loop_bound unknown through DoomCore: not a realtime claim"

    def session? = !@session.nil?

    # ---- 1
    def session_step1
      if @app.session_path.nil?
        refuse(1, "--session-image and --session-objects belong to an application with a core_session; this one declares none") if @session_image || @session_objects
        return
      end
      refuse(1, "core_session needs --session-image DIR (tools/doom/session-image.rb) and --session-objects DIR (the entries built for #{@board})") unless @session_image && @session_objects
      dir = File.expand_path(@app.session_path, File.dirname(@app_path))
      begin
        @session = Session.read(dir, @session_image)
      rescue Session::Error, Errno::ENOENT => e
        refuse(1, "core_session: #{e.message}")
      end
      @session_reports = {}
      @session_core_objects = {}
      Session::ENTRIES.each do |e|
        %W[#{e}.o #{e}.h report_#{e}.json #{e}.contract].each do |f|
          refuse(1, "core_session: #{@session_objects} has no #{f}") unless File.file?(File.join(@session_objects, f))
        end
        unless File.binread(File.join(@session_objects, "#{e}.contract")) == File.binread(File.join(dir, "#{e}.contract"))
          refuse(1, "core_session: #{@session_objects}/#{e}.contract is not #{dir}/#{e}.contract; the objects were built from another contract")
        end
        if @failure_sites
          %W[#{e}.sites.tsv #{e}.map.tsv].each do |f|
            refuse(1, "core_session: --failure-sites needs the entries built with --failure-sites; #{@session_objects} has no #{f}") unless File.file?(File.join(@session_objects, f))
          end
        end
        @session_reports[e] = JSON.parse(File.read(File.join(@session_objects, "report_#{e}.json")))
        @session_core_objects[e] = File.join(@session_objects, "#{e}.o")
      end
      @app.session_params.map(&:last).uniq.each do |p|
        begin
          st = Session.state_for(@session, p)
        rescue Session::Error => e
          refuse(1, "core_session: entry parameter #{e.message}")
        end
        users = @app.session_params.select { |_, q| q == p }.map(&:first)
        refuse(1, "entry #{users.join(', ')}: parameter #{p} is neither a declared state nor a field of the session") unless st
        @app.states << State.new(name: p, element: st[:element], count: st[:count], line: @app.session_line,
                                 placement: :session, part: st[:part], offset: st[:offset], readonly: st[:readonly] == true)
      end
      # the fields the declaration keeps in the data TCM: each a writable
      # field of the image (step 4 keeps them there only on a board with one)
      @app.session_dtcm.each do |f|
        fld = @session.image.field(f)
        refuse(1, "core_session dtcm: #{f} is not a field of the session image") unless fld
        refuse(1, "core_session dtcm: #{f} is in part #{fld.part}; only a writable field can be kept in the data TCM") unless fld.part == "writable"
      end
      @log << "[1] core_session #{@app.session_path}: image #{@session_image} (resources #{@session.image.resources_bytes} B, writable #{@session.image.writable_bytes} B), " \
              "#{@app.states.count { |s| s.placement == :session }} session state(s)#{@session.image.demo ? ", demo #{@session.image.demo[:name]} (#{@session.image.demo[:tics]} tics)" : ''}"
    end

    # ---- 4
    def session_step4
      @session_externs = []
      @session_constants = {}
      return unless session?
      facts = read_board_facts
      %w[session_flash_offset session_flash_bytes].each do |k|
        refuse(4, "core_session: the board #{@board} has no #{k}; it has no area for a session image") unless facts.key?(k)
      end
      @session_area_offset = Integer(facts["session_flash_offset"].first)
      @session_area_bytes = Integer(facts["session_flash_bytes"].first)
      refuse(4, "core_session: the image needs #{@session.image.partition_bytes} B and the board's session area holds #{@session_area_bytes}") if @session.image.partition_bytes > @session_area_bytes
      # the NOR's window in this core's view: the board's own where it names
      # one (the M7's FlexSPI2 window, decision 0023), else the flash base
      flash_base = if facts["session_flash_window"]
                     Integer(facts["session_flash_window"].first)
                   else
                     Integer(@config["CONFIG_FLASH_BASE_ADDRESS"] || refuse(4, "no CONFIG_FLASH_BASE_ADDRESS"))
                   end
      @session_base = flash_base + @session_area_offset
      # dtcm: holds where the board has a data TCM; elsewhere the fields
      # stay in the writable part, as every other writable field does
      @session_dtcm = @dtcm_bytes ? @app.session_dtcm : []
      unless @app.session_dtcm.empty?
        @log << "[4] core_session dtcm: #{@app.session_dtcm.map { |f| "#{f} (#{session_field_bytes(f)} B)" }.join(', ')} " \
                "#{@dtcm_bytes ? "kept in the data TCM (#{@dtcm_bytes} B)" : "stay in the writable part: #{@board} has no zephyr,dtcm"}"
      end
      # the entries whose code the board keeps in the instruction TCM
      # (session_itcm_entries in its table, decision 0023: the M7 runs its
      # code in place from the NOR otherwise); each entry's .text sections
      # must fit the zephyr,itcm node together
      names = @mutate.key?(:itcm_entries) ? @mutate[:itcm_entries] : facts["session_itcm_entries"]&.first.to_s.split
      @session_itcm = {}
      unless names.empty?
        names.each { |e| refuse(4, "session_itcm_entries: #{e} is not one of the session's entries (#{Session::ENTRIES.join(', ')})") unless Session::ENTRIES.include?(e) }
        refuse(4, "session_itcm_entries names #{names.join(', ')} and the board's devicetree chooses no zephyr,itcm") unless @itcm
        names.each { |e| @session_itcm[e] = text_bytes(@session_core_objects[e]) }
        need = @session_itcm.values.sum { |n| (n + 7) / 8 * 8 }
        refuse(4, "the instruction TCM holds #{@itcm[1]} B; the entries' code (#{@session_itcm.map { |e, n| "#{e} #{n} B" }.join(', ')}) needs #{need} B") if need > @itcm[1]
        @log << "[4] core_session itcm: #{@session_itcm.map { |e, n| "#{e} (#{n} B)" }.join(', ')} in the instruction TCM, #{need} of #{@itcm[1]} B"
      end
      dir = File.join(@staging, "session")
      FileUtils.mkdir_p(dir)
      pkg = Session.package_rb(@session, bound: ->(e) { session_bound(e) })
      File.write(File.join(dir, "package.rb"), pkg)
      read = Declarations.read_package(File.join(dir, "package.rb"), origin: "session")
      @session_externs = read.externs
      @session_constants = read.constants
      @log << "[4] core_session package: #{@session_externs.map { |x| "#{x.full} (#{x.bound})" }.join('; ')}; #{@session_constants.size} constants; session at #{format('%#x', @session_base)}"
    end

    def session_field_bytes(f)
      fld = @session.image.field(f)
      fld.count * Session::WIDTH.fetch(fld.element)
    end

    # The bytes the session keeps in the data TCM, each field at 8-byte
    # alignment as session.c places it.
    def session_dtcm_bytes = (@session_dtcm || []).sum { |f| (session_field_bytes(f) + 7) / 8 * 8 }

    # The bound clause of a DoomCore member, from its entry's report.
    def session_bound(entry)
      lb = @session_reports[entry]["properties"]["loop_bound"]
      if lb["verdict"] == "pass"
        expr = lb["work_bound"]["expression"]
        n = Session.evaluate_work(expr, Session.counts(@session, entry))
        refuse(4, "core_session: #{entry}'s work bound #{expr.inspect} does not evaluate over the session's counts") unless n
        "bound: \"iterations #{n}\""
      else
        unknown = lb["loops"].count { |l| l["verdict"] != "pass" }
        "bound: \"iterations unknown \\\"#{entry} has #{unknown} loop(s) without a derived bound in its #{@triple || 'target'} report\\\"\""
      end
    end

    # ---- 5: session.c, its object, and the symbols the screen exempts in it
    def session_step5_compile(inc)
      return unless session?
      src = File.join(@staging, "session", "session.c")
      File.write(src, Session.c_source(@session, base: @session_base, id: session_id, failure_sites: @failure_sites, dtcm: @session_dtcm))
      obj = File.join(@objs, "session.o")
      clang_compile(5, src, obj, inc + ["-I#{@session_objects}"])
      @provider_objects["session.c"] = obj
      # the entries' objects join the others where the link and its map
      # name them; the digest of each copy is its source's
      @session_core_objects = @session_core_objects.to_h do |e, o|
        copy = File.join(@objs, File.basename(o))
        FileUtils.cp(o, copy)
        refuse(5, "core_session: the copy of #{o} differs from it") unless Digest::SHA256.file(copy) == Digest::SHA256.file(o)
        [e, copy]
      end
      # an entry kept in the instruction TCM is linked from a copy whose code
      # sections are renamed .text* to .itcm*: Zephyr's linker script places
      # .itcm and .itcm.* there with their load address in the NOR, and
      # z_data_copy copies them at boot (arch/common/xip.c)
      @session_itcm_objects = @session_itcm.keys.to_h do |e|
        o = @session_core_objects[e]
        copy = File.join(@objs, "#{e}.itcm.o")
        renames = text_sections(o).flat_map { |n| ["--rename-section", "#{n}=#{n.sub(/\A\.text/, '.itcm')}"] }
        sh(5, @tools[:objcopy], *renames, o, copy)
        refuse(5, "core_session: #{copy} still has a .text section") unless text_sections(copy).empty?
        [e, copy]
      end
    end

    # The names of an object's .text and .text.<name> sections.
    def text_sections(obj)
      sh(5, @tools[:readelf], "-S", "-W", obj).scan(/\]\s+(\.text(?:\.\S+)?)\s/).flatten
    end

    # The bytes of an object's code: its .text and .text.<name> sections.
    def text_bytes(obj)
      sh(4, @tools[:readelf], "-S", "-W", obj).scan(/\]\s+(\.text(?:\.\S+)?)\s+\S+\s+\h+\s+\h+\s+(\h+)/).sum { |_, n| n.to_i(16) }
    end

    # THE BUILD'S IDENTITY: 16 hex digits of a digest of what this build was
    # made from. session.c holds it and the firmware prints
    # `SPC_SESSION_ID <id>` at boot once the image is accepted; build.json
    # records it. A lane reading the console requires the line and this value
    # before it reads a frame, so a run of firmware written before, or of
    # another build, is never read as this one's.
    #
    # The glue (main.c and the other generated units) is written after
    # session.c, so it cannot be digested here; what generates it is, so that
    # two builds that differ only in a template or a table get two ids:
    #
    #   the application's source and its providers' C, with the files they
    #   include by quotes; every file of tools/app (templates, lib, the
    #   release's tables, the adapters, bin); the board, the board overlay,
    #   the network file (--net); and what step 3 produced from them (zephyr.dts, .config and the
    #   compile flags, as @binding holds them); the build's switches (the PC sampler, --verify,
    #   --stress, the controls, the release); the clang and the Zephyr tree;
    #   the image's files and the entries' objects and headers.
    #
    # A build without a session (the M33 companion of decision 0027) has an
    # id of the same parts less the session's: its image_id.
    def session_id = image_id

    def image_id
      @image_id ||= begin
        parts = ["app #{Digest::SHA256.file(@app_path).hexdigest}", "board #{@board}", "pcsample #{@pcsample.inspect}"]
        # decision 0027: the helper files the application requires
        parts += @app.helpers.map { |(n, _l, path)| "helper #{n} #{Digest::SHA256.file(path).hexdigest}" }
        # decision 0027 stage 2: the contract files of its channels
        parts += @app.channels.select(&:contract).map { |c| "contract #{c.name} #{c.contract.digest}" }
        parts += provider_sources.map { |p, d| "provider #{p} #{d}" }
        app_root = File.expand_path("..", @tools[:lib])
        Dir.glob("**/*", base: app_root).sort.each do |f|
          path = File.join(app_root, f)
          parts << "tools/app #{f} #{Digest::SHA256.file(path).hexdigest}" if File.file?(path)
        end
        parts << "overlay #{@board_overlay ? Digest::SHA256.file(@board_overlay).hexdigest : 'none'}"
        # the network file of the udp: channels (--net): its endpoints and its
        # interface reach the image (spc_net.h)
        parts << "net #{@net_path ? Digest::SHA256.file(@net_path).hexdigest : 'none'}"
        # the flags name the staging directory (-I, -imacros); the id must not
        # depend on where --out put it
        flags = Digest::SHA256.hexdigest(@flags.map { |f| f.gsub(@staging, "<staging>") }.join("\n") + "\n")
        # and zephyr.dts names the generated overlay's path in its comments
        # when the overlay holds nodes (a board's own, decision 0023), as a path
        # relative to ZEPHYR_BASE that ends in the staging directory
        dts = Digest::SHA256.hexdigest(File.read(@dts_path).gsub(/\S*#{Regexp.escape(@staging)}/, "<staging>"))
        parts << "configured dts #{dts} config #{@binding[:config]} flags #{flags}"
        if session?
          parts << "dtcm #{@session_dtcm.join(',')} of #{@dtcm_bytes || 'none'}"
          parts << "itcm #{@session_itcm.map { |e, n| "#{e}:#{n}" }.join(',')} of #{@itcm&.last || 'none'}"
        end
        parts << "switches verification=#{@verification} stress=#{@stress.inspect} release=#{@release} mutate=#{@mutate.sort_by { |k, _| k.to_s }.inspect}"
        parts << "clang #{IO.popen([@tools[:clang], '--version'], err: File::NULL, &:read).lines.first.to_s.strip}"
        zrev = IO.popen(["git", "-C", @tools[:zephyr_base].to_s, "rev-parse", "HEAD"], err: File::NULL, &:read).strip
        parts << "zephyr #{zrev.empty? ? @tools[:zephyr_base] : zrev}"
        if session?
          parts += @session.image.sha256.sort.map { |n, d| "image #{n} #{d}" }
          parts += @session_core_objects.sort.map { |e, o| "object #{e} #{Digest::SHA256.file(o).hexdigest}" }
          parts += Dir.glob(File.join(@session_objects, "*.h")).sort.map { |h| "header #{File.basename(h)} #{Digest::SHA256.file(h).hexdigest}" }
        end
        @session_id_parts = parts
        Digest::SHA256.hexdigest(parts.join("\n"))[0, 16]
      end
    end

    # The application's provider sources, each with the files it includes by
    # quotes (profile_digests.c includes frame_digests.c), resolved as the
    # compiler resolves them: beside the including file.
    def provider_sources
      seen = {}
      todo = @app.externs.map(&:provider).uniq.map { |p| File.expand_path(p, File.dirname(@app_path)) }
      until todo.empty?
        path = todo.shift
        next if seen.key?(path) || !File.file?(path)
        seen[path] = Digest::SHA256.file(path).hexdigest
        File.read(path).scan(/^\s*#\s*include\s+"([^"]+)"/).flatten.each { |inc| todo << File.expand_path(inc, File.dirname(path)) }
      end
      base = File.dirname(@app_path)
      seen.sort.map { |p, d| [p.start_with?("#{base}/") ? p.delete_prefix("#{base}/") : p, d] }
    end

    # The CORE entry symbols the screen lets a provider call: the three DOOM
    # entries, in session.c alone, whose three providers exist to call them.
    # Every other provider calling one is refused as the screen refuses any
    # call back into CORE.
    def session_screen_exempt(name)
      return [] unless session? && name == "session.c"
      # --failure-sites: the providers also read each entry's site global,
      # data the entry's object defines, not a call into CORE
      Session::ENTRIES.map { |e| "spinel_core_#{e}" } +
        (@failure_sites ? Session::ENTRIES.map { |e| "spinel_core_#{e}_failure_site" } : [])
    end

    # The helper rows of this build's multilib, by symbol.
    def session_helpers
      @session_helpers ||= begin
        multilib = @triple.start_with?("thumbv7em-") ? "thumb/v7e-m/" : "thumb/v8-m.main/"
        File.readlines(File.join(@zt, "helpers.tsv"), chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }
            .map { |l| s, b, a, d, ev = l.split("\t", 5); [s, { bytes: Integer(b), archive: a, sha256: d, evidence: ev }] }
            .select { |_, r| r[:archive].start_with?(multilib) }.to_h
      end
    end

    def session_step5_evidence(frame)
      return unless session?
      @session_used_helpers = {}
      @session_externs.each do |x|
        entry = Session::MEMBER.key(x.name) or refuse(5, "core_session: #{x.full} names no entry")
        undefined = Open3.capture2(@tools[:symbols], "--undefined", @session_core_objects[entry]).first.lines.map { |l| l.chomp.split("\t").last }
        helpers = undefined.reject { |s| s.start_with?("spinel_core_") }
        helpers.each { |h| refuse(5, "core_session: #{entry}'s object calls #{h}, which helpers.tsv does not attest") unless session_helpers.key?(h) }
        @session_used_helpers[entry] = helpers.sort
        helper_bytes = helpers.map { |h| session_helpers[h][:bytes] }.max || 0
        st = @session_reports[entry]["properties"]["stack_budget"]
        refuse(5, "core_session: #{entry}'s report has no kernel_stack") unless st["kernel_stack"].is_a?(Integer)
        bytes = frame.call(x.symbol) + st["kernel_stack"] + helper_bytes
        Evidence.write(File.join(@evidence_dir, "#{x.symbol}.json"), symbol: x.symbol, object: @provider_objects["session.c"],
                       target: @triple, board: @board, release: @release, dts_sha256: @binding[:dts], config_sha256: @binding[:config],
                       flags_sha256: @binding[:flags], stack_bytes: bytes,
                       stack_method: "clang -fstack-usage frame of #{x.symbol} (#{frame.call(x.symbol)}#{unreserved_note(x.symbol)}), plus #{entry}'s kernel_stack (#{st['kernel_stack']}, its report) " \
                                     "and the deepest runtime helper it calls (#{helpers.empty? ? 'none' : "#{helpers.join(', ')}: #{helper_bytes}, helpers.tsv"})",
                       effects: { "isr_ok" => false, "blocking" => false, "row" => "core_session (decision 0021): a DOOM entry, which calls nothing" })
      end
    end

    # ---- 7
    def session_step7_checks
      @session_loop_bound = {}
      return unless session?
      names = @app.states.select { |s| s.placement == :session }.map(&:name)
      users = @app.scheduled.select do |entry, _|
        calls = @reports[entry.name]["application"]["externs"].any? { |x| x["symbol"].start_with?("spc_session_doomcore_") && x["sites"].to_i.positive? }
        calls || (entry.params & names).any?
      end
      contexts = users.map { |_, t| t.context }.uniq
      if contexts.size > 1
        refuse(7, "core_session: the session is written from one context, and #{users.map { |e, t| "#{e.name} (#{t.context})" }.join(', ')} " \
                  "call DoomCore or name a session state from #{contexts.size} contexts")
      end
      @app.scheduled.each do |entry, _|
        rep = @reports[entry.name]
        rep["application"]["buffers"].each do |b|
          st = @app.state(b["name"])
          next unless st&.readonly
          refuse(7, "core_session: entry #{entry.name} writes #{b['name']}, a resource of the session, which is read-only") if b["written"]
        end
        lb = rep["properties"]["loop_bound"]
        next if lb["verdict"] == "pass"
        unknown = lb["unknown_externs"] || []
        own = (lb["loops"] || []).reject { |l| l["verdict"] == "pass" }
        refuse(7, "entry #{entry.name}: loop_bound is #{lb['verdict']} through its own loops") unless own.empty?
        refuse(7, "entry #{entry.name}: loop_bound is unknown and no extern is named") if unknown.empty?
        foreign = unknown.reject { |u| u["extern"].start_with?("DoomCore.") }
        refuse(7, "entry #{entry.name}: loop_bound is unknown through #{foreign.map { |u| u['extern'] }.join(', ')}, which core_session does not generate") unless foreign.empty?
        @session_loop_bound[entry.name] = { "verdict" => "unknown", "claim" => NOT_REALTIME, "through" => unknown }
      end
      @log << "[7] core_session: written from #{contexts.first || 'no'} context; #{@session_loop_bound.keys.map { |e| "#{e}: #{NOT_REALTIME}" }.join('; ')}"
    end

    # ---- 9
    def session_link_objects = session? ? @session_core_objects.map { |e, o| (@session_itcm_objects || {})[e] || o } : []

    # ---- 10
    def session_step10_checks(map, fails)
      return unless session?
      # each entry the board keeps in the instruction TCM is there, and the
      # TCM's section fits it
      # (an entry the application never calls is not linked: nothing to check)
      @session_itcm.each_key do |e|
        addr = @image_syms.dig("spinel_core_#{e}", 0)
        if addr.nil?
          @log << "[10] core_session itcm: #{e} is not linked (the application does not call it)"
          next
        end
        fails << "core_session itcm: spinel_core_#{e} is at #{format('%#x', addr)}, outside the instruction TCM #{format('%#x', @itcm[0])}+#{@itcm[1]}" unless addr >= @itcm[0] && addr < @itcm[0] + @itcm[1]
      end
      unless @session_itcm.empty?
        used = @image_syms.dig("__itcm_end", 0).to_i - @image_syms.dig("__itcm_start", 0).to_i
        fails << "core_session itcm: the image's instruction TCM section is #{used} B, more than the #{@itcm[1]} B it has" if used > @itcm[1]
      end
      end_sym = %w[_image_rom_end __rom_region_end].find { |s| @image_syms.key?(s) }
      if end_sym
        code_end = @image_syms[end_sym][0]
        fails << "core_session: the image's code ends at #{format('%#x', code_end)} (#{end_sym}), past the session area at #{format('%#x', @session_base)}" if code_end > @session_base
      else
        fails << "core_session: the image has neither _image_rom_end nor __rom_region_end; where its code ends is unknown"
      end
      used = @session_used_helpers.values.flatten.uniq
      used.each do |h|
        row = session_helpers[h]
        arch = map.lines.filter_map { |l| l[/(\S*\/#{Regexp.escape(row[:archive])})\(/, 1] }.uniq
        if arch.empty?
          fails << "core_session: the map names no #{row[:archive]}, the archive helpers.tsv attests #{h} in"
          next
        end
        arch.each do |a|
          got = Digest::SHA256.file(File.expand_path(a)).hexdigest
          fails << "core_session: #{a} is sha256 #{got}; helpers.tsv attests #{h} in #{row[:sha256]}" unless got == row[:sha256]
        end
      end
      @session_code_end = end_sym && @image_syms[end_sym][0]
      @log << "[10] core_session: code ends at #{@session_code_end ? format('%#x', @session_code_end) : 'unknown'}, the session at #{format('%#x', @session_base)} (#{@session.image.partition_bytes} of #{@session_area_bytes} B); helpers #{used.empty? ? 'none' : used.join(' ')}"
    end

    def session_summary
      return nil unless session?
      {
        "entries_dir" => @app.session_path,
        "id" => session_id,
        "image" => { "dir" => File.expand_path(@session_image), "sha256" => @session.image.sha256,
                     "resources_bytes" => @session.image.resources_bytes, "writable_bytes" => @session.image.writable_bytes,
                     "writable_offset" => @session.image.rw_offset, "demo" => @session.image.demo },
        "area" => { "base" => format("%#x", @session_base), "bytes" => @session_area_bytes, "code_end" => @session_code_end && format("%#x", @session_code_end) },
        "objects" => @session_core_objects.to_h { |e, o| [e, Digest::SHA256.file(o).hexdigest] },
        "dtcm" => @session_dtcm.to_h { |f| [f, session_field_bytes(f)] },
        "itcm" => @session_itcm,
        "helpers" => @session_used_helpers,
        "loop_bound" => @session_loop_bound,
        "claim" => NOT_REALTIME,
      }
    end
  end
end
