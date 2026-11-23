# frozen_string_literal: true
#
# tools/app/lib/core_app/app_model.rb -- the value objects of an application.
#
# Decision 0014 §2. Everything here is read from the application's
# declarations by CoreApp::Declarations; nothing is derived. The derived facts
# (the write set, the call counts) come from the kernel's reports.
module CoreApp
  # The targets' width: each kernel call of this tool passes it
  # (`--int-width`), whatever the states' elements. It is the body's width
  # unless the application declares `# spinel: int64` and decision 0019's
  # table lists it (CoreApp.body_bits).
  TARGET_BITS = 32
  INT64_ALLOW = File.expand_path("../../../../tools/core/int64-allow.tsv", __dir__)

  # Decision 0019's table lists a source by its bytes. Whether `src` (the
  # application's own bytes) is listed in `table`: the row [path, reason], or
  # nil when it is not, or when the table is one the kernel would refuse
  # (a malformed row, a path listed twice, a listed file that is missing or
  # does not declare `# spinel: int64`).
  def self.declares_int64?(bytes) = bytes.split("\n", 2).first.to_s.chomp("\r") == "# spinel: int64"
  def self.int64_listing(src, table)
    return nil unless declares_int64?(src) && File.file?(table)
    root = File.expand_path("../..", File.dirname(table))
    seen = {}
    hit = nil
    File.binread(table).split("\n").each do |line|
      line = line.chomp("\r")
      next if line.empty? || line.start_with?("#")
      path, reason = line.split("\t", 2)
      return nil if path.to_s.empty? || reason.to_s.strip.empty? || reason.include?("\t") || seen[path]
      seen[path] = true
      file = File.join(root, path)
      return nil unless File.file?(file) && declares_int64?(bytes = File.binread(file))
      hit ||= [path, reason] if bytes == src
    end
    hit
  end

  # The body's width for the application at `path`, as the build has it:
  # TARGET_BITS, or 64 for a listed `# spinel: int64` source. An unlisted
  # declaration is refused here as the kernel refuses it
  # (int-width-int64-refused), so no model runs a body the build would not
  # make (decision 0041 stage 2, the review).
  class WidthRefused < StandardError; end
  def self.body_bits(path, table = INT64_ALLOW)
    src = File.binread(path)
    return TARGET_BITS unless declares_int64?(src)
    return 64 if int64_listing(src, table)
    raise WidthRefused, "#{path}:1: int-width-int64-refused: `# spinel: int64` declares a 64-bit body, " \
                        "the targets are #{TARGET_BITS}-bit, and #{table} does not list this source"
  end
  ELEMENTS = %w[u8 i32 u32 i64].freeze
  SCALARS = %w[i32 u32 i64].freeze
  CONTEXTS = %w[thread interrupt].freeze
  DOMAIN = {
    "u8" => (0..255),
    "i32" => (-(2**31)..(2**31 - 1)),
    "u32" => (0..(2**32 - 1)),
    "i64" => (-(2**63)..(2**63 - 1)),
  }.freeze

  # `placement` is nil for a state the glue allocates, or :session for one a
  # core_session places (decision 0021): `part` is "writable" or "resource",
  # `offset` its byte offset there, and `readonly` set for a resource.
  State = Struct.new(:name, :element, :count, :line, :placement, :part, :offset, :readonly, keyword_init: true)
  # `wake` names a contract channel whose doorbell releases the entry before
  # its period (decision 0028 Q4: `every_ms 10, :relay, wake: :console`), or
  # is nil; the period stays, as the time-out of a doorbell that never comes.
  Trigger = Struct.new(:entry, :period_us, :context, :line, :wake, keyword_init: true)
  # A channel carries `uart: true` or `udp: true` (decision 0014 §5). A
  # `udp:` message is one datagram in one Ethernet frame: 1500 bytes of MTU
  # less the IPv4 header (20) and the UDP header (8).
  UDP_PAYLOAD_MAX = 1472
  # `xcore` and `ring` are set by the build, not the source: a udp: channel on
  # a board whose table names a udp_consumer (decision 0024's amendment) has
  # its other end on the other core, through the OCRAM ring -- the consumer of
  # an :out channel, the producer of an :in one (decision 0025) -- and `ring`
  # is its [slot stride, slots' offset] there (Channels.ring_layout).
  # `contract` is a CoreChannel::Contract for a channel between a pair's two
  # cores (decision 0027 stage 2: `channel :name, contract: "FILE.channel"`):
  # its size and depth are the contract's, its direction is set by the build
  # from the board's core, and `ring` is then [descriptor index, slots'
  # offset] in the pair's region.
  # `doorbell` is set by the build for a contract channel whose consumer an
  # entry names with wake: (decision 0028): {notify:, mu:, gi:, gcr:, silent:}.
  Channel = Struct.new(:name, :direction, :size, :depth, :uart, :udp, :line, :xcore, :ring, :contract, :doorbell, keyword_init: true) do
    def module_name = name.to_s.split("_").map(&:capitalize).join
    # a channel the board's UART transport frames: neither a contract channel
    # nor one the other core sends
    def framed? = !contract
    # a udp: channel this core's own transport thread sends (an :in one is
    # received by the other core only, decision 0025)
    def local_udp? = udp && !xcore && direction == "out"
  end
  # One parameter of an extern: a scalar domain, or [:buf, element].
  ExternParam = Struct.new(:name, :kind, :type, keyword_init: true) do
    def buffer? = kind == :buffer
  end
  Extern = Struct.new(:module_name, :name, :params, :returns, :reads, :writes, :isr_ok,
                      :bound, :provider, :guards, :statics, :origin, :line, :end_line, keyword_init: true) do
    def symbol = "spc_#{origin}_#{module_name.downcase}_#{name}"
    def full = "#{module_name}.#{name}"
  end
  Entry = Struct.new(:name, :params, :line, keyword_init: true)
  # A reference `Module.member(...)` in a definition body, with the first
  # argument when it is an integer literal (the instance index of a board
  # member). Reachability is the kernel's; this is the file's text.
  MemberRef = Struct.new(:module_name, :name, :line, :first_literal, :definition, keyword_init: true) do
    def full = "#{module_name}.#{name}"
  end

  # One refusal of the tool, with its code, the file and line, and the detail.
  Diagnostic = Struct.new(:code, :file, :line, :detail, keyword_init: true) do
    def to_s = "#{file}:#{line}: #{code}: #{detail}"
  end

  class App
    # `definitions` are every top-level `def`; `entries` are the ones a trigger
    # names, in trigger order. The rest are helpers.
    # `requires` are [path, line] pairs: the packer blanks those lines.
    # `helpers` are [name, line, path] for each `require_relative` of a file
    # beside the application (decision 0027), packed after it.
    attr_reader :path, :states, :triggers, :channels, :externs, :definitions, :requires, :member_refs, :helpers
    # Decision 0021: the `core_session` path as written and its line, and the
    # entry parameters that name no declared state, which the session
    # resolves ([entry name, parameter]). `session_dtcm`: the writable
    # fields the declaration places in the data TCM where the board has one.
    attr_reader :session_path, :session_line, :session_params, :session_dtcm
    # Decision 0041 stage 2: the data stack of each context that declares
    # one, context name => bytes.
    attr_reader :scratches

    def initialize(path:, states:, triggers:, channels:, externs:, definitions:, requires:, helpers: [], member_refs: [],
                   session_path: nil, session_line: nil, session_params: [], session_dtcm: [], scratches: {})
      @scratches = scratches
      @session_path = session_path
      @session_dtcm = session_dtcm
      @session_line = session_line
      @session_params = session_params
      @member_refs = member_refs
      @path = path
      @states = states
      @triggers = triggers
      @channels = channels
      @externs = externs
      @definitions = definitions
      @requires = requires
      @helpers = helpers
    end

    def entries = triggers.map { |t| definition(t.entry) }
    def definition(name) = definitions.find { |e| e.name == name.to_s }

    def state(name) = states.find { |s| s.name == name.to_s }
    def entry(name) = trigger_of(name) && definition(name)
    def trigger_of(entry_name) = triggers.find { |t| t.entry == entry_name.to_s }
    def channel(name) = channels.find { |c| c.name == name.to_s }
    # The entries in declaration order, each with its trigger; an entry with
    # no trigger is not an entry of the application.
    def scheduled = triggers.map { |t| [entry(t.entry), t] }
    def context_of(entry_name) = trigger_of(entry_name)&.context
    def scratch_of(entry_name) = scratches[context_of(entry_name)]
  end
end
