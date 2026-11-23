# frozen_string_literal: true
#
# tools/app/lib/core_app/core_channel.rb -- decision 0027 stage 2: the
# `.channel` contract file of a channel between the FRDM-IMXRT1186's two
# cores, which both applications of a pair name
# (`channel :console, contract: "channels/console.channel"`).
#
# The file, one item per line, single spaces; a line starting with `#` is a
# comment and a blank line is ignored:
#
#   core-channel 1                      the first line, exactly
#   channel <name>                      [a-z][a-z0-9_]*, at most 32 characters
#   from <core>                         cm7 | cm33
#   to <core>                           cm7 | cm33, not from
#   depth <n>                           a power of two, 1 .. 1024
#   field <name> <type> [count <n>]     one or more; u8 i8 u16 i16 u32 i32
#
# The message is the fields in the order written, each at its natural
# alignment, little-endian, with no padding the file does not name and no
# tail padding: msg_bytes is the end of the last field. A slot holds a length
# word, a stamp word and the message, rounded up to 32 bytes. The digest is
# sha256 over the file's bytes as read, so any edit moves the pair id.
#
# Refused, each with its code (the design's R1-R16): the version line, an
# unknown, repeated or misplaced keyword, a missing one, a core that is not
# the pair's, from equal to to, a depth that is not a power of two in range,
# i64/u64 (decision 0019's revision), floating point (owner, 2026-10-26),
# pointers and addresses, `offset` (stage 2 declares no region), any other
# type, a count below 1, unnamed padding, a bad or repeated field name, and a
# message larger than a slot can hold. The application's side (R6, R17-R19)
# is Declarations' and the build's; the pair's (R20-R25) is PairSteps'.
require "digest"
require_relative "app_model"

