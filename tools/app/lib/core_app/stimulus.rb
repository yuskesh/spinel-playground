# frozen_string_literal: true
#
# tools/app/lib/core_app/stimulus.rb -- the stimulus script (the plan's
# "Stimulus script (TSV)").
#
#   horizon_us <H>            drain_us <D>
#   adc <t_us> <channel> <millivolts>
#   gpio <t_us> <pin> <0|1>
#   inbound <t_us> <channel> <hex payload>
#   cost <entry> <release|*> <us>
#   nest_timer <period_us> <busy_us>
#   expect_failure <entry> <release> <status>
#
# `cost` is the virtual execution time of one invocation, for the host runner
# only; it is simulation input, not an estimate of anything. Items are
# numbered in file order from 1: an inbound item's number is the stimulus_id
# the transport records. Every item's time is strictly before the horizon
# (0014 §10: the stimulus ends before H).
module CoreApp
  class Stimulus
    Item = Struct.new(:id, :kind, :time, :a, :b, :line, keyword_init: true)
    Failure = Struct.new(:entry, :release, :status, keyword_init: true)

    attr_reader :horizon, :drain, :items, :costs, :expected_failures, :path, :nest_timer

    def self.read(path)
      new(path, File.read(path))
    end

    def initialize(path, text)
      @path = path
      @horizon = nil
      @drain = nil
      @items = []
      @costs = Hash.new { |h, k| h[k] = {} }
      @expected_failures = []
      @nest_timer = nil # [period_us, busy_us]: the verification build's nesting source (Task 11); nothing on the host
      text.each_line.with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        f = ln.chomp.split(/[ \t]+/)
        where = "#{path}:#{i}"
        case f[0]
        when "horizon_us" then @horizon = int(f, 1, where)
        when "drain_us" then @drain = int(f, 1, where)
        when "adc", "gpio"
          raise "#{where}: #{f[0]} takes <t_us> <index> <value>" unless f.size == 4
          @items << Item.new(id: @items.size + 1, kind: f[0], time: int(f, 1, where), a: int(f, 2, where), b: int(f, 3, where), line: i)
        when "inbound"
          raise "#{where}: inbound takes <t_us> <channel> <hex payload>" unless f.size == 4
          raise "#{where}: the payload is an even number of hex digits" unless f[3].match?(/\A([0-9a-fA-F]{2})+\z/)
          @items << Item.new(id: @items.size + 1, kind: "inbound", time: int(f, 1, where), a: f[2], b: [f[3]].pack("H*").bytes, line: i)
        when "cost"
          raise "#{where}: cost takes <entry> <release|*> <us>" unless f.size == 4
          @costs[f[1]][f[2] == "*" ? "*" : int(f, 2, where)] = int(f, 3, where)
        when "nest_timer"
          raise "#{where}: nest_timer takes <period_us> <busy_us>" unless f.size == 3
          @nest_timer = [int(f, 1, where), int(f, 2, where)]
          raise "#{where}: the busy time must be below the period" unless @nest_timer[1] < @nest_timer[0]
        when "expect_failure"
          raise "#{where}: expect_failure takes <entry> <release> <status>" unless f.size == 4
          @expected_failures << Failure.new(entry: f[1], release: int(f, 2, where), status: int(f, 3, where))
        else
          raise "#{where}: unknown stimulus line #{f[0].inspect}"
        end
      end
      raise "#{path}: horizon_us is required" unless @horizon
      raise "#{path}: drain_us is required" unless @drain
      late = @items.select { |it| it.time >= @horizon }
      raise "#{path}:#{late.first.line}: a stimulus item at #{late.first.time} us is not strictly before the horizon #{@horizon}" unless late.empty?
    end

    def cost_of(entry, release)
      c = @costs[entry]
      c.fetch(release) { c.fetch("*", 0) }
    end

    private

    def int(f, i, where)
      raise "#{where}: field #{i + 1} is missing" unless f[i]
      Integer(f[i], 10)
    rescue ArgumentError
      raise "#{where}: #{f[i].inspect} is not an integer"
    end
  end
end
