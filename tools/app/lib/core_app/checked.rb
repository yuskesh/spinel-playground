# frozen_string_literal: true
#
# tools/app/lib/core_app/checked.rb -- the checked-domain discipline for the
# host runner (decision 0014 §10).
#
# `Checked` is the checked-operand mechanism of tests/core-boundary/oracle.rb,
# copied rather than moved: the plan lets the mechanism move into tools/app/lib
# only if oracle.rb and its six mutation controls stay unchanged and passing,
# and a copy keeps them untouched by construction. The arithmetic rules are
# 0007's, established by the arithmetic lane; the operators here are those of
# the oracle's class, one for one, and any divergence between the two would be
# a defect in this file, not a second reading of the decision.
#
# `Buffer` is what the runner binds an entry's `state` parameters to: element
# loads and stores checked against the index range (`BOUNDS`) and the element
# domain (`ARITHMETIC`, as a store of a value the element cannot hold is in
# CORE), reporting each access to the runner when the buffer is cross-context.
module CoreApp
  class Checked
    I64 = (-(2**63)..(2**63 - 1))

    class Failure < StandardError
      attr_reader :reason
      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    attr_reader :v

    def initialize(value)
      @v = value
    end

    def self.of(x)
      x.is_a?(Checked) ? x : Checked.new(x)
    end

    # The plain Integer behind a checked value, or the Integer itself.
    def self.plain(x)
      x.is_a?(Checked) ? x.v : x
    end

    def coerce(other)
      [Checked.new(other), self]
    end

    def fits(r)
      raise Failure, "overflow" unless I64.cover?(r)
      Checked.new(r)
    end
    private :fits

    def +(o) = fits(@v + Checked.of(o).v)
    def -(o) = fits(@v - Checked.of(o).v)
    def *(o) = fits(@v * Checked.of(o).v)
    def -@ = fits(-@v)
    def +@ = self
    def ~ = fits(~@v)
    def abs = fits(@v.abs)

    def /(o)
      d = Checked.of(o).v
      raise Failure, "div-zero" if d.zero?
      fits(@v / d)
    end

    def %(o)
      d = Checked.of(o).v
      raise Failure, "div-zero" if d.zero?
      fits(@v % d)
    end

    def <<(o)
      c = Checked.of(o).v
      raise Failure, "shift-range" unless (0..63).cover?(c)
      fits(@v << c)
    end

    def >>(o)
      c = Checked.of(o).v
      raise Failure, "shift-range" unless (0..63).cover?(c)
      fits(@v >> c)
    end

    def &(o) = fits(@v & Checked.of(o).v)
    def |(o) = fits(@v | Checked.of(o).v)
    def ^(o) = fits(@v ^ Checked.of(o).v)

    def <(o) = @v < Checked.of(o).v
    def <=(o) = @v <= Checked.of(o).v
    def >(o) = @v > Checked.of(o).v
    def >=(o) = @v >= Checked.of(o).v
    def ==(o) = @v == Checked.of(o).v
    def !=(o) = @v != Checked.of(o).v

    def to_s = @v.to_s
    def inspect = "Checked(#{@v})"
    def hash = @v.hash
    def eql?(o) = o.is_a?(Checked) && o.v == @v
  end

  # The statuses of 0007, by the reason a checked run gives.
  STATUS = { "OK" => 0, "ARGUMENT" => 1, "ARITHMETIC" => 2, "BOUNDS" => 3, "CAPACITY" => 4 }.freeze
  STATUS_OF_REASON = {
    "overflow" => 2, "div-zero" => 2, "shift-range" => 2, "domain" => 2,
    "argument" => 1, "bounds" => 3, "capacity" => 4,
  }.freeze

  # One `state` under the runner: `count` elements of `element`, zero at the
  # start (0014 §10: the initial state is all storage zero).
  class Buffer
    attr_reader :name, :element, :count, :cross, :index
    attr_accessor :observer

    def initialize(name, element, count, cross: false, index: 0)
      @name = name
      @element = element
      @count = count
      @cross = cross
      @index = index
      @cells = Array.new(count, 0)
      @observer = nil
    end

    def domain = DOMAIN.fetch(@element)

    def [](i)
      i = Checked.plain(i)
      raise Checked::Failure, "bounds" unless i.is_a?(Integer) && i >= 0 && i < @count
      v = @cells[i]
      @observer&.load(self, i, v) if @cross
      Checked.new(v)
    end

    def []=(i, v)
      i = Checked.plain(i)
      v = Checked.plain(v)
      raise Checked::Failure, "bounds" unless i.is_a?(Integer) && i >= 0 && i < @count
      raise Checked::Failure, "domain" unless v.is_a?(Integer) && domain.cover?(v)
      @cells[i] = v
      @observer&.store(self, i, v) if @cross
      v
    end

    # The bytes of the first `n` elements, for an extern's `in` argument and
    # for the channel simulator; no record is written (a buffer passed to an
    # extern is context-private, 0014 §5).
    def bytes(from, n) = @cells[from, n].dup
    def store_raw(i, v)
      @cells[i] = v
    end
    def cells = @cells.dup
    # decision 0041 stage 1's loops over a buffer, each element read checked
    def each
      @count.times { |i| yield self[i] }
      self
    end
    def each_with_index
      @count.times { |i| yield self[i], Checked.new(i) }
      self
    end
    def size = @count
    def length = @count
    def to_s = "#{@name}[#{@count}]"
  end
end