module CoreApp
  module CoreChannel
    VERSION_LINE = "core-channel 1"
    CORES = %w[cm7 cm33].freeze
    # the core numbers of the descriptor's flags (tools/app/ring/ring_abi.h)
    CORE_IDS = { "cm7" => 1, "cm33" => 2 }.freeze
    WIDTHS = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "u32" => 4, "i32" => 4 }.freeze
    INT64 = %w[i64 u64].freeze
    FLOATS = %w[f16 f32 f64 float double bf16].freeze
    POINTERS = %w[ptr pointer address addr usize isize uintptr intptr].freeze
    DEPTH_MAX = 1024
    CHANNELS_MAX = 64
    REGION_BYTES = 128 * 1024
    # header lines 0-15, then six lines per channel (ring_abi.h, version 5)
    FIRST_LINE = 16
    LINES_PER_CHANNEL = 6
    LINE_BYTES = 32
    # a contract is a file of this repository (AGENTS.md: no sibling checkout)
    REPO_ROOT = File.expand_path("../../../..", __dir__)
    SLOT_WORDS = 8 # len and stamp
    NAME = /\A[a-z][a-z0-9_]{0,31}\z/
    KEYWORDS = %w[auto break case char const continue default do double else enum extern float for goto if inline int long
                  register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while
                  alias and begin class def defined ensure false in module next nil not or redo rescue retry self super then
                  true undef unless until when yield].freeze
    ORDER = %w[channel from to depth].freeze

    # `array` is set when the file gives a count, even a count of 1
    Field = Struct.new(:name, :type, :count, :array, :offset, :line, keyword_init: true) do
      def width = WIDTHS.fetch(type)
      def bytes = width * count
    end
    Contract = Struct.new(:path, :name, :from, :to, :depth, :fields, :msg_bytes, :digest, keyword_init: true) do
      def stride = ((SLOT_WORDS + msg_bytes + LINE_BYTES - 1) / LINE_BYTES) * LINE_BYTES
      def ring_bytes = depth * stride
      def field(name) = fields.find { |f| f.name == name }
      def path_shown = path.start_with?("#{REPO_ROOT}/") ? path.delete_prefix("#{REPO_ROOT}/") : path
      def module_name = name.split("_").map(&:capitalize).join
    end
    # The region's layout for a pair's contracts: the descriptor index and the
    # slots' offset of each, in name order, the header's size and the end of
    # the last channel's slots.
    Layout = Struct.new(:channels, :header_bytes, :slots_end, keyword_init: true) do
      def index(name) = channels.index { |c, _| c.name == name }
      def offset(name) = channels.find { |c, _| c.name == name }&.last
    end

    module_function

    def header_bytes(n) = (FIRST_LINE + LINES_PER_CHANNEL * n) * LINE_BYTES

    # the largest message one channel's slot can hold: the region less a
    # one-channel header, less the slot's two words
    def msg_bytes_max = REGION_BYTES - header_bytes(1) - SLOT_WORDS

    # [Contract, []] or [nil, [Diagnostic...]]; `display` is the path the
    # diagnostics name.
    def parse(path, display: path)
      diags = []
      bytes = File.binread(path)
      bad = ->(line, code, detail) { diags << Diagnostic.new(code: code, file: display, line: line, detail: detail) }
      lines = bytes.force_encoding(Encoding::UTF_8).lines(chomp: true)
      items = lines.each_with_index.map { |l, i| [l, i + 1] }.reject { |l, _| l.start_with?("#") || l.strip.empty? }
      first, first_line = items.shift
      unless first == VERSION_LINE
        bad.(first_line || 1, "channel-version", "the first line must be #{VERSION_LINE.inspect}; found #{first.to_s.inspect}")
        return [nil, diags]
      end
      seen = {}
      fields = []
      items.each do |text, ln|
        words = text.split(" ", -1)
        key = words.first
        if key == "field"
          field(words, ln, fields, bad)
          next
        end
        unless ORDER.include?(key)
          bad.(ln, "channel-field", "unknown keyword #{key.inspect}")
          next
        end
        if seen.key?(key)
          bad.(ln, "channel-field", "#{key} appears twice")
          next
        end
        bad.(ln, "channel-field", "#{key} must come before the fields") unless fields.empty?
        unless words.size == 2
          bad.(ln, "channel-field", "#{key} takes one value: `#{key} <value>`")
          next
        end
        seen[key] = [words[1], ln]
      end
      ORDER.each { |k| bad.(items.last&.last || first_line, "channel-field", "the contract names no #{k}") unless seen.key?(k) }
      bad.(items.last&.last || first_line, "channel-field", "the contract names no field") if fields.empty? && diags.none? { |d| d.detail.start_with?("field ") }
      name, = seen["channel"]
      bad.(seen["channel"][1], "channel-name", "#{name} is not a channel name ([a-z][a-z0-9_]*, at most 32 characters)") if name && !name.match?(NAME)
      %w[from to].each do |k|
        c, ln = seen[k]
        bad.(ln, "channel-core", "#{c} is not a core of this board's pair (#{CORES.join(', ')})") if c && !CORES.include?(c)
      end
      if seen["from"] && seen["to"] && seen["from"][0] == seen["to"][0] && CORES.include?(seen["from"][0])
        bad.(seen["to"][1], "channel-core", "from and to are both #{seen['to'][0]}; a core-channel crosses between the two cores")
      end
      depth = nil
      if (d, ln = seen["depth"])
        depth = d.match?(/\A[1-9]\d*\z/) ? d.to_i : nil
        bad.(ln, "channel-depth", "depth #{d} is not a power of two in 1..#{DEPTH_MAX}") unless depth && depth <= DEPTH_MAX && (depth & (depth - 1)).zero?
      end
      at = layout_fields(fields, bad)
      bad.(fields.first.line, "channel-size", "the message is #{at} bytes; a slot holds at most #{msg_bytes_max}") if at && at > msg_bytes_max
      return [nil, diags] unless diags.empty?

      [Contract.new(path: path, name: name, from: seen["from"][0], to: seen["to"][0], depth: depth, fields: fields, msg_bytes: at,
                    digest: Digest::SHA256.hexdigest(bytes)), []]
    end

    # `field <name> <type> [count <n>]`: the type is read first, so each
    # refused type is named for its own reason and nothing else
    def field(words, ln, fields, bad)
      _, fname, type, *rest = words
      t = type.to_s
      return bad.(ln, "channel-type-int64", "field #{fname}: #{t} is refused on 32-bit targets (decision 0019's revision); use i32 or u32, or two u32 fields") if INT64.include?(t)
      return bad.(ln, "channel-type-float", "field #{fname}: #{t}: no floating point in a message (owner, 2026-10-26, decision 0027)") if FLOATS.include?(t)
      if POINTERS.include?(t) || t.end_with?("*")
        return bad.(ln, "channel-type-pointer", "field #{fname}: #{t}: a message holds no pointer or address; an address is an offset into a region the contract declares, and stage 2 declares none (decision 0027)")
      end
      return bad.(ln, "channel-type-offset", "field #{fname}: offset: in stage 2 the only region is the channel's own slots, and an offset into any other region is refused (decision 0027)") if t == "offset"
      return bad.(ln, "channel-type", "field #{fname}: #{t} is not a message type; the types are #{WIDTHS.keys.join(' ')}, with count for an array (byte strings are u8 arrays)") unless WIDTHS.key?(t)
      return bad.(ln, "channel-field-name", "#{fname.inspect} is not a field name") unless fname&.match?(NAME) && !KEYWORDS.include?(fname)
      return bad.(ln, "channel-field-name", "field #{fname} is named twice") if fields.any? { |f| f.name == fname }

      count = 1
      unless rest.empty?
        unless rest.size == 2 && rest[0] == "count"
          return bad.(ln, "channel-field", "field #{fname}: a field is `field <name> <type> [count <n>]`")
        end
        return bad.(ln, "channel-count", "field #{fname}: count is an integer of at least 1") unless rest[1].match?(/\A[1-9]\d*\z/)

        count = rest[1].to_i
      end
      fields << Field.new(name: fname, type: t, count: count, array: !rest.empty?, line: ln)
    end

    # each field at the end of the one before, which must be its natural
    # alignment; answers the message's size, or nil after a refusal
    def layout_fields(fields, bad)
      at = 0
      ok = true
      fields.each do |f|
        if (at % f.width).nonzero?
          pad = f.width - at % f.width
          bad.(f.line, "channel-padding", "field #{f.name} (#{f.type}) falls at offset #{at}, which is not #{f.width}-aligned; name the #{pad} padding byte(s) as a field before it")
          ok = false
        end
        f.offset = at
        at += f.bytes
      end
      ok ? at : nil
    end

    # The pair's region (R23, R24): the header, then each channel's slots in
    # name order, 32-byte aligned. [Layout, []] or [nil, [detail...]].
    def layout(contracts)
      return [nil, ["#{contracts.size} channels; the header describes at most #{CHANNELS_MAX}"]] if contracts.size > CHANNELS_MAX

      hb = header_bytes(contracts.size)
      at = hb
      placed = contracts.sort_by(&:name).map { |c| o = at; at += c.ring_bytes; [c, o] }
      if at > REGION_BYTES
        parts = placed.map { |c, _| "#{c.name} #{c.depth} x #{c.stride} = #{c.ring_bytes}" }.join(", ")
        return [nil, ["the channels need #{at} bytes (header #{hb}, #{parts}); the region is #{REGION_BYTES}"]]
      end
      [Layout.new(channels: placed, header_bytes: hb, slots_end: at), []]
    end
  end
end
