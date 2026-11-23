# frozen_string_literal: true
#
# tools/app/lib/core_app/pair_steps.rb -- decision 0027's stage 1: an
# application for the FRDM-IMXRT1186's Cortex-M7 built together with a Spinel
# application for its Cortex-M33 (`spinel-core-app build --companion APP`).
#
# The M7's build is the primary. Its board table names the companion's board
# (`companion_board`); the companion is a second Pipeline whose steps run
# between the primary's own, so that one sysbuild configures and links both:
#
#   - step 2 writes the companion's Zephyr application first, and the
#     primary's sysbuild.cmake adds it as the image `companion`, in place of
#     tools/app/launcher;
#   - step 3 configures both with one west call; the companion reads its
#     image's directory of that sysbuild;
#   - after step 4 both ids are known (session_steps.rb's image_id), and the
#     pair id is a digest of the two; each image's glue carries it;
#   - step 9 links both with one west call, each image with its own objects;
#   - steps 10 and 11 check and publish each, the companion under
#     <out>/companion and its binary as the firmware's launcher.bin.
#
# The pair words (tools/app/ring/ring_abi.h, line 11) carry the ids from the
# M33 to the M7, which prints them for the lane. A build of the pair with a
# udp: channel on either side is refused: the network firmware is the M33's
# other image, and the two do not run together (owner, 2026-10-26).
#
# Stage 2: the channels both applications declare with one `.channel`
# contract (core_channel.rb). Step 1 of each image sets each channel's
# direction from its board's `core` fact; after both, the pair's contracts
# are matched and laid out once, in name order, and each image's channel
# package is generated from the same layout. The companion writes the table
# and the descriptors at PRE_KERNEL_1; the M7 checks them at boot.
#
# Decision 0028: an entry of the consumer's application declared with
# `wake: :channel` gives that channel a doorbell. Its MU and interrupt are
# the boards' `doorbell` facts (Q1): the consumer's receive is the
# producer's send, on the same MU. The descriptor's notify names them, the
# producer's put rings by writing its own side's GCR (Q2), and the
# consumer's glue takes the MU's interrupt through Zephyr's driver.
module CoreApp
  module PairSteps
    COMPANION_IMAGE = "companion"

    attr_accessor :pair_id
    attr_reader :parent

    def pair? = !@child.nil?
    def companion? = !@parent.nil?

    def pair_new_child
      facts = read_board_facts(0)
      cb = facts["companion_board"] or refuse(0, "--companion: the board #{@board} names no companion_board in its table")
      refuse(0, "--companion is a production build's; it cannot be combined with --verify, --stress or --pcsample") if @verification || @stress || @pcsample
      @child = Pipeline.new(app_path: @companion_path, board: cb.first, out: File.join(@out, COMPANION_IMAGE), tools: @tools,
                            release: @release, keep_staging: @keep_staging, parent: self,
                            mutate: @mutate.slice(:consumer_stopped, :channel_cacheable, :doorbell_unrung, :doorbell_unenabled, :doorbell_notify))
      FileUtils.rm_rf(@child.staging)
      FileUtils.mkdir_p(@child.staging)
      FileUtils.rm_rf(File.join(@child.out, "firmware"))
    end

    # the network firmware is the M33's other image (step 1)
    def pair_step1
      return unless pair? || companion?
      udp = @app.channels.select(&:udp)
      return if udp.empty?

      refuse(1, "#{udp.map(&:name).join(', ')}: a udp: channel needs the M33's network firmware, and a build with a Spinel " \
                "companion on the M33 is refused with it (decision 0027, owner 2026-10-26)")
    end

    # Step 1 of each image (R6, R20): the board's core is one end of each
    # contract channel, which sets its direction; a contract channel needs
    # the pair.
    def contract_step1
      cs = @app.channels.select(&:contract)
      woken = @app.triggers.select(&:wake)
      unless woken.empty?
        refuse(1, "wake-verify: entry #{woken.first.entry}: wake: is refused in a verification build for now: an entry released before its period is a release the trace does not record (decision 0028 Q4)") if @verification
        woken.each do |t|
          next if cs.any? { |c| c.name == t.wake }

          refuse(1, "wake-channel: entry #{t.entry}: wake: :#{t.wake} names no contract channel of #{File.basename(@app_path)}; a doorbell is a .channel contract's (decision 0028)")
        end
      end
      return if cs.empty?

      core = read_board_facts(1)["core"]&.first
      cs.each do |c|
        k = c.contract
        unless [k.from, k.to].include?(core)
          refuse(1, "channel-not-this-core: #{File.basename(@app_path)} is built for #{@board} (core #{core || 'none'}), which is neither from (#{k.from}) nor to (#{k.to}) of channel #{c.name}")
        end
        c.direction = core == k.from ? "out" : "in"
        refuse(1, "channel-pair: channel #{c.name} crosses to #{core == k.from ? k.to : k.from}; build the pair with --companion") unless pair? || companion?
      end
      woken.each do |t|
        c = cs.find { |x| x.name == t.wake }
        next if c.direction == "in"

        refuse(1, "wake-channel: entry #{t.entry}: wake: :#{t.wake}: this core (#{core}) produces channel #{c.name}; the doorbell wakes its consumer, #{c.contract.to}")
      end
    end

    # The board's doorbell fact (decision 0028 Q1): its side's devicetree
    # label, that side's base in this core's view, and the general-purpose
    # interrupts it sends and receives on; nil when the table names none.
    def doorbell_fact(step)
      v = read_board_facts(step)["doorbell"] or return nil
      label, base, sw, send, rw, recv = v.first.split
      mu = label.to_s[/\Ambox([12])_[ab]\z/, 1]
      refuse(step, "the board's doorbell fact is `<mboxN_a|b> <base> send <n> receive <n>`, not #{v.first.inspect}") unless mu && sw == "send" && rw == "receive" &&
                                                                                                    [send, recv].all? { |x| x.to_s.match?(/\A[0-3]\z/) } && base.to_s.match?(/\A0x\h{8}\z/)
      { label: label, mu: mu.to_i, base: Integer(base), send: send.to_i, receive: recv.to_i,
        free: read_board_facts(step)["doorbell_free"]&.first.to_s.split }
    end

    attr_accessor :doorbells

    # After both images' step 1: each channel an entry of its consumer names
    # with wake: gets its doorbell, from both boards' facts, the same for both
    # images; {name => {notify:, mu:, gi:, gcr:, consumer:}}. 0028's controls:
    # --mutate-doorbell-notify CORE gives that core's descriptor check another
    # notify than the one the companion writes.
    def pair_doorbells
      bells = {}
      [self, @child].each do |pl|
        other = pl.equal?(self) ? @child : self
        pl.app.triggers.select(&:wake).each do |t|
          next if bells.key?(t.wake)

          mine = pl.doorbell_fact(1) or refuse(1, "doorbell: #{pl.board} names no doorbell in its table, and #{File.basename(pl.app_path)}'s entry #{t.entry} is woken by channel #{t.wake}")
          theirs = other.doorbell_fact(1) or refuse(1, "doorbell: #{other.board} names no doorbell in its table, and it produces channel #{t.wake}, which #{pl.board} is woken by")
          unless mine[:mu] == theirs[:mu] && mine[:receive] == theirs[:send]
            refuse(1, "doorbell: channel #{t.wake}: #{pl.board} receives on MU#{mine[:mu]} GIR#{mine[:receive]} and #{other.board} sends on MU#{theirs[:mu]} GIR#{theirs[:send]}; the two boards' doorbell facts must name one MU and one interrupt")
          end
          bells[t.wake] = { notify: mine[:mu] | (mine[:receive] << 2), mu: mine[:mu], gi: mine[:receive], label: mine[:label], free: mine[:free],
                            gcr: theirs[:base] + 0x114, consumer: pl.companion? ? "companion" : "primary" }
        end
      end
      [self, @child].each do |pl|
        pl.doorbells = bells
        core = pl.read_board_facts(1)["core"]&.first
        pl.app.channels.select(&:contract).each do |c|
          b = bells[c.name] or next

          want = @mutate[:doorbell_notify] == core ? b[:notify] ^ 0x8 : b[:notify]
          c.doorbell = { notify: b[:notify], want: want, gi: b[:gi], gcr: b[:gcr],
                         unrung: c.direction == "out" && @mutate[:doorbell_unrung] == c.name }
        end
        pl.log << "[1] doorbell: #{bells.map { |n, b| "channel #{n} on MU#{b[:mu]} GIR#{b[:gi]}, notify 0x#{format('%02x', b[:notify])}" }.join(', ')}" unless bells.empty?
      end
      @log << "[1] control: the #{@mutate[:doorbell_notify]} image checks another notify" if @mutate[:doorbell_notify]
      @log << "[1] control: the put of #{@mutate[:doorbell_unrung]} never rings" if @mutate[:doorbell_unrung]
      @log << "[1] control: the consumer never enables the MU's interrupt" if @mutate[:doorbell_unenabled]
    end

    # After both images' step 1 (R21, R22, R25, and the region's R23, R24):
    # each contract channel named by both applications with the same file,
    # one owner of the UART, and the region laid out once for both.
    def pair_contracts
      mine = @app.channels.select(&:contract).to_h { |c| [c.name, c] }
      theirs = @child.app.channels.select(&:contract).to_h { |c| [c.name, c] }
      a = File.basename(@app_path)
      b = File.basename(@companion_path)
      (mine.keys | theirs.keys).sort.each do |n|
        x, y = mine[n], theirs[n]
        refuse(1, "channel-pair: channel #{n}: #{x ? a : b} names it and #{x ? b : a} does not; both ends name the same contract") unless x && y
        next if x.contract.digest == y.contract.digest

        refuse(1, "channel-pair: channel #{n}: #{a} names #{x.contract.path_shown} (sha256 #{x.contract.digest}), #{b} names #{y.contract.path_shown} (sha256 #{y.contract.digest})")
      end
      if @app.channels.any?(&:uart) && @child.app.channels.any?(&:uart)
        refuse(1, "channel-uart: both #{a} and #{b} declare a uart: channel; the pair has one VCOM (LPUART1), and its owner is the core whose application declares one")
      end
      layout, why = CoreChannel.layout(mine.values.map(&:contract))
      refuse(1, "channel-region: #{why.first}") unless layout
      pair_doorbells
      [self, @child].each do |pl|
        pl.channel_layout = layout
        pl.app.channels.select(&:contract).each { |c| c.ring = [layout.index(c.name), layout.offset(c.name)] }
        pl.generate_channels
      end
    end

    attr_accessor :channel_layout

    # The two ids, after both images' step 4, and the pair id over them and
    # each contract the pair's channels use.
    def pair_ids
      own = @child.image_id
      contracts = (@channel_layout&.channels || []).map { |k, _| "channel #{k.name} #{k.digest}\n" }.join
      @pair_id = Digest::SHA256.hexdigest("spinel-pair 1\nprimary #{image_id}\ncompanion #{own}\n#{contracts}")[0, 16]
      # the control of tests/app/build.sh: the companion publishes another pair id
      @child.pair_id = @mutate[:pair_id] || @pair_id
      @log << "[4] pair: primary #{image_id}, companion #{own}, pair #{@pair_id}"
      @log << "[4] pair: control: the companion publishes #{@child.pair_id}" if @mutate[:pair_id]
    end

    # The glue's pair words: the role, and each id as two 32-bit words.
    def pair_glue
      return nil unless pair? || companion?

      own = companion? ? image_id : nil
      words = ->(hex) { [hex[0, 8].to_i(16), hex[8, 8].to_i(16)] }
      ph, pl = words.(@pair_id)
      oh, ol = own ? words.(own) : [0, 0]
      table = pair_table.merge(pair_clocks)
      { role: companion? ? :companion : :primary, pair_id: @pair_id, pair_hi: format("0x%08x", ph), pair_lo: format("0x%08x", pl),
        own_hi: format("0x%08x", oh), own_lo: format("0x%08x", ol), console: @app.channels.any?(&:uart),
        channel_names: checked_channels, doorbell: consumer_doorbell, **table }
    end

    # The glue's doorbell (decision 0028), on the image whose entries a
    # doorbell wakes: the MU side's label, and each woken channel's
    # descriptor index, interrupt and entries (their index in the entry
    # table); nil on an image no doorbell wakes.
    def consumer_doorbell
      names = @app.triggers.filter_map(&:wake).uniq
      return nil if names.empty?

      chans = names.map do |n|
        c = @app.channels.find { |x| x.name == n }
        { name: n, index: c.ring[0], gi: @doorbells.fetch(n)[:gi],
          entries: @app.scheduled.each_index.select { |i| @app.scheduled[i][1].wake == n } }
      end
      b = @doorbells.fetch(names.first)
      { label: b[:label], mu: b[:mu], channels: chans, unenabled: @mutate[:doorbell_unenabled] ? true : false }
    end

    # Step 2 of the image a doorbell wakes: Zephyr's MU driver, and the MUs
    # the board leaves free disabled (Q1), so that the driver connects the
    # doorbell's MU alone. [overlay, Kconfig] or nil.
    def doorbell_config
      return nil unless (pair? || companion?) && @app.triggers.any?(&:wake)

      free = @doorbells.values.first[:free]
      ["/* decision 0028: the doorbell's MU through Zephyr's driver; the free MUs disabled */\n" +
         free.map { |l| "&#{l} {\n\tstatus = \"disabled\";\n};\n" }.join,
       "# decision 0028: the doorbell's MU, through Zephyr's driver (CONFIG_MBOX_NXP_IMX_MU follows the devicetree)\nCONFIG_MBOX=y\n"]
    end

    # The contract channels this image checks at boot. 0027's control 5
    # (--mutate-consumer-stopped CHANNEL) leaves the consumer's check out, so
    # that end never becomes ready and never takes.
    def checked_channels
      stopped = @mutate[:consumer_stopped]
      @app.channels.select(&:contract).reject { |c| c.name == stopped && c.direction == "in" }.map(&:name)
    end

    # 0027's control 6 (--mutate-channel-cacheable CORE): on that core the
    # region is mapped cacheable by the devicetree, as Zephyr's ARM MPU driver
    # programs a `zephyr,memory-attr` node after the board's own regions. The
    # M7's OCRAM2 region is its board's static table's, so a node over the
    # 128 KB is added and, numbered higher, decides it; the M33's is OCRAM2's
    # own node, whose attribute becomes cacheable RAM.
    def cacheable_overlay
      return nil unless (pair? || companion?) && @mutate[:channel_cacheable] == read_board_facts(2)["core"]&.first

      if companion?
        "/* 0027 control 6: OCRAM2 cacheable on the M33 */\n#include <zephyr/dt-bindings/memory-attr/memory-attr-arm.h>\n" \
          "&ocram2 {\n\tzephyr,memory-attr = <DT_MEM_ARM(ATTR_MPU_RAM)>;\n};\n"
      else
        "/* 0027 control 6: the channel region cacheable on the M7 */\n#include <zephyr/dt-bindings/memory-attr/memory-attr-arm.h>\n" \
          "/ {\n\tspc_cacheable: memory@20500000 {\n\t\tcompatible = \"zephyr,memory-region\";\n\t\treg = <0x20500000 0x20000>;\n" \
          "\t\tzephyr,memory-region = \"SPC_CACHEABLE\";\n" \
          "\t\tzephyr,memory-attr = <DT_MEM_ARM(ATTR_MPU_RAM)>;\n\t};\n};\n"
      end
    end

    # The clocks of the wait (decision 0027, Stage 2's choices): the M7's
    # cycles per M33 cycle reduced (both CYCLES_PER_SECOND, from RC24M), the
    # same as 16.16 and its inverse as 0.32 for the get, and the channels the
    # companion consumes, each its descriptor index.
    def pair_clocks
      hz = ->(pl) { File.read(pl.config_path)[/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=(\d+)$/, 1].to_i }
      m7, m33 = companion? ? [@parent, self] : [self, @child]
      f7 = hz.(m7)
      f33 = hz.(m33)
      refuse(8, "the pair's CYCLES_PER_SECOND are not both known (M7 #{f7}, M33 #{f33})") unless f7.positive? && f33.positive?
      g = f7.gcd(f33)
      num = f7 / g
      den = f33 / g
      consumed = (companion? ? @app : @child.app).channels.select { |c| c.contract && c.direction == "in" }
      { num: num, den: den, k_prod: ((num << 16) + den / 2) / den, k_cons: (den << 32) / num, consumer_hz: f33,
        consumed: consumed.map { |c| { name: c.name, index: c.ring[0] } } }
    end

    attr_reader :config_path

    # The channel table of ring_abi.h's lines 12 and 16 + 6i, the same in
    # both images: each descriptor's eight words, and the layout's digest
    # over them.
    def pair_table
      l = @channel_layout || CoreChannel.layout([]).first
      chans = l.channels.each_with_index.map do |(k, off), i|
        words = [k.digest[0, 8].to_i(16), k.digest[8, 8].to_i(16),
                 CoreChannel::CORE_IDS[k.from] | (CoreChannel::CORE_IDS[k.to] << 8) | (1 << 16) | ((@doorbells&.dig(k.name, :notify) || 0) << 24),
                 k.depth, k.stride, k.msg_bytes, off, 0]
        { name: k.name, index: i, init_index: 0, words: words.map { |v| format("0x%08xu", v) } }
      end
      digest = Digest::SHA256.hexdigest(chans.map { |d| "#{d[:index]} #{d[:words].join(' ')}\n" }.join)
      { channels: chans, header_bytes: l.header_bytes, slots_end: l.slots_end,
        layout_hi: format("0x%08x", digest[0, 8].to_i(16)), layout_lo: format("0x%08x", digest[8, 8].to_i(16)) }
    end

    # The sysbuild image of the companion, for the primary's step 2.
    def pair_sysbuild
      "# generated by spinel-core-app build: the M33 companion of decision 0027\n" \
        "ExternalZephyrProject_Add(APPLICATION #{COMPANION_IMAGE} SOURCE_DIR #{@child.zapp} BOARD #{@child.target})\n"
    end

    # The companion's variables in the primary's west calls.
    def pair_args(link: false)
      return [] unless pair?

      args = ["-D#{COMPANION_IMAGE}_DTC_OVERLAY_FILE=#{File.join(@child.zapp, 'app.overlay')}"]
      args << "-D#{COMPANION_IMAGE}_SPC_OBJECTS=#{@child.link_objects.join(';')}" if link
      args
    end

    # Step 10, both images: no section in the channel region of
    # tools/app/ring/ring_abi.h, in this core's view; the pair words and the
    # channels of decision 0027 live there, written by no link.
    def pair_region_checks(fails)
      return unless pair? || companion?

      base = companion? ? 0x3050_0000 : 0x2050_0000
      top = base + 128 * 1024
      out, st = Open3.capture2(@tools[:readelf], "-S", "-W", @elf)
      return fails << "#{@tools[:readelf]} -S #{@elf} failed" unless st.success?

      out.each_line do |l|
        f = l.sub(/\A\s*\[\s*\d+\]\s*/, "").split
        next unless f.size >= 6 && f[2].match?(/\A\h{8}\z/) && f[4].match?(/\A\h+\z/)

        addr = f[2].to_i(16)
        size = f[4].to_i(16)
        next if size.zero? || addr.zero?
        next unless addr < top && addr + size > base

        fails << "section #{f[0]} (#{format('0x%08x', addr)}, #{size} bytes) lies in the channel region #{format('0x%08x', base)}..#{format('0x%08x', top)}"
      end
    end

    def pair_summary
      return {} unless pair?

      { "pair" => { "id" => @pair_id, "primary" => image_id, "companion" => { "app" => File.basename(@companion_path, ".rb"), "board" => @child.board,
                                                                            "id" => @child.image_id, "firmware" => "companion/" },
                   "channels" => (@channel_layout&.channels || []).map do |k, off|
                     { "name" => k.name, "contract" => k.path_shown, "sha256" => k.digest, "from" => k.from, "to" => k.to,
                       "depth" => k.depth, "msg_bytes" => k.msg_bytes, "stride" => k.stride, "offset" => off,
                       "notify" => @doorbells&.dig(k.name, :notify) || 0 }
                   end } }
    end
  end
end
