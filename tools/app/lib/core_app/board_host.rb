# frozen_string_literal: true
#
# tools/app/lib/core_app/board_host.rb -- what a board's host package
# registers with the runner.
#
# A `board_host.rb` (the synthetic one under tests/app/fixtures, or Task 7's
# generated one) defines the board modules with CRuby bodies and registers
# how a stimulus item reaches them:
#
#   CoreApp::BoardHost.stimulus(:adc) { |channel, millivolts| ... }
#   CoreApp::BoardHost.stimulus(:gpio) { |pin, level| ... }
#
# and how every simulator returns to its initial state before a run:
#
#   CoreApp::BoardHost.reset { ... }
#
# The Clock simulator reads the runner's virtual clock through `clock_us`;
# the runner installs the source before the run.
module CoreApp
  module BoardHost
    @handlers = {}
    @resets = []

    class << self
      attr_accessor :clock_source

      def clock_us = (@clock_source ? @clock_source.call : 0)

      # One handler per kind: a second registration would silently take the
      # first's items, so it is refused. A split module registers none.
      def stimulus(kind, &block)
        raise "a #{kind} stimulus handler is already registered; a stimulus item addresses one module" if @handlers.key?(kind.to_s)
        @handlers[kind.to_s] = block
      end

      def reset(&block)
        @resets << block
      end

      def apply(kind, a, b)
        h = @handlers[kind.to_s]
        raise "the board's host package registers no #{kind} stimulus handler" unless h
        h.call(a, b)
      end

      def reset_all
        @resets.each(&:call)
      end

      def clear
        @handlers.clear
        @resets.clear
        @clock_source = nil
      end
    end
  end
end
