# frozen_string_literal: true
#
# tools/app/lib/core_app/pipeline.rb -- the eleven build steps of decision
# 0014 §8, staging and publication.
#
# Each step consumes only the outputs of earlier steps. Everything before
# step 11 is written to `<out>/.staging` and is not a deliverable; firmware
# reaches `<out>/firmware` only when step 10 passes, and any failure removes
# staging and leaves no firmware. Configuration is fixed at step 3 (the final
# DTS, .config and the compile flags, each digested, the first step that has
# them) and verified unchanged at step 10 (the last before publication);
# 0014 §8 counts the same two moments as its "step 2" and "step 11". The CORE objects, the glue and the providers are compiled by
# the kernel's clang against Zephyr's headers with the flags of the
# configured build translated as Task 2 recorded (drop what clang rejects,
# add -mfloat-abi=soft -fshort-enums); west links them.
#
# Every refusal is a Pipeline::Refused with the step and the reason; the
# build log (`build.log` in the output) records each step's commands.
require "json"
require "digest"
require "fileutils"
require "open3"
require_relative "app_model"
require_relative "declarations"
require_relative "channels"
require_relative "contracts"
require_relative "app_checks"
require_relative "board"
require_relative "evidence"
require_relative "reserves"
require_relative "inventory"
require_relative "stack"
require_relative "glue"
require_relative "labels"
require_relative "stimulus"
require_relative "xwrap"
require_relative "session_steps"
require_relative "pair_steps"
require_relative "unreserved"

