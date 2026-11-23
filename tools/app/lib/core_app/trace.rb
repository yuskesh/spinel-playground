# frozen_string_literal: true
#
# tools/app/lib/core_app/trace.rb -- the trace as the host runner emits it.
#
# One record per event, with the kinds and fields of the plan's "Trace" table:
# a global sequence number, the context (0 the scheduler thread, 1 the
# transport thread, 2 the stimulus thread, 3 the system clock interrupt), the
# entry (its index in trigger order, or 255 for a non-entry actor), and the
# kind's fields by name. The byte encoding is trace_schema.tsv's (one row per
# field; the C recorder header is generated from the same file): `encode`
# writes a record as its bytes and `decode` reads a byte stream back,
# refusing an unknown kind, a short record, a body the fields do not consume
# exactly, and a record over a limit. The text form (`line`) is what the host
# fixtures compare; a decoded target record has the same fields as the host
# runner's, so the two text forms agree. OVERFLOW is a kind only the target's
# record buffers can produce; the host never emits it.
module CoreApp
  class Trace
    KINDS = %w[HEADER SELECT START END LOAD STORE XCALL XRET ENQ DEQ RX TX DROP STATUS FAIL CANCEL CUT PRIVATE OVERFLOW ENDMARK].freeze
    CONTEXT_THREAD = 0
    CONTEXT_TRANSPORT = 1
    CONTEXT_STIMULUS = 2
    CONTEXT_ISR = 3
    NO_ENTRY = 255
    ENQ_QUEUED = 0
    ENQ_FULL = 1
    DEQ_DEQUEUED = 0
    DEQ_EMPTY = 1
    DROP_OVERSIZE = 1
    DROP_CHANNEL_FULL = 2
    DROP_REASON = { "oversize" => DROP_OVERSIZE, "channel_full" => DROP_CHANNEL_FULL }.freeze

    SCHEMA_PATH = File.expand_path("trace_schema.tsv", __dir__)
    MAGIC = "SPTR"
    HEADER_LEN = 20
    TYPE_WIDTH = { "u8" => 1, "u16" => 2, "u32" => 4, "u64" => 8, "i32" => 4, "i64" => 8 }.freeze
    PACK = { "u8" => "C", "u16" => "v", "u32" => "V", "u64" => "Q<", "i32" => "l<", "i64" => "q<" }.freeze

    class DecodeError < StandardError; end

    Field = Struct.new(:name, :type, :length_field, keyword_init: true)
    Schema = Struct.new(:fields, :ids, :names, :codes, :limits, keyword_init: true) do
      def kind_of(id) = names[id]
      def id_of(kind) = ids.fetch(kind)
      def version = limits.fetch("schema_version")
    end

    # The schema file, read once: {kind => [Field]}, the id maps, the code
    # table {kind => {field => {name => value}}} and the limits.
    def self.schema
      @schema ||= begin
        fields = Hash.new { |h, k| h[k] = [] }
        ids = {}; names = {}; codes = Hash.new { |h, k| h[k] = Hash.new { |g, j| g[j] = {} } }; limits = {}
        File.foreach(SCHEMA_PATH).with_index(1) do |ln, i|
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t")
          case f[0]
          when "code" then codes[f[1]][f[2]][f[3]] = Integer(f[4])
          when "limit" then limits[f[1]] = Integer(f[2])
          else
            id = Integer(f[0])
            raise "#{SCHEMA_PATH}:#{i}: unknown type #{f[3]}" unless TYPE_WIDTH.key?(f[3]) || %w[bytes args].include?(f[3])
            raise "#{SCHEMA_PATH}:#{i}: a bytes field names its length field" if f[3] == "bytes" && f[4].to_s.empty?
            raise "#{SCHEMA_PATH}:#{i}: kind #{f[1]} is not one of the kinds" unless KINDS.include?(f[1])
            raise "#{SCHEMA_PATH}:#{i}: id #{id} is #{names[id]}, not #{f[1]}" if names.key?(id) && names[id] != f[1]
            ids[f[1]] = id; names[id] = f[1]
            fields[f[1]] << Field.new(name: f[2], type: f[3], length_field: f[4])
          end
        end
        missing = KINDS - fields.keys
        raise "#{SCHEMA_PATH}: no fields for #{missing.join(', ')}" unless missing.empty?
        Schema.new(fields: fields, ids: ids, names: names, codes: codes, limits: limits)
      end
    end

    # The text form of tagged XCALL arguments: scalars as decimal, buffers as
    # x<hex>, comma-separated; `tagged` is [[0, int] | [1, [bytes]]].
    def self.args_text(tagged)
      tagged.map { |t, v| t.zero? ? v.to_s : "x#{v.pack('C*').unpack1('H*')}" }.join(",")
    end

    def self.args_parse(text)
      return [] if text.to_s.empty?
      text.split(",").map { |a| a.start_with?("x") ? [1, [a[1..]].pack("H*").bytes] : [0, Integer(a)] }
    end

    # One record as its bytes.
    def self.encode(record, version: schema.version)
      sc = schema
      body = +"".b
      sc.fields.fetch(record.kind).each do |f|
        case f.type
        when "bytes"
          b = record.fields.fetch(f.name.to_sym)
          b = b.bytes if b.is_a?(String)
          body << [b.size].pack("V") << b.pack("C*")
        when "args"
          tagged = args_parse(record.fields.fetch(:args))
          body << [tagged.size].pack("C")
          tagged.each do |t, v|
            body << [t].pack("C")
            body << (t.zero? ? [v].pack("q<") : [v.size].pack("V") + v.pack("C*"))
          end
        else
          body << [record.fields.fetch(f.name.to_sym)].pack(PACK.fetch(f.type))
        end
      end
      [MAGIC, version, sc.id_of(record.kind), body.bytesize, record.seq, record.context, record.entry, 0].pack("a4vvVVCCv") + body
    end

    def to_bytes = @records.map { |r| Trace.encode(r) }.join

    # A text line (the `line` form) back to a record: the schema says which
    # fields are bytes (hex) and which are integers; `args` stays text.
    def self.from_text(line)
      seq, kind, context, entry, *fs = line.chomp.split("\t")
      raise DecodeError, "unknown kind #{kind.inspect} in #{line.inspect}" unless KINDS.include?(kind)
      byte_fields = schema.fields.fetch(kind).select { |f| f.type == "bytes" }.map(&:name)
      fields = fs.to_h do |kv|
        k, v = kv.split("=", 2)
        [k.to_sym, byte_fields.include?(k) ? [v].pack("H*").bytes : (k == "args" ? v : Integer(v))]
      end
      Record.new(seq: Integer(seq), kind: kind, context: Integer(context), entry: Integer(entry), fields: fields)
    end

    def self.from_text_file(path) = File.readlines(path).reject { |l| l.strip.empty? || l.start_with?("#") }.map { |l| from_text(l) }

    # A byte stream back to records. Refusals name the offset and the reason.
    def self.decode(bytes)
      sc = schema
      bytes = bytes.b
      out = []
      pos = 0
      while pos < bytes.bytesize
        raise DecodeError, "offset #{pos}: #{bytes.bytesize - pos} bytes remain, fewer than the #{HEADER_LEN}-byte header" if bytes.bytesize - pos < HEADER_LEN
        magic, version, kid, body_len, seq, context, entry, _pad = bytes[pos, HEADER_LEN].unpack("a4vvVVCCv")
        raise DecodeError, "offset #{pos}: magic #{magic.inspect}, not #{MAGIC}" unless magic == MAGIC
        raise DecodeError, "offset #{pos}: schema version #{version}, not #{sc.version}" unless version == sc.version
        kind = sc.kind_of(kid) or raise DecodeError, "offset #{pos}: unknown kind #{kid}"
        raise DecodeError, "offset #{pos}: body_len #{body_len} exceeds the limit #{sc.limits['body_len']}" if body_len > sc.limits.fetch("body_len")
        raise DecodeError, "offset #{pos}: #{kind} needs #{body_len} body bytes and #{bytes.bytesize - pos - HEADER_LEN} remain (truncated)" if bytes.bytesize - pos - HEADER_LEN < body_len
        body = bytes[pos + HEADER_LEN, body_len]
        fields = {}
        p = 0
        take = lambda do |n, what|
          raise DecodeError, "offset #{pos}: #{kind}: #{what} needs #{n} bytes at body offset #{p}, body_len is #{body_len}" if p + n > body_len
          v = body[p, n]; p += n; v
        end
        sc.fields.fetch(kind).each do |f|
          case f.type
          when "bytes"
            n = take.call(4, f.name).unpack1("V")
            fields[f.length_field.to_sym] = n
            fields[f.name.to_sym] = take.call(n, "#{f.name} (#{n} bytes)").bytes
          when "args"
            argc = take.call(1, "argc").unpack1("C")
            raise DecodeError, "offset #{pos}: #{kind}: #{argc} arguments exceed the limit #{sc.limits['args']}" if argc > sc.limits.fetch("args")
            tagged = Array.new(argc) do |k|
              t = take.call(1, "argument #{k} tag").unpack1("C")
              case t
              when 0 then [0, take.call(8, "argument #{k}").unpack1("q<")]
              when 1
                n = take.call(4, "argument #{k} length").unpack1("V")
                [1, take.call(n, "argument #{k} (#{n} bytes)").bytes]
              else raise DecodeError, "offset #{pos}: #{kind}: argument #{k} has tag #{t}, not 0 or 1"
              end
            end
            fields[:argc] = argc
            fields[:args] = args_text(tagged)
          else
            fields[f.name.to_sym] = take.call(TYPE_WIDTH.fetch(f.type), f.name).unpack1(PACK.fetch(f.type))
          end
        end
        raise DecodeError, "offset #{pos}: #{kind}: the fields consume #{p} bytes, body_len says #{body_len}" unless p == body_len
        out << Record.new(seq: seq, kind: kind, context: context, entry: entry, fields: fields)
        pos += HEADER_LEN + body_len
      end
      out
    end

    Record = Struct.new(:seq, :kind, :context, :entry, :fields, keyword_init: true) do
      def [](k) = fields.fetch(k.to_sym)
      def line
        fs = fields.map { |k, v| "#{k}=#{v.is_a?(Array) ? v.pack('C*').unpack1('H*') : v}" }
        [seq, kind, context, entry, *fs].join("\t")
      end
    end

    attr_reader :records

    def initialize
      @records = []
    end

    def emit(kind, context, entry, **fields)
      raise "unknown trace kind #{kind}" unless KINDS.include?(kind)
      r = Record.new(seq: @records.size, kind: kind, context: context, entry: entry, fields: fields)
      @records << r
      r
    end

    def last_seq = @records.size - 1
    def of(kind) = @records.select { |r| r.kind == kind }
    def to_text = @records.map(&:line).join("\n") + "\n"
  end
end
