# frozen_string_literal: true
#
# tools/app/lib/core_app/core_channel_sim.rb -- a contract channel between a
# pair's two cores (decision 0027 stage 2) under CRuby.
#
# The same rules as the generated C (templates/channel_core.c.erb) on a Ruby
# array: `put` takes the scalar fields as integers and the array fields as
# buffers, refuses (0) when `depth` messages are queued, and counts every
# call as attempted and accepted or refused; `get` copies the oldest message
# into the caller's buffers, a buffer per field, and answers 1, or 0 when
# nothing is queued. A scalar outside its field's domain is ARGUMENT, the
# guard the kernel emits before the call; a buffer shorter than its field is
# refused at build time, which the simulator also refuses, loudly, if it is
# ever reached. Each message is kept packed as the slot holds it
# (little-endian, the fields in order), and unpacked on the way out.
require_relative "checked"

module CoreApp
  class CoreChannelSim
    DOMAIN = { "u8" => 0..255, "u16" => 0..65_535, "u32" => 0..(2**32 - 1), "i8" => -128..127, "i16" => -32_768..32_767,
               "i32" => -(2**31)..(2**31 - 1) }.freeze
    PACK = { "u8" => "C", "u16" => "v", "u32" => "V", "i8" => "c", "i16" => "s<", "i32" => "l<" }.freeze

    class << self
      attr_reader :all
    end
    @all = []

    attr_reader :name, :direction, :depth, :fields, :queue, :attempted, :accepted, :refused, :taken

    # `fields` are [name, type, count or nil] in the contract's order
    def initialize(name, direction, depth, fields)
      @name = name
      @direction = direction
      @depth = depth
      @fields = fields
      @format = fields.map { |_, t, n| "#{PACK.fetch(t)}#{n || ''}" }.join
      reset
      CoreChannelSim.all << self
    end

    def reset
      @queue = []
      @attempted = @accepted = @refused = @taken = 0
    end

    def put(*args)
      @attempted += 1
      values = @fields.zip(args).flat_map do |(n, t, count), a|
        if count
          raise "channel #{@name}: #{n} is a buffer of #{a.count} < #{count}; the build refuses this" if a.count < count
          # a Checked::Buffer (the host runner) or a plain Array (the session
          # host), whose literal bytes arrive as one-character Strings
          a.respond_to?(:cells) ? a.bytes(0, count) : a[0, count].map { |x| x.is_a?(String) ? x.ord : Checked.plain(x) }
        else
          v = Checked.plain(a)
          raise Checked::Failure, "argument" unless DOMAIN.fetch(t).cover?(v)
          [v]
        end
      end
      if @queue.size >= @depth
        @refused += 1
        return 0
      end
      @queue << values.pack(@format)
      @accepted += 1
      1
    end

    def get(*bufs)
      @fields.zip(bufs).each do |(n, _, count), b|
        raise "channel #{@name}: #{n} is a buffer of #{b.count} < #{count || 1}; the build refuses this" if b.count < (count || 1)
      end
      return 0 if @queue.empty?
      values = @queue.shift.unpack(@format)
      @fields.zip(bufs).each do |(_, _, count), b|
        (count || 1).times { |i| b.respond_to?(:store_raw) ? b.store_raw(i, values.shift) : (b[i] = values.shift) }
      end
      @taken += 1
      1
    end
  end
end