module CoreApp
  class Pipeline
    include SessionSteps
    include PairSteps
    class Refused < StandardError
      attr_reader :step
      def initialize(step, message)
        @step = step
        super("step #{step}: #{message}")
      end
    end

    TICK_US = 100 # CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000 in prj.conf.erb
    XFLAGS = %w[-mfloat-abi=soft -fshort-enums].freeze
    BOARDS = { "mps2_an521" => "mps2/an521/cpu0", "frdm_mcxn947" => "frdm_mcxn947/mcxn947/cpu0",
               "frdm_imxrt1186" => "frdm_imxrt1186/mimxrt1186/cm33",
               "frdm_imxrt1186_cm7" => "frdm_imxrt1186/mimxrt1186/cm7",
               # the M33 as the M7's companion (decision 0027)
               "frdm_imxrt1186_cm33_amp" => "frdm_imxrt1186/mimxrt1186/cm33" }.freeze
    # the --target each board's units are compiled for, and the prefix of
    # clang's normalised triple under it (decision 0023: the M7 is v7E-M)
    TARGETS = Hash.new(["thumbv8m.main-none-eabi", "thumbv8m.main-"]).merge(
      "frdm_imxrt1186_cm7" => ["thumbv7em-none-eabi", "thumbv7em-"]
    ).freeze

    attr_reader :log, :staging, :out, :zapp, :target, :board, :app, :app_path

    # tools: {kernel:, clang:, typedump:, int64_allow:, symbols:, objcopy:, gate:, lib:, zephyr_dir:}
    # `stimulus` is the script's path, required by a verification build: its
    # horizon, drain and nesting source shape the glue (Task 11).
    # `stress` is Task 12's sampling source: {period_us:, report_at:}, a
    # production build only (the verification build's nesting source already
    # owns the other CMSDK timer, and a recorded build is not the subject).
    # `pcsample` is the PC sampler of a frdm_imxrt1186 measurement build:
    # {period_us:, tics:, capacity:} (pcsample_timer.c.erb).
    def initialize(app_path:, board:, out:, tools:, board_overlay: nil, verification: false, release: "v4.4.2",
                   mutate: {}, keep_staging: false, stimulus: nil, stress: nil, session_image: nil, session_objects: nil,
                   pcsample: nil, failure_sites: false, net: nil, companion: nil, parent: nil)
      @app_path = File.expand_path(app_path)
      @session_image = session_image && File.expand_path(session_image)
      @session_objects = session_objects && File.expand_path(session_objects)
      @board = board
      @out = File.expand_path(out)
      @tools = tools
      @board_overlay = board_overlay && File.expand_path(board_overlay)
      @verification = verification
      @stimulus_path = stimulus && File.expand_path(stimulus)
      raise Refused.new(0, "a verification build needs --stimulus, the script whose horizon and drain bound the run") if verification && !@stimulus_path
      @stress = stress
      raise Refused.new(0, "--stress is a production build's sampling source (0014 Task 12); it cannot be combined with --verify") if stress && verification
      raise Refused.new(0, "--stress needs the an521 CMSDK timer 1; #{board} has none") if stress && board != "mps2_an521"
      @pcsample = pcsample
      # decision 0027: the M33 companion's application (the primary's), or the
      # primary whose sysbuild configures and links this companion
      @companion_path = companion && File.expand_path(companion)
      @parent = parent
      # the network file of the udp: channels (CoreApp::Net), read at step 1
      @net_path = net && File.expand_path(net)
      # a debugging aid (spinel-core-kernel --failure-sites): the first failed
      # call's entry, status and site, printed once on the console
      @failure_sites = failure_sites
      raise Refused.new(0, "--failure-sites is a production build's debugging aid; it cannot be combined with --verify") if failure_sites && verification
      raise Refused.new(0, "--pcsample is a measurement build's sampler; it cannot be combined with --verify or --stress") if pcsample && (verification || stress)
      raise Refused.new(0, "--pcsample needs the FRDM-IMXRT1186's GPT1; #{board} has none") if pcsample && !%w[frdm_imxrt1186 frdm_imxrt1186_cm7].include?(board)
      @release = release
      @keep_staging = keep_staging # diagnosis only: a refusal leaves .staging in place, still no firmware
      @mutate = mutate # test controls: {thread_stack_delta:, prj_lines:, config_touch:, extra_source:, reserved_slot:}
      @staging = File.join(@out, ".staging")
      @log = []
      @zt = File.join(@tools[:lib], "..", "zephyr", release)
      @target = BOARDS[board] or raise Refused.new(0, "unknown board #{board}; known: #{BOARDS.keys.join(', ')}")
    end

    def refuse(step, msg) = raise(Refused.new(step, companion? ? "the companion #{File.basename(@app_path)}: #{msg}" : msg))

    def run
      FileUtils.rm_rf(@staging)
      FileUtils.mkdir_p(@staging)
      FileUtils.rm_rf(File.join(@out, "firmware"))
      return run_pair if @companion_path

      step1_declarations
      step2_skeleton
      step3_configure
      step4_board
      if @verification
        # the recorder's context count and the nesting source's context come
        # from the inventory, which only needs step 3's outputs
        step6_inventory
        @inventory_sources_count = @inventory.sources.size
        @nest_source_index = @inventory.sources.index { |x| x.name == "nest_timer" }
        step5_providers
      else
        step5_providers
        step6_inventory
      end
      step7_kernel
      step8_glue
      step9_link
      step10_checks
      step11_publish
      self
    rescue Refused, Declarations::Refused, Board::Error, Dts::Error, Reserves::Error, Inventory::Error, Stack::Error => e
      @log << "REFUSED: #{e.message}"
      FileUtils.mkdir_p(@out)
      File.write(File.join(@out, "build.log"), @log.join("\n") + "\n")
      FileUtils.rm_rf(@staging) unless @keep_staging
      FileUtils.rm_rf(File.join(@out, "firmware"))
      raise
    end

    # Decision 0027: the primary and its companion, step by step, each step
    # the companion's first where the primary's sysbuild needs its output.
    def run_pair
      pair_new_child
      step1_declarations
      @child.step1_declarations
      pair_contracts
      @child.step2_skeleton
      step2_skeleton
      step3_configure
      @child.step3_configure
      step4_board
      @child.step4_board
      pair_ids
      [@child, self].each do |pl|
        pl.step5_providers
        pl.step6_inventory
        pl.step7_kernel
        pl.step8_glue
      end
      step9_link
      @child.step9_link
      @child.step10_checks
      step10_checks
      @child.step11_publish
      step11_publish
      self
    rescue Refused, Declarations::Refused, Board::Error, Dts::Error, Reserves::Error, Inventory::Error, Stack::Error => e
      @log.concat(@child.log.map { |l| "companion #{l}" }) if @child
      @log << "REFUSED: #{e.message}"
      FileUtils.mkdir_p(@out)
      File.write(File.join(@out, "build.log"), @log.join("\n") + "\n")
      FileUtils.rm_rf(@staging) unless @keep_staging
      FileUtils.rm_rf(File.join(@out, "firmware"))
      FileUtils.rm_rf(@child.out) if @child && !@keep_staging
      raise
    end

    def generate_channels = (@channels = Channels.generate(@app, net: @net))

    def sh(step, *argv, chdir: nil, env: {}, relocate: nil)
      @log << "[#{step}] #{argv.join(' ')}"
      out, st = Open3.capture2e(env, *argv, chdir: chdir || @staging)
      out = relocate.call(out) if relocate
      File.write(File.join(@staging, "step#{step}.log"), out, mode: "a")
      refuse(step, "#{argv.first(2).join(' ')} failed:\n#{out.lines.last(12).join}") unless st.success?
      out
    end

    def sha(path) = Digest::SHA256.file(path).hexdigest

    # ---- 1
    def step1_declarations
      @app = Declarations.read(@app_path)
      @app_name = File.basename(@app_path, ".rb")
      session_step1
      @app.triggers.each do |t|
        next if (t.period_us % TICK_US).zero?
        refuse(1, "entry #{t.entry}: the period #{t.period_us} us is not a multiple of the tick, #{TICK_US} us (CONFIG_SYS_CLOCK_TICKS_PER_SEC=#{1_000_000 / TICK_US}); a release the tick rate cannot represent is refused")
      end
      # a pair refuses udp: channels before they ask for the network file (decision 0027)
      pair_step1
      contract_step1
      udp = @app.channels.select(&:udp)
      unless udp.empty?
        refuse(1, "a verification build of udp: channels (#{udp.map(&:name).join(', ')}) is not implemented: the trace records the UART transport only") if @verification
        refuse(1, "the udp: channels #{udp.map(&:name).join(', ')} need the network file: --net FILE, outside the repository (tools/app/lib/core_app/net.rb)") unless @net_path
        begin
          @net = Net.read(@net_path, @app)
        rescue Net::Error => e
          refuse(1, e.message)
        end
      end
      refuse(1, "--net is given and the application has no udp: channel") if @net_path && udp.empty?
      # a board whose udp: channels the other core sends (decision 0024's
      # amendment): the put writes the OCRAM ring of tools/app/ring/ring_abi.h
      # and tools/app/launcher is built as the network firmware
      uc = read_board_facts(1)["udp_consumer"]
      uc = [@mutate[:udp_consumer], "--mutate-udp-consumer"] if @mutate[:udp_consumer]
      if uc
        refuse(1, "the board's udp_consumer is #{uc.first.inspect}; ocram-ring-v1 is the only one this tool generates") unless uc.first == "ocram-ring-v1"
        unless udp.empty?
          # the OCRAM rings carry one udp: channel each way (ring ABI version 5,
          # decision 0025): an :out channel the M33 sends, an :in one it receives
          %w[out in].each do |dir|
            same = udp.select { |c| c.direction == dir }
            refuse(1, "#{same.size} udp: :#{dir} channels (#{same.map(&:name).join(', ')}): the OCRAM ring carries one :#{dir} channel, and #{@board} sends its udp: channels through it") if same.size > 1
          end
          udp.each do |c|
            refuse(1, "channel #{c.name}: depth #{c.depth} is not a power of two, which the OCRAM ring's slots need (tools/app/ring/ring_abi.h)") unless (c.depth & (c.depth - 1)).zero? && c.depth < 2**30
          end
          @xcore_out = udp.find { |c| c.direction == "out" }
          @xcore_in = udp.find { |c| c.direction == "in" }
          layout, used = Channels.ring_layout(@xcore_out, @xcore_in)
          if used > Channels::RING_BYTES
            refuse(1, "the OCRAM rings' slots (#{layout.map { |c, (st, _)| "#{c.name}: #{c.depth} of #{st} bytes" }.join(', ')}) end at #{used} bytes, above the region's #{Channels::RING_BYTES}")
          end
          layout.each do |c, geometry|
            c.xcore = true
            c.ring = geometry
          end
          @xcore = true
        end
      end
      # a udp: :in channel is received by the other core (decision 0025); this
      # core's own transport thread sends udp: :out channels only
      local_in = udp.select { |c| c.direction == "in" && !c.xcore }
      refuse(1, "channel #{local_in.first.name}: udp: on an :in channel is received by the other core, through a board whose udp_consumer is ocram-ring-v1 (decision 0025); #{@board} names none, and this core's own transport does not receive") unless local_in.empty?
      # a pair's contract channels are generated once both images' step 1 laid the region out
      generate_channels unless @app.channels.any?(&:contract)
      if @verification
        @stim = Stimulus.read(@stimulus_path)
        @nest = @stim.nest_timer
        refuse(1, "nest_timer is the mps2/an521 nesting source (CMSDK timer 0); #{@board} has none") if @nest && @board != "mps2_an521"
        refuse(1, "the horizon #{@stim.horizon} us is not a multiple of the tick, #{TICK_US} us") unless (@stim.horizon % TICK_US).zero?
      end
      @log << "[1] #{@app.states.size} states, #{@app.triggers.size} triggers, #{@app.channels.size} channels, #{@app.externs.size} application externs#{@verification ? "; verification: horizon #{@stim.horizon} us, drain #{@stim.drain} us, #{@stim.items.size} stimulus items#{@nest ? ", nest_timer #{@nest.join('/')} us" : ''}" : ''}"
    end

    # ---- 2
    def step2_skeleton
      @zapp = File.join(@staging, "zephyr-app")
      FileUtils.mkdir_p(File.join(@zapp, "src"))
      File.write(File.join(@zapp, "CMakeLists.txt"), Glue.cmakelists(app_name: @app_name, wrap: @verification ? @app.externs.map(&:symbol) + %w[__aeabi_ldivmod __aeabi_uldivmod] : []))
      # the subsystems of the classes the application refers to (a module
      # with no class here is an application module or an unknown member,
      # which step 4 settles)
      classes = Board.read_classes(File.join(@tools[:lib], "..", "adapters"))
      referenced = @app.member_refs.map(&:module_name).uniq
      @subsystems = classes.select { |c| referenced.include?(c.module_name) }.flat_map(&:subsystems).uniq
      # a board's own overlays and Kconfig fragment (the FRDM-IMXRT1186's
      # Cortex-M7, decision 0023), before --board-overlay and the controls
      facts = read_board_facts(2)
      board_ovl = facts["zephyr_overlays"]&.first.to_s.split.map { |f| File.read(File.join(@zt, "boards", f)) }
      board_conf = facts["zephyr_conf"] ? File.read(File.join(@zt, "boards", facts["zephyr_conf"].first)) : ""
      # a pair's UART is the core's whose application declares a uart: channel
      # (decision 0027): an image of the pair without one has no console
      if (pair? || companion?) && @app.channels.none?(&:uart) && (nc = facts["pair_no_console"])
        ovl, conf = nc.first.split
        board_ovl << File.read(File.join(@zt, "boards", ovl))
        board_conf += File.read(File.join(@zt, "boards", conf))
        @log << "[2] no console: #{@app_name} declares no uart: channel (#{ovl}, #{conf})"
      end
      if (bell = doorbell_config)
        board_ovl << bell[0]
        board_conf += bell[1]
        @log << "[2] doorbell: Zephyr's MU driver, #{@doorbells.values.first[:free].join(' ')} disabled"
      end
      if (ovl = cacheable_overlay)
        board_ovl << ovl
        @log << "[2] control: the channel region mapped cacheable on #{@mutate[:channel_cacheable]}"
      end
      # the console transport's transmit is interrupt-driven only where this
      # board's own fragment asks for it (the Cortex-M7, decision 0023), not
      # wherever Zephyr's board defaults enable the option (mps2, frdm_mcxn947)
      @uart_tx_irq = board_conf.match?(/^CONFIG_UART_INTERRUPT_DRIVEN=y$/)
      # the network, only for an application with udp: channels: a driver the
      # application never uses would still connect its interrupts (prj.conf.erb)
      if @xcore
        # the network firmware's generated headers, for the launcher's build
        @launcher_gen = File.join(@staging, "launcher-gen")
        FileUtils.mkdir_p(@launcher_gen)
        File.write(File.join(@launcher_gen, "spc_net.h"), Net.launcher_header(@net, @xcore_out, @xcore_in))
        File.write(File.join(@launcher_gen, "spc_ring_geometry.h"), Channels.ring_geometry_h(@xcore_out, @xcore_in))
      elsif @net
        refuse(2, "the udp: channels need the board's network configuration, and #{@board} names none (zephyr_net_conf in its board table)") unless facts["zephyr_net_conf"]
        board_conf += File.read(File.join(@zt, "boards", facts["zephyr_net_conf"].first))
      end
      File.write(File.join(@zapp, "prj.conf"), Glue.prj_conf(verification: @verification, subsystems: @subsystems) + board_conf + (@mutate[:prj_lines] || []).map { |l| "#{l}\n" }.join)
      File.write(File.join(@zapp, "app.overlay"), Glue.overlay(board_overlay: (board_ovl + [@board_overlay ? File.read(@board_overlay) : "/* no board overlay */\n"]).join("\n")))
      # a board whose application is a second core's: the launcher is the
      # other image of a sysbuild (decision 0023)
      if pair?
        # decision 0027: the companion is the other image, in the launcher's place
        File.write(File.join(@zapp, "sysbuild.cmake"), pair_sysbuild)
      elsif companion?
        # its image is configured and linked by the primary's sysbuild
      elsif (l = facts["launcher"])
        dir, lboard = l.first.split(" ", 2)
        @launcher = { dir: File.expand_path(File.join("..", dir), @tools[:lib]), board: lboard,
                      offset: Integer(facts.fetch("launcher_flash_offset") { refuse(2, "the board has a launcher and no launcher_flash_offset") }.first) }
        File.write(File.join(@zapp, "sysbuild.cmake"),
                   "# generated by spinel-core-app build: the launcher image of decision 0023\n" \
                   "ExternalZephyrProject_Add(APPLICATION launcher SOURCE_DIR #{@launcher[:dir]} BOARD #{@launcher[:board]})\n")
      end
      File.write(File.join(@zapp, "src", "spc_placeholder.c"), Glue.placeholder)
      @log << "[2] skeleton written under #{@zapp}; subsystems #{@subsystems.empty? ? 'none' : @subsystems.join(' ')} for #{referenced.join(' ')}"
    end

    # ---- 3
    def step3_configure
      west_env = { "ZEPHYR_BASE" => @tools[:zephyr_base], "ZEPHYR_SDK_INSTALL_DIR" => @tools[:sdk], "PATH" => @tools[:path] }
      if companion?
        # the primary's sysbuild configured this image (pair_steps.rb)
        @sysdir = @parent.sysdir
        @build = File.join(@sysdir, PairSteps::COMPANION_IMAGE)
      else
        @sysdir = File.join(@staging, "build")
        sh(3, "west", "build", *west_mode, "-p", "always", "-b", @target, @zapp, "-d", @sysdir, "--cmake-only", "--",
           "-DZEPHYR_SDK_INSTALL_DIR=#{@tools[:sdk]}", "-D#{image_var('DTC_OVERLAY_FILE')}=#{File.join(@zapp, 'app.overlay')}", *launcher_args, *pair_args, env: west_env)
        # with a launcher or a companion, sysbuild's image of the application
        # is named after its source directory and built beside the other's
        @build = @launcher || pair? ? File.join(@sysdir, File.basename(@zapp)) : @sysdir
      end
      @dts_path = File.join(@build, "zephyr", "zephyr.dts")
      @config_path = File.join(@build, "zephyr", ".config")
      refuse(3, "no zephyr.dts or .config after the configure step") unless File.file?(@dts_path) && File.file?(@config_path)
      # the generated headers the glue and the providers include (offsets.h,
      # syscall_list.h and the syscall stubs): two phony targets, nothing
      # linked -- no zephyr.elf exists after this step
      sh(3, "ninja", "-C", @build, "offsets_h", "zephyr/syscall_list_h_target", env: west_env)
      refuse(3, "a zephyr.elf exists after the configure step; nothing may be linked before step 9") if File.file?(File.join(@build, "zephyr", "zephyr.elf"))
      @config = Reserves.read_config(File.read(@config_path))
      refuse(3, "CONFIG_FPU=y: a configuration that enables the FPU is refused (0014 §9)") if @config.key?("CONFIG_FPU")
      # the tick step 1 checked the periods against must be the one Kconfig produced
      tps = @config["CONFIG_SYS_CLOCK_TICKS_PER_SEC"].to_i
      refuse(3, "CONFIG_SYS_CLOCK_TICKS_PER_SEC is #{tps}, not the #{1_000_000 / TICK_US} the periods were checked against") unless tps == 1_000_000 / TICK_US
      # the QEMU the run target would use, for the suites (absent on a board with none)
      @qemu = File.read(File.join(@build, "CMakeCache.txt"))[/^QEMU:FILEPATH=(.+)$/, 1]
      cc = JSON.parse(File.read(File.join(@build, "compile_commands.json")))
      entry = cc.find { |c| c["file"].end_with?("spc_placeholder.c") } or refuse(3, "compile_commands.json has no line for spc_placeholder.c")
      words = entry["command"].split(" ")
      words.shift # the compiler
      flags = []
      skip = false
      words.each do |w|
        if skip then skip = false; next end
        if %w[-o -c].include?(w) then skip = true; next end
        next if w.end_with?(".c") || w.end_with?(".obj") || w.end_with?(".o")
        flags << w
      end
      dropped = File.readlines(File.join(@zt, "dropped-flags.txt"), chomp: true).reject { |l| l.start_with?("#") || l.empty? }
      @flags = ["--target=#{TARGETS[@board][0]}"] + XFLAGS + flags.reject { |f| dropped.include?(f) }
      @flags << "-DSPC_VERIFY" if @verification # every unit of a verification build, and its digest
      File.write(File.join(@staging, "flags.txt"), @flags.join("\n") + "\n")
      # the target as the kernel names it in reports and evidence: clang's
      # normalised triple under these flags (thumbv8m.main-unknown-none-eabi,
      # thumbv7em-unknown-none-eabi), not the --target spelling
      @triple = sh(3, @tools[:clang], *@flags, "-print-target-triple").lines.first.to_s.strip
      want = TARGETS[@board][1]
      refuse(3, "clang -print-target-triple gave #{@triple.inspect}, not a #{want.chomp('-')} triple") unless @triple.start_with?(want)
      unreserved_control
      @binding = { dts: sha(@dts_path), config: sha(@config_path), flags: Digest::SHA256.hexdigest(@flags.join("\n") + "\n") }
      @log << "[3] configured: dts #{@binding[:dts][0, 12]} config #{@binding[:config][0, 12]} flags #{@binding[:flags][0, 12]} (#{@flags.size} flags)"
    end

    def clang_compile(step, src, obj, extra = [])
      sh(step, @tools[:clang], *@flags, "-fstack-usage", "-Wall", "-Wextra", *extra, "-c", src, "-o", obj)
      unreserved_side(step, src, obj, extra)
    end

    # The unit's call frames clang did not reserve (unreserved.rb), read from
    # the object's own code against its .su: written beside the .su as
    # <unit>.unreserved, which read_su adds to the frames.
    def unreserved_side(step, src, obj, _extra = [])
      found = unreserved_of(step, src, obj)
      File.write(obj.sub(/\.o\z/, ".unreserved"), found.map { |fn, b| "#{fn}\t#{b}\n" }.join)
      found.each { |fn, b| (@unreserved ||= {})[[File.basename(src), fn]] = b }
    end

    def unreserved_of(step, src, obj)
      objdump = File.join(File.dirname(@tools[:clang]), "llvm-objdump")
      text, st = Open3.capture2(objdump, "-d", obj)
      refuse(step, "#{objdump} -d #{obj} failed") unless st.success?
      frames = File.foreach(obj.sub(/\.o\z/, ".su")).to_h { |l| f = l.split("\t"); [f[0].split(":").last, f[1].to_i] }
      Unreserved.from_disassembly(text, frames)
    rescue Unreserved::Error => e
      refuse(step, "#{src}: #{e.message}")
    end

    # The evidence text for a frame that includes an unreserved call frame.
    def unreserved_note(fn)
      b = (@unreserved || {}).find { |(_, f), _| f == fn }&.last
      b ? ", of which #{b} an unreserved call frame (sp moved by #{b} beyond the .su frame)" : ""
    end

    # The method's control, once per build under this build's flags: a call
    # whose area cannot be reserved must be found, or no unit's silence can be
    # read as "every call frame was reserved".
    def unreserved_control
      src = File.join(@staging, "unreserved_control.c")
      File.write(src, Unreserved.control_source)
      obj = File.join(@staging, "unreserved_control.o")
      sh(3, @tools[:clang], *@flags, "-fstack-usage", "-c", src, "-o", obj)
      got = unreserved_of(3, src, obj)["spc_unreserved_control"].to_i
      refuse(3, "the unreserved call frame method did not find its control (a call with #{Unreserved::CONTROL_ARGS} arguments) in #{obj}") if got < Unreserved::CONTROL_FLOOR
      @unreserved_control = got
    end

    # ---- 4
    def step4_board
      @dts = Dts.read(@dts_path)
      @board_dir = File.join(@staging, "board")
      @board_pkg = Board.generate(dts: @dts, config: @config, effects: File.join(@zt, "effects.tsv"),
                                 adapters: File.join(@tools[:lib], "..", "adapters"), out: @board_dir, board: @board,
                                 release: @release, dts_sha256: @binding[:dts], config_sha256: @binding[:config], flags_sha256: @binding[:flags])
      @board_externs = Declarations.read_package(File.join(@board_dir, "board.rb"), origin: "board")
      @board_rows = AppChecks.read_board_tsv(File.join(@board_dir, "board.tsv"))
      @dtcm_bytes = dtcm_bytes
      @itcm = chosen_memory("zephyr,itcm")
      session_step4
      declared = (@board_externs.externs + @session_externs + @channels.externs + @app.externs).map(&:full)
      unknown = @app.member_refs.reject { |r| declared.include?(r.full) }
      refuse(4, "unknown-member: #{unknown.map { |r| "#{r.full} (line #{r.line})" }.uniq.join(', ')} -- the board #{@board} does not provide it") unless unknown.empty?
      @log << "[4] board package: #{@board_pkg.modules.map { |m| "#{m.name}(#{m.instances.size})" }.join(' ')}"
    end

    # ---- 5
    def step5_providers
      @objs = File.join(@staging, "objects")
      @evidence_dir = File.join(@staging, "evidence")
      FileUtils.mkdir_p(@objs)
      FileUtils.mkdir_p(@evidence_dir)
      inc = ["-I#{File.join(@tools[:lib], '..')}", "-I#{@board_dir}", "-I#{File.join(@staging, 'channels')}"]
      # the channel units, and the transport -- which is glue (the transport
      # thread of §4 sleeps between passes): compiled and measured here,
      # linked, never called from CORE, and not screened as a provider
      FileUtils.mkdir_p(File.join(@staging, "channels"))
      @channels = Channels.generate(@app, xi_base: @board_externs.externs.size, transport: true) if @verification
      @channels.c_files.each { |n, t| File.write(File.join(@staging, "channels", n), t) }
      if (ch = @mutate[:ring_early_publish])
        # Task 12's negative control: the channel's put publishes the head
        # BEFORE the copy, and on every other put holds the window open for
        # longer than any consumer's period, so a consumer is certain to
        # dequeue a slot that was never filled. The build does not refuse it:
        # the label check is `spinel-core-app labels`, not a step, and it does
        # refuse this image statically -- moving the store empties the
        # publication span -- while tests/app/stress.sh shows the run refusing
        # it dynamically. The control is of both.
        #
        # EVERY OTHER put, not every put: measured, a window held open on
        # every put turns the ring into a two-deep delay line -- the consumer
        # always reads the slot's previous message, whose own copy landed
        # after ITS read, so the stream it sees is complete, in order and
        # well-formed, only late (200 of 200 windows entered, no content
        # failure). Sequence and checksum cannot see that; a window that is
        # entered only sometimes mixes late messages with on-time ones, and
        # the sequence goes backwards, which is the defect as it occurs.
        f = File.join(@staging, "channels", "channel_#{ch}_put.c")
        refuse(5, "--mutate-ring-early-publish: the application has no channel #{ch}") unless File.file?(f)
        src = File.read(f)
        store = src[/^\s*atomic_store_explicit\(&spc_channel_#{Regexp.escape(ch)}_head, head \+ 1u, memory_order_release\);\n/] or
          refuse(5, "--mutate-ring-early-publish: the publication store of #{ch} was not found")
        begin_label = src[/^\s*SPC_LABEL\("spc_ring_#{Regexp.escape(ch)}_put_copy_begin"\);\n/] or
          refuse(5, "--mutate-ring-early-publish: the copy label of #{ch} was not found")
        src = src.sub(store, "").sub(begin_label, begin_label + store + "\tif ((head & 1u) == 0u) {\n\t\tz_impl_k_busy_wait(#{@mutate[:ring_hold_us] || 2000}u); /* the window, held open on every other put */\n\t}\n")
        # the channel body includes no Zephyr header (it is host-compilable);
        # the control only ever runs on the target
        src = "void z_impl_k_busy_wait(uint32_t usec_to_wait); /* the body behind Zephyr's k_busy_wait, a syscall inline; the Task 12 negative control */\n" + src
        src = "#include <stdint.h>\n" + src
        File.write(f, src)
        @log << "[5] MUTATED: channel #{ch} publishes before its copy (the Task 12 negative control)"
      end
      @provider_objects = {}
      @glue_objects = {}
      if @verification
        # the recorder (0014 §10 (a)) and the verification-only units: the
        # cycle wrapper, the stimulus thread, the nesting source. All glue:
        # measured, screened but for the block set, never called from CORE
        # except the recorder's two hooks, which the kernel calls in place of
        # the cross-context accesses and whose frames it is told
        cyc0 = (@config["CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC"] || refuse(5, "no CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC")).to_i
        # the plan's limits: the header counts are u8 and 255 is the non-entry actor
        { "contexts" => 3 + @inventory_sources_count, "entries" => @app.scheduled.size, "states" => @app.states.size, "channels" => @app.channels.size }.each do |what, n|
          refuse(5, "#{n} #{what}: more than 250 is refused (the trace counts them in a byte, 255 is the non-entry actor)") if n > 250
        end
        body_max = trace_body_max
        File.write(File.join(@staging, "channels", "recorder.h"), Glue.recorder_h(@app, body_max: body_max, contexts: 3 + @inventory_sources_count, states: @app.states.size, ring: 4096))
        FileUtils.cp(File.join(Glue::TEMPLATES, "recorder.c"), File.join(@staging, "channels", "recorder.c"))
        FileUtils.cp(File.join(Glue::TEMPLATES, "cycles.c"), File.join(@staging, "channels", "cycles.c"))
        stim_c = Glue.stimulus_c(@app, @stim, @board_pkg, cycles_per_sec: cyc0)
        File.write(File.join(@staging, "channels", "stimulus.c"), stim_c)
        # the literal the verification glue allocates for its stimulus thread,
        # read back from the unit rather than repeated here (build.json's
        # threads_unbudgeted)
        @stimulus_stack = stim_c[/^#define SPC_STIMULUS_STACK (\d+)$/, 1].to_i
        File.write(File.join(@staging, "channels", "xwrap.c"), Xwrap.c(@app, xi_base: @board_externs.externs.size + @channels.externs.size)) unless @app.externs.empty?
        if @nest
          File.write(File.join(@staging, "channels", "nest_timer.c"), Glue.nest_timer_c(cycles_per_sec: cyc0, nest_ctx: 3 + @nest_source_index, priority: 3, period_us: @nest[0], busy_us: @nest[1]))
        end
        %w[recorder.c cycles.c stimulus.c xwrap.c nest_timer.c].each do |n|
          src = File.join(@staging, "channels", n)
          next unless File.file?(src)
          obj = File.join(@objs, n.sub(".c", ".o"))
          clang_compile(5, src, obj, inc)
          @glue_objects[n] = obj
        end
      end
      if @stress
        # DECISION 0014 Task 12: the sampling source of a production build.
        # Glue like the others -- measured, screened, linked -- and, like the
        # nesting source, it configures its own interrupt, which the screen
        # admits for a source and nothing else.
        cyc = (@config["CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC"] || refuse(5, "no CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC")).to_i
        refuse(5, "--stress needs at least one channel: it samples the ring spans of Task 8, and this application declares none") if @app.channels.empty?
        FileUtils.mkdir_p(File.join(@staging, "channels"))
        File.write(File.join(@staging, "channels", "stress_timer.c"),
                   Glue.stress_timer_c(@app, cycles_per_sec: cyc, priority: 2, period_us: @stress[:period_us], report_at: @stress[:report_at]))
        obj = File.join(@objs, "stress_timer.o")
        clang_compile(5, File.join(@staging, "channels", "stress_timer.c"), obj, inc)
        @glue_objects["stress_timer.c"] = obj
      end
      if @pcsample
        # the PC sampler of a measurement build: glue, measured, screened and
        # linked like the stress source, and like it a source that connects
        # its own interrupt
        FileUtils.mkdir_p(File.join(@staging, "channels"))
        File.write(File.join(@staging, "channels", "pcsample_timer.c"),
                   Glue.pcsample_timer_c(priority: 2, period_us: @pcsample[:period_us], tics: @pcsample[:tics], capacity: @pcsample[:capacity]))
        obj = File.join(@objs, "pcsample_timer.o")
        clang_compile(5, File.join(@staging, "channels", "pcsample_timer.c"), obj, inc)
        @glue_objects["pcsample_timer.c"] = obj
      end
      @channels.c_files.keys.select { |n| n.end_with?(".c") }.each do |n|
        obj = File.join(@objs, n.sub(".c", ".o"))
        if n == "transport_uart.c"
          extra = ["-DSPC_TRANSPORT_STACK=1024"]
          extra << "-DSPC_VERIFY" if @verification
          extra << "-DSPC_UART_TX_IRQ" if @uart_tx_irq
          clang_compile(5, File.join(@staging, "channels", n), obj, inc + extra)
          @glue_objects[n] = obj
        elsif n == "transport_udp.c"
          # the udp: half of the transport thread: glue, like the UART half
          clang_compile(5, File.join(@staging, "channels", n), obj, inc)
          @glue_objects[n] = obj
        else
          clang_compile(5, File.join(@staging, "channels", n), obj, inc)
          @provider_objects[n] = obj
        end
      end
      # the adapters of the classes the board has (their glue units beside
      # them: the ADC sampler thread), and the port
      @board_pkg.modules.map(&:spec).uniq.each do |spec|
        dir = spec.dir
        obj = File.join(@objs, "adapter_#{File.basename(dir)}.o")
        clang_compile(5, File.join(dir, "adapter.c"), obj, inc + ["-I#{dir}"])
        @provider_objects["adapters/#{File.basename(dir)}/adapter.c"] = obj
        spec.glue.each do |g|
          gobj = File.join(@objs, "adapter_#{File.basename(dir)}_#{File.basename(g, '.c')}.o")
          clang_compile(5, File.join(dir, g), gobj, inc + ["-I#{dir}"])
          @glue_objects["adapters/#{File.basename(dir)}/#{g}"] = gobj
        end
        # the threads the class's glue creates (class.tsv `thread`): each gets a
        # requirement at step 8, its unit recompiled with -D<macro>=R, and the
        # readback at step 10
        spec.threads.each do |t|
          refuse(5, "#{spec.module_name}: thread #{t[:name]} names unit #{t[:unit]}, which is not a glue unit of the class") unless spec.glue.include?(t[:unit])
          # one requirement per thread and one stack object per thread: a
          # repeated name or object would give two requirements the readback
          # and the limits map cannot tell apart
          @adapter_threads ||= []
          refuse(5, "#{spec.module_name}: thread #{t[:name]} is declared twice") if @adapter_threads.any? { |x| x[:name] == t[:name] }
          refuse(5, "#{spec.module_name}: thread #{t[:name]} names stack object #{t[:object]}, already named by thread #{@adapter_threads.find { |x| x[:object] == t[:object] }&.[](:name)}") if @adapter_threads.any? { |x| x[:object] == t[:object] }
          @adapter_threads << t.merge(dir: dir, object_path: File.join(@objs, "adapter_#{File.basename(dir)}_#{File.basename(t[:unit], '.c')}.o"))
        end
      end
      if (x = @mutate[:extra_glue])
        # the control of a glue unit reaching what the screen refuses
        obj = File.join(@objs, "mutate_glue_#{File.basename(x, '.c')}.o")
        clang_compile(5, x, obj, inc)
        @glue_objects[File.basename(x)] = obj
      end
      clang_compile(5, File.join(@board_dir, "board_port.c"), File.join(@objs, "board_port.o"), inc)
      @provider_objects["board_port.c"] = File.join(@objs, "board_port.o")
      # the application's own providers, against the prototype header (a
      # definition that disagrees with it does not compile: the signature
      # check of 0014's C ABI)
      File.write(File.join(@staging, "externs.h"), Glue.externs_h(@app))
      @app.externs.map(&:provider).uniq.each do |p|
        src = File.expand_path(p, File.dirname(@app_path))
        refuse(5, "provider #{p} of the application's core_extern is not a file") unless File.file?(src)
        obj = File.join(@objs, "provider_#{File.basename(p, '.c')}.o")
        clang_compile(5, src, obj, inc + ["-include", File.join(@staging, "externs.h")])
        @provider_objects[p] = obj
      end
      session_step5_compile(inc)
      # the screen on every provider object, and its stack, then the evidence
      screen_rows = Evidence.read_screen(File.join(@zt, "screen.tsv"))
      entry_symbols = @app.scheduled.map { |e, _| "spinel_core_#{e.name}" }
      su_all = {}
      su_owner = {}
      # glue (the transport thread, the Adc sampler) may block -- that is
      # what a thread of §4 does -- and is screened for everything else: no
      # allocation, no interrupt configuration, no call back into CORE
      glue_rows = screen_rows.reject { |r| r.set == "block" }
      # the verification build's nesting source is an interrupt source with
      # its own inventory row (Task 11): it connects its interrupt by design,
      # so the irqconfig set does not apply to it; the rest of the screen does
      # exactly the symbols the source needs, not the set: IRQ_CONNECT and irq_enable/irq_disable as Cortex-M spells them
      source_rows = glue_rows.reject { |r| r.set == "irqconfig" && %w[arm_irq_enable arm_irq_disable arm_irq_priority_set].include?(r.symbol) }
      # an application provider's evidence is its own frame and nothing else,
      # so it may call nothing outside its object: a call into Zephyr or libc
      # (printk's path through picolibc, say) has no frame here, and on the
      # 224-byte scheduler stack it overran into the next thread's
      app_providers = @app.externs.map(&:provider).uniq
      @provider_objects.merge(@glue_objects).each do |name, obj|
        glue = @glue_objects.key?(name)
        source = (@nest && obj == @glue_objects["nest_timer.c"]) || (@stress && obj == @glue_objects["stress_timer.c"]) ||
                 (@pcsample && obj == @glue_objects["pcsample_timer.c"])
        rows_for = source ? source_rows : (glue ? glue_rows : screen_rows)
        found = Evidence.screen(obj, rows_for, entry_symbols, symbols_tool: @tools[:symbols], exempt: session_screen_exempt(name))
        refuse(5, "the #{glue ? 'glue unit' : 'provider'} #{name} calls #{found.map { |f| "#{f['symbol']} (#{f['set']}: #{f['reason']})" }.join('; ')}; the screen of 0014 §6 refuses it") unless found.empty?
        if app_providers.include?(name)
          outside = Evidence.undefined(obj, symbols_tool: @tools[:symbols]).sort
          refuse(5, "the provider #{name} calls #{outside.join(', ')}, which it does not define; its evidence counts only its own frame, so a call outside it has no stack figure") unless outside.empty?
        end
        su = obj.sub(/\.o\z/, ".su")
        refuse(5, "#{name}: no .su beside its object; -fstack-usage wrote nothing") unless File.file?(su)
        rows = read_su(su, qualifiers: true)
        refuse(5, "#{name}: its .su names no function; the unit's frames are unknown") if rows.empty?
        rows.each do |fn, (bytes, qual)|
          refuse(5, "#{name}: #{fn} has a #{qual} frame; a provider's frame must be static") unless qual == "static"
          # one index over every unit: a name two units define is refused
          # rather than summed on a guess (as reserves.rb does for the .su tree)
          refuse(5, "#{fn} is defined in #{su_owner[fn]} and #{name}; the frame index cannot tell them apart") if su_owner.key?(fn)
          su_owner[fn] = name
          su_all[fn] = bytes
        end
      end
      @provider_su = su_all
      # an exported symbol is always emitted, so its frame line exists; a
      # missing one is refused, never read as 0
      frame = ->(fn) { su_all.fetch(fn) { refuse(5, "no -fstack-usage frame for #{fn}; the provider's stack is unknown") } }
      reserves = (@reserves ||= Reserves.read(@mutate[:reserves] || File.join(@zt, "reserves.tsv")))
      @board_externs.externs.each do |e|
        wrapper = "spc_board_#{e.module_name.downcase}_#{e.name}"
        adapter = "spc_adapter_#{class_of(e.module_name)}_#{e.name}"
        drv_item = "drv_#{class_of(e.module_name)}_#{e.name}"
        drv_item = "drv_clock" if class_of(e.module_name) == "clock"
        drv = Reserves.applicable(reserves, drv_item, @config, reserves_board)
        refuse(5, "no applicable reserve #{drv_item} for #{e.full}: Zephyr's part of the member's stack is unknown") unless drv
        bytes = frame.call(wrapper) + frame.call(adapter) + drv.bytes
        row = @board_rows.find { |r| r.module_name == e.module_name }
        Evidence.write(File.join(@evidence_dir, "#{e.symbol}.json"), symbol: e.symbol, object: @provider_objects["board_port.c"],
                       target: @triple, board: @board, release: @release, dts_sha256: @binding[:dts], config_sha256: @binding[:config],
                       flags_sha256: @binding[:flags], stack_bytes: bytes,
                       stack_method: "clang -fstack-usage frames of #{wrapper} (#{frame.call(wrapper)}#{unreserved_note(wrapper)}) and #{adapter} (#{frame.call(adapter)}#{unreserved_note(adapter)}), plus the attested #{drv_item} (#{drv.bytes}, #{drv.evidence})",
                       effects: { "isr_ok" => e.isr_ok, "blocking" => row ? row.blocking == "true" : nil, "row" => row ? "board.tsv (#{row.evidence})" : "none" })
      end
      @channels.externs.each do |e|
        fn = "spc_channel_#{e.module_name.downcase}_#{e.name}"
        Evidence.write(File.join(@evidence_dir, "#{e.symbol}.json"), symbol: e.symbol, object: @provider_objects["channel_#{e.module_name.downcase}_#{e.name}.c"] || refuse(5, "no object for #{e.full}"),
                       target: @triple, board: @board, release: @release, dts_sha256: @binding[:dts], config_sha256: @binding[:config],
                       flags_sha256: @binding[:flags], stack_bytes: frame.call(fn),
                       stack_method: "clang -fstack-usage frame of #{fn}#{unreserved_note(fn)}; the ring calls nothing",
                       effects: { "isr_ok" => true, "blocking" => false, "row" => "generated channel (0014 §5)" })
      end
      @app.externs.each do |e|
        obj = @provider_objects[e.provider]
        syms = Open3.capture2(@tools[:symbols], "--exported", obj).first.lines.map { |l| l.chomp.split("\t").last }
        refuse(5, "provider #{e.provider} does not define #{e.symbol}") unless syms.include?(e.symbol)
        Evidence.write(File.join(@evidence_dir, "#{e.symbol}.json"), symbol: e.symbol, object: obj, target: @triple, board: @board,
                       release: @release, dts_sha256: @binding[:dts], config_sha256: @binding[:config], flags_sha256: @binding[:flags],
                       stack_bytes: frame.call(e.symbol), stack_method: "clang -fstack-usage frame of #{e.symbol}#{unreserved_note(e.symbol)}; the provider's object has no undefined symbol, so it calls nothing outside itself",
                       effects: { "isr_ok" => e.isr_ok, "blocking" => false, "row" => "application core_extern" })
      end
      session_step5_evidence(frame)
      @log << "[5] #{@provider_objects.size} provider objects compiled, screened and measured; #{Dir[File.join(@evidence_dir, '*.json')].size} evidence files"
    end

    def class_of(module_name)
      m = @board_pkg.modules.find { |x| x.name == module_name } or refuse(5, "no board module #{module_name}")
      File.basename(m.spec.dir)
    end

    # ---- 6
    def step6_inventory
      irq_rows = Reserves.read_irq_rows(File.join(@zt, "irq-rows.tsv"))
      @inventory = Inventory.build(@dts, @config, irq_rows, board: reserves_board)
      if @nest
        # the verification-only nesting source (Task 11): CMSDK timer 0 of
        # mps2/an521, IRQ 3 at priority 3, its handler connected by the glue;
        # its cost in the chain is isr_entry_exit plus the handler's measured
        # frame (stack.rb)
        refuse(6, "the nesting source needs the an521 timer@0 node, which the devicetree does not have") unless @dts.compatibles("arm,cmsdk-timer").any? { |n| n.path.end_with?("timer@0") }
        @inventory.sources << Inventory::Source.new(name: "nest_timer", kind: :irq, slot: 16 + 3, irq: 3, priority: 3, node_path: "/soc/timer@0",
                                                    compatible: "arm,cmsdk-timer", handler: "_isr_wrapper", reserve_item: "isr_entry_exit", row: nil)
        @inventory.sources.sort_by!(&:slot)
        @inventory.absent.reject! { |a| a.node_path.end_with?("timer@0") }
      end
      if @stress
        # Task 12's sampling source: CMSDK timer 1 of mps2/an521, IRQ 4, its
        # handler connected by the glue. Budgeted like any other source --
        # isr_entry_exit plus the handler's measured frame -- so the interrupt
        # inequality covers a build that carries it.
        refuse(6, "the sampling source needs the an521 timer@1000 node, which the devicetree does not have") unless @dts.compatibles("arm,cmsdk-timer").any? { |n| n.path.end_with?("timer@1000") }
        @inventory.sources << Inventory::Source.new(name: "stress_timer", kind: :irq, slot: 16 + 4, irq: 4, priority: 2, node_path: "/soc/peripheral@50000000/timer@1000",
                                                    compatible: "arm,cmsdk-timer", handler: "_isr_wrapper", reserve_item: "isr_entry_exit", row: nil)
        @inventory.sources.sort_by!(&:slot)
        @inventory.absent.reject! { |a| a.node_path.end_with?("timer@1000") }
      end
      if @pcsample
        # the PC sampler: GPT1 of the RT1180, IRQ 209, its handler connected by
        # the glue; budgeted like the stress source. The node must be there
        # and disabled: enabled, a driver would own the timer
        # by its label: the peripheral bus is at 0x50000000 in the M33's
        # view and 0x40000000 in the M7's (decision 0023)
        node = @dts.by_label("gpt1")
        refuse(6, "the PC sampler needs the RT1180's gpt1 node, which the devicetree does not have") unless node&.compatible&.include?("nxp,imx-gpt")
        gpt1 = node.path
        refuse(6, "the PC sampler programs GPT1 itself, and the devicetree enables #{gpt1} for a driver") if node.enabled?
        @inventory.sources << Inventory::Source.new(name: "pcsample_timer", kind: :irq, slot: 16 + 209, irq: 209, priority: 2, node_path: gpt1,
                                                    compatible: "nxp,imx-gpt", handler: "_isr_wrapper", reserve_item: "isr_entry_exit", row: nil)
        @inventory.sources.sort_by!(&:slot)
        @inventory.absent.reject! { |a| a.node_path == gpt1 }
      end
      refuse(6, "the interrupt inventory is unknown: #{@inventory.unknown.join('; ')}") unless @inventory.unknown.empty?
      @inventory.sources.each do |s|
        next if Reserves.applicable((@reserves ||= Reserves.read(@mutate[:reserves] || File.join(@zt, "reserves.tsv"))), s.reserve_item, @config, reserves_board)
        refuse(6, "source #{s.name} (slot #{s.slot}) has no applicable reserve #{s.reserve_item}: unknown, and unknown refuses the build under realtime")
      end
      @log << "[6] inventory: #{@inventory.sources.map { |s| "#{s.name}@#{s.priority}" }.join(' ')}; absent drivers: #{@inventory.absent.map(&:compatible).uniq.join(', ')}"
    end

    # Decision 0019's table lists a source by its bytes, and the root the
    # kernel reads is the packed app.rb, whose require and extern lines the
    # packer has rewritten. When the table lists the application's own bytes,
    # the packed root is that source after the packer's rewrite: a table in
    # staging lists it, with the row's reason, and the kernel reads that one
    # (owner, 2026-10-22). Otherwise -- an unlisted source, or a table the
    # kernel would refuse -- the kernel reads this tree's table, and its
    # diagnostic names it.
    def int64_allow_table
      table = @mutate[:int64_allow] || @tools[:int64_allow] or return nil
      hit = CoreApp.int64_listing(File.binread(@app.path), table) or return table
      derived = File.join(@staging, "int64", "core", "int64-allow.tsv")
      FileUtils.mkdir_p(File.dirname(derived))
      File.write(derived, "# derived from #{table} by spinel-core-app (decision 0019)\n" \
                          "pack/app.rb\t#{hit[0]} after the application packer's rewrite: #{hit[1]}\n")
      @log << "[7] int64: #{hit[0]} is listed in #{table}; the packed root is listed in #{derived}"
      derived
    end

    # ---- 7
    def step7_kernel
      @pack = File.join(@staging, "pack")
      FileUtils.mkdir_p(@pack)
      Contracts.pack(@app, @board_externs.externs + @session_externs, @channels.externs, File.join(@tools[:lib], "spinel", "net.rb"), @pack,
                     constants: @board_externs.constants.merge(@session_constants))
      contracts = Contracts.write(@app, @board_externs.externs + @session_externs, @channels.externs, @pack)
      FileUtils.cp_r(@evidence_dir, File.join(@pack, "evidence"))
      allow = int64_allow_table
      @reports = {}
      @core_objects = {}
      contracts.each do |entry, contract|
        obj = File.join(@objs, "core_#{entry}.o")
        report = File.join(@staging, "report_#{entry}.json")
        kh = File.join(@staging, "externs_#{entry}.h")
        verify_flags = @verification ? ["--record-cross", "--record-cross-frame", record_hook_frame.to_s] : []
        # a --stress build also keeps each entry's optimised IR, which Task 12
        # applies Task 5's atomic-closure checks to; the object is the same
        # either way (the flag writes a copy of the IR, it does not change it)
        ir_flags = @stress ? ["--emit-optimised-ir", File.join(@objs, "core_#{entry}.bc")] : []
        site_flags = @failure_sites ? ["--failure-sites", File.join(@staging, "sites", "#{entry}.tsv")] : []
        FileUtils.mkdir_p(File.join(@staging, "sites")) if @failure_sites
        allow_flags = allow ? ["--int64-allow", allow] : []
        sh(7, @tools[:kernel], contract, "--root", @pack, "-o", obj, "--layout", "ptr32-i64-32long", "--clang", @tools[:clang], *site_flags, *allow_flags,
           "--typedump", @tools[:typedump], "--int-width=#{CoreApp::TARGET_BITS}", "--report", report, "--profile", "realtime", "--extern-header", kh, *verify_flags, *ir_flags,
           "--config-binding", "#{@binding[:dts]}:#{@binding[:config]}:#{@binding[:flags]}", "--", *@flags,
           relocate: ->(t) { Contracts.relocate(t, @pack, Contracts.units_of(@app, File.join(@tools[:lib], "spinel", "net.rb"))) })
        # the kernel's prototypes are the authority; step 5's header, which
        # the providers compiled against, must say the same for every
        # application extern this entry calls
        kernel_protos = File.readlines(kh, chomp: true).select { |l| l.include?("(") && l.end_with?(");") }.map { |l| l.squeeze(" ") }
        @app.externs.each do |e|
          mine = Glue.prototype(e).squeeze(" ")
          next unless kernel_protos.any? { |l| l.include?(" #{e.symbol}(") }
          refuse(7, "entry #{entry}: the prototype of #{e.symbol} the provider compiled against (#{mine}) is not the kernel's (#{kernel_protos.find { |l| l.include?(" #{e.symbol}(") }})") unless kernel_protos.include?(mine)
        end
        @reports[entry] = JSON.parse(File.read(report))
        @core_objects[entry] = obj
        undefined = Open3.capture2(@tools[:symbols], "--undefined", obj).first.lines.map { |l| l.chomp.split("\t").last }.sort
        declared = @reports[entry]["application"]["externs"].select { |x| (x["const_args"] || []).any? }.map { |x| x["symbol"] }.sort
        # a verification build's object calls the recorder's hooks in place
        # of its cross-context accesses (only those it has)
        hooks = @verification ? undefined & %w[spc_record_load spc_record_store] : []
        # the AEABI 64-bit division helpers (libgcc): their stack is not
        # attested, which is the deferred D3; a production build refuses an
        # entry that needs them, a verification build admits them so the
        # run can measure them (the cycle wrapper, the painted stacks)
        helpers = undefined & %w[__aeabi_ldivmod __aeabi_uldivmod]
        if !helpers.empty? && !@verification
          refuse(7, "entry #{entry}: the object calls #{helpers.join(' and ')}, the libgcc 64-bit division helper, whose stack is not attested (the plan's deferred D3); a production build refuses it")
        end
        @log << "[7] entry #{entry} calls #{helpers.join(' ')}: admitted in the verification build, its frame measured by the run, not attested" unless helpers.empty?
        refuse(7, "entry #{entry}: the object's undefined set #{undefined.inspect} is not its declared externs #{declared.inspect}") unless undefined - hooks - helpers == declared
        st = @reports[entry]["properties"]["stack_budget"]
        refuse(7, "entry #{entry}: the report's stack budget is not evaluated: #{st['reason']}") unless st["evaluated"]
        # The kernel's own inequality (0010: kernel_stack + interrupt_reserve
        # <= provisioned_stack) has no right-hand side under realtime -- the
        # provision is R, which step 8 derives from this very kernel_stack
        # (0014 §9), and the interrupt side is the MSP inequality over the
        # inventory. So the kernel's verdict here is `unknown` for exactly that
        # reason and no other; the numbers it composed are what step 8 uses.
        unless st["verdict"] == "pass" || (st["verdict"] == "unknown" && st["reason"].to_s.include?("no right-hand side"))
          refuse(7, "entry #{entry}: the report's stack verdict is #{st['verdict']}#{st['reason'] ? ": #{st['reason']}" : ''}")
        end
        refuse(7, "entry #{entry}: the report has no kernel_stack") unless st["kernel_stack"].is_a?(Integer)
        refuse(7, "entry #{entry}: extern_effects #{@reports[entry]['properties']['extern_effects'].inspect}") unless @reports[entry]["properties"]["extern_effects"]["verdict"] == "pass"
      end
      diags = AppChecks.run(@app, { externs: @board_externs.externs + @session_externs, rows: @board_rows }, @channels.externs, @reports)
      refuse(7, "cross-entry checks: #{diags.map(&:to_s).join('; ')}") unless diags.empty?
      session_step7_checks
      @owned = AppChecks.owners(@app, @board_externs.externs, @board_rows, @reports)
      @log << "[7] #{@core_objects.size} entries admitted under realtime; owners: #{@owned.map { |c, l| "#{c}=#{l.map { |m, i| "#{m}[#{i}]" }.join(',')}" }.join(' ')}"
    end

    # ---- 8
    def step8_glue
      cyc = (@config["CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC"] || refuse(8, "no CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC")).to_i
      # the glue converts a period to cycles as period_us * (cycles per
      # second / 1e6): exact only for a whole number of MHz, and the product
      # must fit the 32-bit period the glue keeps
      refuse(8, "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=#{cyc} is not a whole number of MHz; the period conversion would be inexact") unless cyc >= 1_000_000 && (cyc % 1_000_000).zero?
      @app.triggers.each do |t|
        pc = t.period_us * (cyc / 1_000_000)
        refuse(8, "entry #{t.entry}: the period is #{pc} cycles, more than the glue's 32-bit period") if pc > 0xffff_ffff
      end
      verify = nil
      if @verification
        timer_index = @inventory.sources.index { |x| x.name == "systick" } or refuse(8, "no systick source in the inventory")
        verify = { timer_ctx: 3 + timer_index, horizon_us: @stim.horizon, drain_us: @stim.drain, nest_timer: !@nest.nil? }
      end
      cross = @app.states.map(&:name).select { |n| @app.scheduled.select { |e, _| e.params.include?(n) }.map { |_, t| t.context }.uniq.size > 1 }
      main_c = Glue.main_c(@app, @board_pkg, @owned, app_name: @app_name, board: @board, cycles_per_sec: cyc, verification: @verification, verify: verify, cross: cross,
                           adapter_threads: (@adapter_threads || []).map { |t| { name: t[:name], cls: File.basename(t[:dir]) } }, stress: !@stress.nil?, pcsample: !@pcsample.nil?,
                           session: session? ? { base: @session_base, dtcm: @session_dtcm } : nil, pair: pair_glue,
                           failure_sites: @failure_sites ? @app.scheduled.map { |e, _| e.name } + (session? ? Session::ENTRIES : []) : nil)
      File.write(File.join(@staging, "main.c"), main_c)
      inc = ["-I#{File.join(@tools[:lib], '..')}", "-I#{@board_dir}", "-I#{File.join(@staging, 'channels')}"]
      # measure first with a placeholder stack, then compile with R
      clang_compile(8, File.join(@staging, "main.c"), File.join(@objs, "glue_measure.o"), inc)
      glue = read_su(File.join(@objs, "glue_measure.su"), qualifiers: true)
      glue.each { |fn, (_b, q)| refuse(8, "the glue's #{fn} has a #{q} frame; a frame summed into R must be static") unless q == "static" }
      glue = glue.transform_values(&:first)
      # a contract channel (decision 0027 stage 2) has no transport thread:
      # its put or get runs on the entry that calls it
      transport = @provider_su.select { |k, _| k.start_with?("spc_transport_") || k.match?(/\Aspc_channel_.*_(put|get)\z/) }
      transport = {} unless @app.channels.any?(&:framed?) || @verification
      entries = @reports.to_h do |e, rep|
        st = rep["properties"]["stack_budget"]
        [e, { context: @app.context_of(e), kernel_stack: st["kernel_stack"].to_i, evidence: st["evidence"].map { |v| v["kind"] }.uniq.join("+") }]
      end
      found = Reserves::ITEMS.to_h { |i| [i, Reserves.applicable(@reserves, i, @config, reserves_board)] }
      @inventory.sources.each { |s| found[s.reserve_item] ||= Reserves.applicable(@reserves, s.reserve_item, @config, reserves_board) }
      board_tsv = read_board_facts
      # a verification build's extra frames on every path: the recorder's
      # (its hooks, the writer and the emitters, called from CORE, the
      # wrappers and the glue), the cycle wrapper's, and the nesting
      # handler's on its own chain level
      vglue = nil
      if @verification
        vglue = { recorder: read_su(File.join(@objs, "recorder.su")), cycles: read_su(File.join(@objs, "cycles.su")),
                  nest: @nest ? read_su(File.join(@objs, "nest_timer.su")) : {} }
      end
      adapter_threads = (@adapter_threads || []).map do |t|
        t[:items].each { |i| found[i] ||= Reserves.applicable(@reserves, i, @config, reserves_board) }
        frames = read_su(t[:object_path].sub(/\.o\z/, ".su"))
        # the row's entry and init name functions of the unit: the entry so
        # that the frames summed are the ones the thread runs, the init so
        # that what is excluded is the function that runs elsewhere. A
        # mistyped or shifted field names neither and is refused here rather
        # than silently changing the sum.
        [[:entry, "entry"], [:init, "init"]].each do |k, what|
          refuse(8, "#{t[:name]}: the #{what} #{t[k]} is not a function of #{t[:unit]} (its frames are #{frames.keys.sort.join(' ')})") unless frames.key?(t[k])
        end
        { name: t[:name], frames: frames, exclude: [t[:init]], items: t[:items] }
      end
      @verdicts = Stack.check(glue: glue, transport: transport, entries: entries, reserves: found, inventory: @inventory, board: board_tsv, config: @config, verification: @verification, vglue: vglue, adapter_threads: adapter_threads)
      @r_sched = @verdicts.threads.find { |t| t.name == "scheduler thread" }.total
      @r_transport = @verdicts.threads.find { |t| t.name == "transport thread" }&.total
      refuse(8, "the application declares channels and no transport requirement was built") if (@app.channels.any?(&:framed?) || @verification) && @r_transport.nil?
      refuse(8, "the stack inequalities fail: #{@verdicts.failures.join('; ')}") unless @verdicts.pass?
      sched_alloc = @r_sched + (@mutate[:thread_stack_delta] || 0)
      dtcm_capacity_check(sched_alloc)
      clang_compile(8, File.join(@staging, "main.c"), File.join(@objs, "glue.o"), inc + ["-DSPC_SCHEDULER_STACK=#{sched_alloc}"])
      glue2 = read_su(File.join(@objs, "glue.su"))
      refuse(8, "the glue's frames changed between the measuring compile and the final one") unless glue2 == read_su(File.join(@objs, "glue_measure.su"))
      # the transport with its own R
      t = File.join(@staging, "channels", "transport_uart.c")
      if File.file?(t)
        before = read_su(@glue_objects["transport_uart.c"].sub(/\.o\z/, ".su"))
        clang_compile(8, t, @glue_objects["transport_uart.c"], inc + ["-DSPC_TRANSPORT_STACK=#{@r_transport}"] + (@verification ? ["-DSPC_VERIFY"] : []) + (@uart_tx_irq ? ["-DSPC_UART_TX_IRQ"] : []))
        after = read_su(@glue_objects["transport_uart.c"].sub(/\.o\z/, ".su"))
        refuse(8, "the transport's frames changed between the measuring compile and the final one") unless before == after
      end
      # the adapter threads' units with their R
      @r_adapter = {}
      (@adapter_threads || []).each do |t|
        r = @verdicts.threads.find { |x| x.name == "#{t[:name]} thread" }.total
        @r_adapter[t[:name]] = r
        before = read_su(t[:object_path].sub(/\.o\z/, ".su"))
        clang_compile(8, File.join(t[:dir], t[:unit]), t[:object_path], inc + ["-I#{t[:dir]}", "-D#{t[:macro]}=#{r + (@mutate[:adapter_stack_delta] || 0)}"])
        refuse(8, "#{t[:name]}: the unit's frames changed between the measuring compile and the final one") unless read_su(t[:object_path].sub(/\.o\z/, ".su")) == before
      end
      @log << "[8] R(scheduler) = #{@r_sched}, R(transport) = #{@r_transport || 'none'}#{@r_adapter.map { |n, r| ", R(#{n}) = #{r}" }.join}, interrupt chain #{@verdicts.interrupt.total} <= #{@verdicts.interrupt.limit}"
    end

    # The largest record body the application can produce (recorder.h sizes
    # its buffers by it): an XCALL with every scalar at 8 bytes and every
    # buffer argument at 256 (the emitters guard the bound at run time),
    # an ENQ/DEQ with the channel's payload, a PRIVATE with the largest
    # private state, each plus the fixed fields.
    def trace_body_max
      externs = @board_externs.externs + @channels.externs + @app.externs
      xcall = externs.map do |e|
        3 + e.params.sum { |pa| pa.buffer? ? 1 + 4 + 256 : 1 + 8 }
      end.max || 3
      enq = (@app.channels.map(&:size).max || 0) + 10
      priv = (@app.states.map { |st| st.count * Glue::WIDTH.fetch(st.element) }.max || 0) + 5
      [xcall, enq, priv, 40].max
    end

    # The frame the kernel is told for the recorder's hooks: the hook's own
    # frame plus the writer's and the emitter's it reaches (recorder.su).
    def record_hook_frame
      su = read_su(File.join(@objs, "recorder.su"))
      hook = [su.fetch("spc_record_load", 0), su.fetch("spc_record_store", 0)].max
      hook + su.fetch("spc_rec_write", 0) + su.fetch("spc_tr_LOAD", 0) + su.fetch("spc_tr_STORE", 0) + su.fetch("spc_rec_find", 0)
    end

    # {function => bytes}, or with qualifiers {function => [bytes, qualifier]}.
    def read_su(path, qualifiers: false)
      h = {}
      File.foreach(path) do |ln|
        # GCC writes file:line:column:function, clang file:line:function
        m = ln.chomp.match(/\A(.*?):(\d+):(?:(\d+):)?(\S+)\t(\d+)\t([\w,]+)\z/) or refuse(0, "#{path}: unreadable .su line #{ln.inspect}")
        h[m[4]] = qualifiers ? [m[5].to_i, m[6]] : m[5].to_i
      end
      # the call frames the .su leaves out, from the side compile beside it
      side = path.sub(/\.su\z/, ".unreserved")
      if File.file?(side)
        File.foreach(side) do |ln|
          fn, b = ln.chomp.split("\t")
          next unless h.key?(fn)

          qualifiers ? h[fn][0] += b.to_i : h[fn] += b.to_i
        end
      end
      h
    end

    # west's mode and a variable's name for the application's image: a
    # sysbuild with the launcher passes it as <image>_<name>
    def west_mode = @launcher || pair? ? ["--sysbuild"] : []
    attr_reader :sysdir
    # the launcher as the network firmware, for a udp: channel the other core sends
    def launcher_args
      return [] unless @launcher_gen
      net = File.join(@launcher[:dir], "net")
      ["-Dlauncher_SPC_GEN_DIR=#{@launcher_gen}", "-Dlauncher_EXTRA_CONF_FILE=#{File.join(net, "net.conf")}",
       "-Dlauncher_EXTRA_DTC_OVERLAY_FILE=#{File.join(net, "net.overlay")}"]
    end
    def image_var(name) = @launcher || pair? ? "#{File.basename(@zapp)}_#{name}" : name

    # The board key of the traced tables (reserves.tsv, irq-rows.tsv): the
    # table's `reserves_board` where it builds the same Zephyr board as
    # another table (decision 0027's companion), else the board itself. Each
    # row's configuration predicates are still read against this build's.
    def reserves_board = (@reserves_board ||= read_board_facts(0)["reserves_board"]&.first || @board)

    # The NOR offset of the image the board boots (the launcher's, or the
    # companion's in its place)
    def pair_offset = Integer(read_board_facts(11).fetch("launcher_flash_offset") { refuse(11, "the board has a companion and no launcher_flash_offset") }.first)

    def read_board_facts(step = 8)
      path = File.join(@zt, "boards", "#{@board}.tsv")
      refuse(step, "no board facts at #{path}") unless File.file?(path)
      File.readlines(path, chomp: true).reject { |l| l.start_with?("#") || l.start_with?("key\t") || l.strip.empty? }
          .to_h { |l| k, v, e = l.split("\t", 3); [k, [v, e]] }
    end

    # ---- 9
    # what the link takes of this image's own
    def link_objects = @core_objects.values + @provider_objects.values + @glue_objects.values + [File.join(@objs, "glue.o")] + session_link_objects

    def step9_link
      return companion_step9 if companion?

      objects = link_objects
      if (x = @mutate[:extra_source])
        obj = File.join(@objs, "mutate_#{File.basename(x, '.c')}.o")
        clang_compile(9, x, obj, ["-I#{File.join(@tools[:lib], '..')}"])
        objects << obj
      end
      west_env = { "ZEPHYR_BASE" => @tools[:zephyr_base], "ZEPHYR_SDK_INSTALL_DIR" => @tools[:sdk], "PATH" => @tools[:path] }
      if @mutate[:config_touch]
        # the control of a configuration changed after step 3: a value the
        # link's Kconfig pass keeps (a comment it would regenerate away)
        c = File.read(@config_path)
        refuse(9, "the control found no CONFIG_MAIN_STACK_SIZE to change") unless c.match?(/^CONFIG_MAIN_STACK_SIZE=\d+$/)
        File.write(@config_path, c.sub(/^CONFIG_MAIN_STACK_SIZE=(\d+)$/) { "CONFIG_MAIN_STACK_SIZE=#{$1.to_i * 2}" })
      end
      sh(9, "west", "build", *west_mode, "-b", @target, @zapp, "-d", @sysdir, "--", "-DZEPHYR_SDK_INSTALL_DIR=#{@tools[:sdk]}",
         "-D#{image_var('DTC_OVERLAY_FILE')}=#{File.join(@zapp, 'app.overlay')}", "-D#{image_var('SPC_OBJECTS')}=#{objects.join(';')}", *launcher_args, *pair_args(link: true), env: west_env)
      if @launcher
        @launcher_bin = File.join(@sysdir, "launcher", "zephyr", "zephyr.bin")
        refuse(9, "the launcher made no zephyr.bin") unless File.file?(@launcher_bin)
      end
      @elf = File.join(@build, "zephyr", "zephyr.elf")
      refuse(9, "no zephyr.elf after the link") unless File.file?(@elf)
      link_log = File.read(File.join(@staging, "step9.log"))
      refuse(9, "the link log warns about an orphan section: #{link_log.lines.grep(/orphan/).first&.strip}") if link_log.match?(/orphan section/)
      if (slot = @mutate[:reserved_slot])
        # the control of a non-zero reserved slot: the staged image's vector
        # table word is overwritten before step 10 reads it
        words = Inventory.dump_section(@elf, "rom_start", @tools[:objcopy])
        words[Inventory.vector_table_offset(@elf, symbols_tool: @tools[:symbols]) + slot * 4, 4] = [0xdeadbeef].pack("V")
        File.binwrite("#{@elf}.rom_start.mut", words)
        sh(9, @tools[:objcopy], "--update-section", "rom_start=#{@elf}.rom_start.mut", @elf)
      end
      @log << "[9] linked #{@elf}"
    end

    # The companion's step 9: the primary's west call linked it.
    def companion_step9
      @elf = File.join(@build, "zephyr", "zephyr.elf")
      refuse(9, "no zephyr.elf after the primary's link") unless File.file?(@elf)
      link_log = File.read(File.join(@parent.staging, "step9.log"))
      refuse(9, "the link log warns about an orphan section: #{link_log.lines.grep(/orphan/).first&.strip}") if link_log.match?(/orphan section/)
      FileUtils.cp(File.join(@parent.staging, "step9.log"), File.join(@staging, "step9.log"))
      @log << "[9] linked #{@elf} (the primary's sysbuild)"
    end

    # ---- 10
    def step10_checks
      fails = []
      fails << "the DTS changed between steps 3 and 9 (#{sha(@dts_path)[0, 12]} against #{@binding[:dts][0, 12]})" unless sha(@dts_path) == @binding[:dts]
      fails << "the .config changed between steps 3 and 9 (#{sha(@config_path)[0, 12]} against #{@binding[:config][0, 12]})" unless sha(@config_path) == @binding[:config]
      config_now = Reserves.read_config(File.read(@config_path))
      fails << "CONFIG_ISR_STACK_SIZE in the image's configuration is #{config_now['CONFIG_ISR_STACK_SIZE']}, and #{@verdicts.interrupt.limit} was checked" unless config_now["CONFIG_ISR_STACK_SIZE"].to_i == @verdicts.interrupt.limit
      # thread stacks in the image: the requested size, a word the glue
      # records, must be R exactly; the stack object must be K_KERNEL_STACK_LEN
      # of it (without userspace K_THREAD_STACK_DEFINE is K_KERNEL_STACK_DEFINE,
      # include/zephyr/kernel/thread_stack.h#L457 at the pinned commit):
      # ROUND_UP(ROUND_UP(R, ARCH_STACK_PTR_ALIGN) + the reserved guard, the
      # object alignment), at an address of that alignment. Without an MPU
      # stack guard the reserved bytes are 0 and the alignment 8. With one
      # (the Cortex-M7, decision 0023) both are the guard's size,
      # MPU_GUARD_ALIGN_AND_SIZE (arch.h#L202-L211, #L266-L271): the guard sits
      # below the buffer, outside R, and guard_area is 0. Userspace sizes the
      # object to the MPU region and carves the guard out of the buffer: not
      # modelled, refused.
      fails << "CONFIG_USERSPACE=y: the thread stack objects carry MPU sizing this check does not model" if config_now.key?("CONFIG_USERSPACE")
      if config_now.key?("CONFIG_FPU_SHARING") && config_now.key?("CONFIG_MPU_STACK_GUARD")
        fails << "CONFIG_FPU_SHARING=y with CONFIG_MPU_STACK_GUARD=y: the floating-point guard is not modelled"
      end
      @stack_guard = stack_guard(config_now)
      pair_region_checks(fails)
      @image_syms = Open3.capture2(@tools[:symbols], "--addresses", "--defined", @elf).first.lines.to_h { |l| a, s, _t, n = l.chomp.split("\t", 4); [n, [a.to_i(16), s.to_i(16)]] }
      fails.concat(stack_object_checks("spc_scheduler_stack", @r_sched))
      fails.concat(stack_object_checks("spc_transport_stack", @r_transport)) if @app.channels.any?(&:framed?) || @verification
      (@adapter_threads || []).each { |t| fails.concat(stack_object_checks(t[:object], @r_adapter[t[:name]])) }
      # each extern an entry calls resolves to the measured provider object,
      # by the link map (a member no entry calls is garbage-collected from
      # the image with its evidence unused; it is listed, not checked)
      map = File.read(File.join(@build, "zephyr", "zephyr.map"))
      used = @reports.values.flat_map { |r| r["application"]["externs"].map { |x| x["symbol"] } }.uniq
      unused = []
      Dir[File.join(@evidence_dir, "*.json")].each do |ev|
        doc = Evidence.read(ev)
        unless used.include?(doc["symbol"])
          unused << doc["symbol"]
          next
        end
        bound, reason = Evidence.bound?(doc, symbol: doc["symbol"], target: @triple, dts_sha256: @binding[:dts], config_sha256: @binding[:config], flags_sha256: @binding[:flags])
        fails << "evidence #{File.basename(ev)}: #{reason}" unless bound
        obj = File.basename(doc["object"]["file"])
        fails << "#{doc['symbol']} is not defined by the measured provider object #{obj} in the link map" unless map_defines?(map, obj, doc["symbol"])
      end
      @log << "[10] evidence bound and linked for #{used.size} externs; unused by every entry: #{unused.sort.join(' ')}"
      # the objects linked are the ones measured (§8 step 10): every input
      # object of the map that is not Zephyr's own build output is one of
      # the measured objects, and every measured object is in the map
      measured = (@core_objects.values + @provider_objects.values + @glue_objects.values + [File.join(@objs, "glue.o")] + session_link_objects).map { |o| File.expand_path(o) }.uniq.sort
      # The generated CMakeLists gives our objects to the `app` library, which
      # Zephyr links under --whole-archive and ahead of libkernel.a, so every
      # one of them is in the image and a kernel member only our glue needs is
      # still pulled. In the map they are members: `libapp.a(glue.o)`. Both
      # spellings are read, and a member of any OTHER archive is Zephyr's own
      # build output, which this accounting ignores as it always has.
      members = map.scan(/\blibapp\.a\((\S+\.o)\)/).flatten.map { |b2| File.expand_path(b2, @objs) }
      linked = (map.lines.filter_map { |l| l[/\s(\S+\.o)\s*\z/, 1] }.map { |o| File.expand_path(o, @build) } + members).uniq.sort
      foreign = linked.reject { |o| o.start_with?(File.expand_path(@build) + "/") || measured.include?(o) }
      fails << "objects linked that were not measured: #{foreign.map { |o| File.basename(o) }.join(' ')}" unless foreign.empty?
      absent_objs = measured - linked
      fails << "measured objects absent from the link: #{absent_objs.map { |o| File.basename(o) }.join(' ')}" unless absent_objs.empty?
      @log << "[10] #{measured.size} measured objects are the #{linked.size - (linked - measured).size} non-Zephyr objects of the link"
      session_step10_checks(map, fails)
      # the vector table
      vc = Reserves.read_vector_classes(File.join(@zt, "vector-classes.tsv"))
      @slots, slot_fails = Inventory.classify_vectors(@elf, @inventory, vc, config_now, symbols_tool: @tools[:symbols], objcopy: @tools[:objcopy])
      fails.concat(slot_fails)
      # memory: the allocated sections by their flags -- writable ones live
      # in RAM (datas, bss, noinit, device_states...), read-only ones in
      # flash (text, rodata, the tables); NOBITS take no flash. The image
      # is executed in place, so RAM holds the writable sections only.
      sec = Open3.capture2(@tools[:readelf], "-S", "-W", @elf).first
      data = 0; bss = 0; flash = 0
      sec.each_line do |l|
        m = l.match(/\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+(\S+)\s/) or next
        flags = m[6]
        next unless flags.include?("A")
        size = m[5].to_i(16)
        if !flags.include?("W") then flash += size
        elsif m[2] == "NOBITS" then bss += size
        else data += size; flash += size # initialised data is copied from its flash image
        end
      end
      refuse(10, "the image has no writable allocated section; the section table was not read") if data + bss == 0
      gate = Stack.memory_gate({ data: data, bss: bss }, read_board_facts)
      fails << gate.reason unless gate.pass?
      @memory = { data: data, bss: bss, flash: flash, limit: gate.limit }
      refuse(10, fails.join("; ")) unless fails.empty?
      @log << "[10] digests unchanged; stacks #{@r_sched}/#{@r_transport || '-'}; ISR #{@verdicts.interrupt.limit}; #{@slots.size} vector slots classified (#{@slots.group_by(&:klass).transform_values(&:size).map { |k, n| "#{k} #{n}" }.join(', ')}); data+bss #{data + bss} of #{gate.limit}"
    end

    # GNU ld's map lists each input section with its object on one line and
    # the symbols it defines, indented, on the following lines:
    #   .text.spc_board_led_set
    #                  0x... 0x... .../objects/board_port.o
    #                  0x...        spc_board_led_set
    def map_defines?(map, object, symbol)
      lines = map.lines
      lines.each_with_index.any? do |l, i|
        next false unless l.include?("/#{object}") || l.strip.end_with?(object) || l.include?("libapp.a(#{object})")
        lines[(i + 1)..(i + 8)].to_a.take_while { |x| x.start_with?(" ") && !x.include?(".o") }.any? { |x| x.split.last == symbol }
      end
    end

    STACK_ALIGN = 8 # ARCH_STACK_PTR_ALIGN on Cortex-M (AAPCS: the stack pointer is 8-byte aligned at a call)

    # The MPU stack guard of the configuration: [reserved bytes, object
    # alignment]. MPU_GUARD_ALIGN_AND_SIZE is 0x40 when
    # CONFIG_ARM_MPU_REGION_MIN_ALIGN_AND_SIZE <= 0x20, else that size; the
    # object alignment Z_MPU_GUARD_ALIGN is the same without the
    # floating-point guard (arch.h#L202-L246).
    def stack_guard(config)
      return [0, STACK_ALIGN] unless config.key?("CONFIG_MPU_STACK_GUARD")
      min = (config["CONFIG_ARM_MPU_REGION_MIN_ALIGN_AND_SIZE"] or refuse(10, "CONFIG_MPU_STACK_GUARD=y with no CONFIG_ARM_MPU_REGION_MIN_ALIGN_AND_SIZE")).to_i
      g = min <= 0x20 ? 0x40 : min
      [g, [STACK_ALIGN, g].max]
    end

    # The node chosen as `prop` (zephyr,dtcm, zephyr,itcm): [address, bytes]
    # from its reg, or nil on a board that chooses none
    def chosen_memory(prop)
      ref = @dts.by_path("/chosen")&.[](prop)&.flatten&.first
      return nil unless ref.is_a?(Dts::Ref)
      node = @dts.resolve(ref, "chosen #{prop}")
      return nil unless node.enabled?
      reg = node.cells("reg")
      refuse(4, "the #{prop} node #{node.path} has reg #{reg.inspect}, not one address and one size") unless reg&.size == 2
      reg
    end

    # The data TCM's bytes, or nil on a board that chooses no zephyr,dtcm
    # (the glue then keeps the scheduler stack, and core_session's dtcm:
    # fields, in ordinary RAM).
    def dtcm_bytes = chosen_memory("zephyr,dtcm")&.last

    # What the glue puts in the data TCM must fit it: the scheduler stack's
    # object (K_KERNEL_STACK_LEN of its size, with the MPU guard where the
    # board has one) after the session's dtcm: fields, each 8-aligned, the
    # whole rounded to the stack's alignment (0021, the screen in DTCM;
    # decision 0023 for the M7).
    def dtcm_capacity_check(sched_alloc)
      return unless @dtcm_bytes
      guard, align = stack_guard(@config)
      stack = ((sched_alloc + STACK_ALIGN - 1) / STACK_ALIGN * STACK_ALIGN + guard + align - 1) / align * align
      fields = session? ? session_dtcm_bytes : 0
      need = (fields + align - 1) / align * align + stack
      names = session? && !@session_dtcm.empty? ? " and the session's dtcm: fields (#{@session_dtcm.map { |f| "#{f} #{session_field_bytes(f)} B" }.join(', ')})" : ""
      refuse(8, "the data TCM holds #{@dtcm_bytes} B; the scheduler stack (#{stack} B)#{names} need #{need} B") if need > @dtcm_bytes
      @log << "[8] data TCM: #{need} of #{@dtcm_bytes} B (scheduler stack #{stack} B, session fields #{fields} B)"
    end

    def stack_object_checks(name, r)
      out = []
      addr, size = @image_syms[name]
      requested = image_word("#{name}_size")
      out << "the image's #{name}_size word is #{requested.inspect}; R is #{r}" unless requested == r
      guard, align = @stack_guard || [0, STACK_ALIGN]
      expected = ((r + STACK_ALIGN - 1) / STACK_ALIGN * STACK_ALIGN + guard + align - 1) / align * align
      how = guard.zero? ? "rounded to the #{STACK_ALIGN}-byte stack alignment" : "rounded to #{STACK_ALIGN}, plus the #{guard}-byte MPU guard, rounded to #{align}"
      out << "the image's #{name} object is #{size.inspect} bytes; R #{r} #{how} is #{expected}" unless size == expected
      out << "the image's #{name} object is at #{format('%#x', addr)}, not #{align}-byte aligned" if addr && (addr % align).nonzero?
      # it lies in the image's RAM or its data TCM: a stack linked anywhere
      # else (a data-TCM section with no region, at address 0) is not memory
      # the thread can use (decision 0027: the companion's table once did this)
      if addr && size
        rams = stack_memories
        unless rams.any? { |_, base, bytes| addr >= base && addr + size <= base + bytes }
          out << "the image's #{name} object is at #{format('%#x', addr)}..#{format('%#x', addr + size)}, in none of #{rams.map { |n, b, z| "#{n} #{format('%#x', b)}..#{format('%#x', b + z)}" }.join(' and ')}"
        end
      end
      out
    end

    # The memories a thread stack may be linked in: the RAM the image links
    # (CONFIG_SRAM_BASE_ADDRESS and CONFIG_SRAM_SIZE, in KB) and the data TCM
    # its zephyr,dtcm chooses, if any.
    def stack_memories
      @stack_memories ||= begin
        conf = File.read(@config_path)
        base = conf[/^CONFIG_SRAM_BASE_ADDRESS=(0x\h+|\d+)$/, 1]
        kb = conf[/^CONFIG_SRAM_SIZE=(\d+)$/, 1]
        out = base && kb ? [["the RAM (CONFIG_SRAM_BASE_ADDRESS)", Integer(base), kb.to_i * 1024]] : []
        if (d = chosen_memory("zephyr,dtcm"))
          out << ["the data TCM (zephyr,dtcm)", d[0], d[1]]
        end
        out
      end
    end

    # A 32-bit little-endian word of the image, by the symbol that names it.
    def image_word(name)
      addr, size = @image_syms.fetch(name) { refuse(10, "the image has no #{name}") }
      refuse(10, "#{name} is #{size} bytes, not a word") unless size == 4
      # the allocated section holding the address, from the section table,
      # then its bytes (llvm-objdump -s does not honour an address window)
      sections = sh(10, @tools[:readelf], "-S", "-W", @elf).lines.filter_map do |l|
        m = l.match(/\A\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+\S+\s+(\S+)/) or next
        next unless m[5].include?("A")
        { name: m[1], addr: m[2].to_i(16), size: m[4].to_i(16) }
      end
      sec = sections.find { |x| addr >= x[:addr] && addr + 4 <= x[:addr] + x[:size] } or refuse(10, "no allocated section holds #{name} (#{format('%#x', addr)})")
      bytes = Inventory.dump_section(@elf, sec[:name], @tools[:objcopy])
      bytes[(addr - sec[:addr]), 4].unpack1("V")
    end

    # ---- 11
    def step11_publish
      fw = File.join(@out, "firmware")
      FileUtils.mkdir_p(fw)
      FileUtils.cp(@elf, File.join(fw, "zephyr.elf"))
      # a session build's image, as Zephyr's build made it: decision 0021's
      # lane writes it at the start of the NOR, with the session after it
      bin = File.join(@build, "zephyr", "zephyr.bin")
      if session? || companion?
        refuse(11, "core_session: the build made no zephyr.bin to write") unless File.file?(bin)
        FileUtils.cp(bin, File.join(fw, "zephyr.bin"))
      end
      FileUtils.cp(File.join(@build, "zephyr", "zephyr.map"), File.join(fw, "zephyr.map"))
      if pair?
        # decision 0027: the companion is the image the board boots, written
        # where the launcher is; its own firmware directory beside
        cfw = File.join(@child.out, "firmware")
        FileUtils.cp(File.join(cfw, "zephyr.bin"), File.join(fw, "launcher.bin"))
        FileUtils.cp(File.join(cfw, "zephyr.elf"), File.join(fw, "launcher.elf"))
        FileUtils.cp_r(cfw, File.join(fw, PairSteps::COMPANION_IMAGE))
        @launcher_bin = File.join(fw, "launcher.bin")
      end
      if @launcher
        # the launcher, the image the board boots (decision 0023); the lane
        # writes it at its offset and the application at its own
        FileUtils.cp(@launcher_bin, File.join(fw, "launcher.bin"))
        FileUtils.cp(File.join(File.dirname(@launcher_bin), "zephyr.elf"), File.join(fw, "launcher.elf"))
      end
      FileUtils.cp(@dts_path, File.join(fw, "zephyr.dts"))
      FileUtils.cp(@config_path, File.join(fw, "config"))
      FileUtils.cp_r(@evidence_dir, File.join(fw, "evidence"))
      # the measured objects the evidence names by file and digest
      FileUtils.mkdir_p(File.join(fw, "objects"))
      (@provider_objects.values + @glue_objects.values + @core_objects.values + [File.join(@objs, "glue.o")]).each do |o|
        FileUtils.cp(o, File.join(fw, "objects", File.basename(o)))
        su = o.sub(/\.o\z/, ".su")
        FileUtils.cp(su, File.join(fw, "objects", File.basename(su))) if File.file?(su)
      end
      @reports.each { |e, r| File.write(File.join(fw, "report_#{e}.json"), JSON.pretty_generate(r) + "\n") }
      Dir[File.join(@objs, "core_*.bc")].each { |bc| FileUtils.cp(bc, File.join(fw, "objects", File.basename(bc))) } if @stress
      FileUtils.cp_r(@board_dir, File.join(fw, "board"))
      FileUtils.cp(File.join(@staging, "main.c"), File.join(fw, "main.c"))
      FileUtils.cp(File.join(@staging, "step9.log"), File.join(fw, "link.log"))
      publish_failure_sites(File.join(fw, "sites")) if @failure_sites
      File.write(File.join(fw, "build.json"), JSON.pretty_generate(summary) + "\n")
      File.write(File.join(@out, "build.log"), (@log + (@child ? @child.log.map { |l| "companion #{l}" } : [])).join("\n") + "\n")
      FileUtils.rm_rf(@staging)
      @log << "[11] published #{fw}"
    end

    def summary
      {
        "format" => "spinel-core-app-build", "version" => 1, "app" => @app_name, "board" => @board, "target" => @target,
        "verification" => @verification, "binding" => @binding,
        **(@launcher ? { "launcher" => { "board" => @launcher[:board], "file" => "launcher.bin", "offset" => format("%#x", @launcher[:offset]),
                                         "sha256" => Digest::SHA256.file(@launcher_bin).hexdigest } } : {}),
        **(pair? ? { "launcher" => { "board" => @child.target, "file" => "launcher.bin", "offset" => format("%#x", pair_offset),
                                     "sha256" => Digest::SHA256.file(@launcher_bin).hexdigest, "companion" => true } } : {}),
        **pair_summary,
        "stacks" => {
          "threads" => @verdicts.threads.map { |t| { "name" => t.name, "requirement" => t.total, "limit" => t.limit, "verdict" => t.verdict.to_s, "terms" => t.terms.map { |x| { "name" => x.name, "bytes" => x.bytes, "evidence" => x.evidence, "detail" => x.detail } } } },
          "interrupt" => { "chain" => @verdicts.interrupt.terms.map { |x| { "name" => x.name, "bytes" => x.bytes, "evidence" => x.evidence, "detail" => x.detail } }, "requirement" => @verdicts.interrupt.total, "limit" => @verdicts.interrupt.limit, "verdict" => @verdicts.interrupt.verdict.to_s },
          "gates" => @verdicts.gates.map { |g| { "name" => g.name, "verdict" => g.verdict.to_s } },
          "evidence_kinds" => @verdicts.evidence_kinds,
        },
        "inventory" => @inventory.sources.map { |s| { "name" => s.name, "slot" => s.slot, "priority" => s.priority, "reserve" => s.reserve_item, "compatible" => s.compatible } },
        "absent_drivers" => @inventory.absent.map { |a| { "node" => a.node_path, "compatible" => a.compatible, "symbols" => a.symbols } },
        "vector_slots" => @slots.group_by(&:klass).transform_values(&:size).transform_keys(&:to_s),
        "memory" => @memory,
        # decision 0041 stage 2: the data regions beside the states (fiber
        # frames and pools among them): each context's data stack, with
        # what each entry's kernel report proved of it
        "scratch" => @app.scratches.map { |ctx, bytes|
          { "context" => ctx, "symbol" => "spc_scratch_#{ctx}", "bytes" => bytes,
            "entries" => @reports.select { |e, _| @app.context_of(e) == ctx }.to_h { |e, r|
              sc = r.dig("application", "scratch") || {}
              [e, { "worst_bytes" => sc["worst_bytes"], "evidence" => sc["evidence"] }] } } },
        "states" => @app.states.map { |st| { "name" => st.name, "element" => st.element, "count" => st.count } },
        # the call frames clang did not reserve, already in the .su frames
        # above (unreserved.rb), and the method's control on this build
        "unreserved_call_frames" => { "control" => @unreserved_control,
                                      "frames" => (@unreserved || {}).sort.map { |(u, fn), b| { "unit" => u, "function" => fn, "bytes" => b, "method" => "sp moved by #{b} beyond the .su frame: unreserved call frame" } } },
        # Threads with a literal stack and no requirement. Every thread the
        # adapters' glue creates has one (class.tsv `thread`), so a
        # production build's list is empty and the field stays so a reader
        # sees the claim is total for that build. A verification build adds
        # the stimulus thread, which the verification glue creates with a
        # literal stack outside the inequalities: it exists only to drive
        # the run and is not part of what a production image claims.
        "threads_unbudgeted" => (@verification ? [{ "entry" => "spc_stimulus_thread", "stack" => @stimulus_stack,
                                                    "unit" => "channels/stimulus.c",
                                                    "measured_frames" => read_su(File.join(@objs, "stimulus.su")),
                                                    "budgeted" => false,
                                                    "reason" => "the verification stimulus thread: a literal stack outside the inequalities, present only in a -DSPC_VERIFY build" }] : []),
        "adapter_threads" => (@adapter_threads || []).map { |t| { "name" => t[:name], "unit" => "adapters/#{File.basename(t[:dir])}/#{t[:unit]}", "object" => t[:object], "requirement" => @r_adapter[t[:name]], "items" => t[:items],
                                                                 # the init runs on Zephyr's main thread, whose stack no
                                                                 # inequality bounds (0014's honest boundary); its frame is
                                                                 # published rather than dropped
                                                                 "excluded" => { t[:init] => read_su(t[:object_path].sub(/\.o\z/, ".su"))[t[:init]] } } },
        "qemu" => @qemu,
        "entries" => @reports.to_h { |e, r| [e, { "kernel_stack" => r["properties"]["stack_budget"]["kernel_stack"], "context" => @app.context_of(e) }] },
      }.merge(session? ? { "session" => session_summary } : {})
       .merge(@failure_sites ? { "failure_sites" => {
         "tables" => "sites/", "line" => "SPC_FAILURE_SITE <entry> <status> <site>",
         "stacks" => "debug: the failing paths store their site and main polls at the lowest priority, so this " \
                     "build's stack figures are a debugging build's, not the production build's claim" } } : {})
    end

    # The site tables (spinel-core-kernel --failure-sites) beside the
    # firmware: the application's entries with each place relocated from the
    # packed root to the application's own file and line, and the session's
    # entries with their tables and pack maps as their build wrote them.
    def publish_failure_sites(dir)
      FileUtils.mkdir_p(dir)
      units = Contracts.units_of(@app, File.join(@tools[:lib], "spinel", "net.rb"))
      Dir[File.join(@staging, "sites", "*.tsv")].each do |t|
        text = File.readlines(t).map do |l|
          f = l.chomp.split("\t", -1)
          next l unless f[0] =~ /\A\d+\z/
          placed = Contracts.relocate("#{f[1]}:#{f[2]}:", @pack, units)
          file, line = placed.match(/\A(.*):(\d+):\z/)&.captures || [f[1], f[2]]
          ([f[0], file, line] + f[3..]).join("\t") + "\n"
        end.join
        File.write(File.join(dir, File.basename(t)), text)
      end
      (session? ? Session::ENTRIES : []).each do |e|
        FileUtils.cp(File.join(@session_objects, "#{e}.sites.tsv"), File.join(dir, "#{e}.tsv"))
        FileUtils.cp(File.join(@session_objects, "#{e}.map.tsv"), File.join(dir, "#{e}.map.tsv"))
      end
    end
  end
end
