# frozen_string_literal: true
#
# tools/app/lib/core_app/channel_sim.rb -- one channel under CRuby.
#
# The same rules as the generated C ring (channels.rb), on a Ruby array, with
# the failures of 0014 §5 raised as the checked runner's failures: `n < 1` is
# ARGUMENT, `n > size` and `n > len(data)` are BOUNDS -- the guards the kernel
# emits before the call -- and a `get` into a buffer shorter than `size` is
# refused at build time, which the simulator also refuses, loudly, if it is
# ever reached. Every operation reports to the recorder, when one is set.
require_relative "checked"

module CoreApp
  class ChannelSim
    class << self
      attr_accessor :recorder
      attr_reader :all
    end
    @all = []

    attr_reader :name, :direction, :size, :depth, :queue, :next_id, :drops

    def initialize(name, direction, size, depth)
      @name = name
      @direction = direction
      @size = size
      @depth = depth
      reset
      ChannelSim.all << self
    end

    def reset
      @queue = []
      @next_id = 1
      @drops = { "oversize" => 0, "channel_full" => 0 }
    end

    def occupancy = @queue.size

    # CORE's end of an :out channel.
    def put(data, n)
      n = Checked.plain(n)
      raise Checked::Failure, "argument" if n < 1
      raise Checked::Failure, "bounds" if n > @size
      raise Checked::Failure, "bounds" if n > data.count
      bytes = data.bytes(0, n)
      return record(:enq, nil, 1, bytes) if occupancy >= @depth  # full: unchanged
      id = @next_id
      @next_id += 1
      @queue << [id, bytes]
      record(:enq, id, 0, bytes)
      1
    end

    # CORE's end of an :in channel.
    def get(data)
      raise "channel #{@name}: get into a buffer of #{data.count} < size #{@size}; the build refuses this" if data.count < @size
      if @queue.empty?
        record(:deq, nil, 1, [])
        return 0
      end
      id, bytes = @queue.shift
      bytes.each_with_index { |b, i| data.store_raw(i, b) }
      record(:deq, id, 0, bytes)
      bytes.size
    end

    # The transport's end: inbound messages from the stimulus (an :in
    # channel), outbound drained to the UART (an :out channel).
    def transport_put(bytes, stimulus_id)
      if bytes.size > @size
        @drops["oversize"] += 1
        ChannelSim.recorder&.drop(self, stimulus_id, "oversize")
        return false
      end
      if occupancy >= @depth
        @drops["channel_full"] += 1
        ChannelSim.recorder&.drop(self, stimulus_id, "channel_full")
        return false
      end
      id = @next_id
      @next_id += 1
      @queue << [id, bytes]
      ChannelSim.recorder&.rx(self, stimulus_id, bytes, id)
      true
    end

    def transport_get
      return nil if @queue.empty?
      id, bytes = @queue.shift
      ChannelSim.recorder&.tx(self, id, bytes)
      [id, bytes]
    end

    private

    def record(op, id, result, bytes)
      ChannelSim.recorder&.channel(self, op, id, result, bytes)
      result == 0 ? (op == :enq ? 1 : bytes.size) : 0
    end
  end
end
