# frozen_string_literal: true
#
# AN INDEPENDENT REFERENCE MODEL for the slot and link state, which is what
# decision 0007 asks for at this bullet and did not ask for at the last one.
#
# The reason it asks is worth stating. For the framebuffer kernels the original
# Full method IS an independent oracle: it computes pixels a different way from
# the extraction only in spelling, and any disagreement is a real one. Here the
# extraction is pointer surgery and so is the original, so a second spelling of
# the same surgery agreeing with the first would show that the transcription
# was faithful and nothing else. A transposition -- `th_prev[th_next[t]]` where
# `th_next[th_prev[t]]` was meant -- would be copied across and agree.
#
# SO THIS MODEL DOES NOT DO THE SURGERY. It keeps
#
#   * the live list as an ordered Ruby Array of slot ids,
#   * the free list as a Ruby Array used as a stack,
#   * `func` and `data` as Hashes,
#   * the bump allocator as one integer,
#
# and it DERIVES what `th_next`, `th_prev`, `th_func`, `th_data` and `state`
# must contain from those. Nothing in here assigns one link field from another.
# The predictions are then compared with the original's arrays and the
# extraction's, cell for cell.
#
# What it deliberately cannot represent, and what is checked instead:
#
#   * A list that is already corrupt -- a cycle in `th_next`, or a link
#     pointing outside the array. An Array has no cycles. These are the
#     status-ABI cases in trace.tsv, checked against decision 0007's numbers.
#   * Freeing one slot twice. The original permits it and so does the
#     extraction; both thread the slot to itself and then hand it out twice.
#     Here the second push is a second entry rather than an alias, so the two
#     part company at the third allocation after it. A caller's error in all
#     three, and out of the trace for that reason.

# The CRuby meaning of the CORE builtin. In CORE, `core_fail(:capacity)` ends
# the call with a status and writes no result; raising is that, in Ruby.
class CoreFail < StandardError
  attr_reader :category
  def initialize(category)
    @category = category
    super("core_fail(#{category.inspect})")
  end
end

TH_REMOVED = 0
TH_NULL = 10

# The thinker list: a circular doubly-linked live list through a sentinel at
# slot 0, and a free list of slots that were on it and are not any more.
class ThinkerModel
  def initialize(cap)
    @cap = cap
    @chain = []          # live slot ids, in list order
    @free = []           # a stack; the last entry is the head
    @alloc = 1           # slot 0 is the sentinel, so the bump starts at 1
    @func = {}
    @data = {}
    @link = {}           # what `th_prev` holds for a slot once it is freed
    # A slot that leaves the list KEEPS ITS OLD SUCCESSOR. Z_Free writes the
    # kind, the data and the free-list link, and never touches `th_next`, so
    # the field still points at whatever followed the slot when it was swept.
    # This model found that out by disagreeing with the original about it, so
    # it is recorded rather than assumed: the stale value is the next element
    # of the list AT THE MOMENT OF REMOVAL, which is an ordinary question to
    # ask an ordered Array and needs no link assigned from another.
    @stale_next = {}
  end

  # P_AddThinker: take the most recently freed slot if there is one, else the
  # next never-used one, and put it at the END of the live list.
  def add(func, data)
    if @free.empty?
      raise CoreFail, :capacity if @alloc >= @cap
      t = @alloc
      @alloc += 1
    else
      t = @free.pop
    end
    @func[t] = func
    @data[t] = data
    @stale_next.delete(t)     # linked again; both fields are written afresh
    @link.delete(t)
    @chain.push(t)
    t
  end

  # P_RemoveThinker: a mark, not an unlinking. The slot stays in the list.
  def remove(t)
    @func[t] = TH_REMOVED
  end

  # The sweep in P_RunThinkers: walk in list order, and whatever is marked
  # leaves the list and goes on the free stack, in the order it was met.
  def collect
    freed = @chain.select { |t| @func[t] == TH_REMOVED }
    freed.each do |t|
      @stale_next[t] = @chain[@chain.index(t) + 1] || 0
      @chain.delete(t)
      @func[t] = TH_NULL
      @data[t] = -1
      @link[t] = @free.empty? ? -1 : @free.last
      @free.push(t)
    end
    freed.length
  end

  # What the four arrays and the two scalars must hold, derived from the above.
  def arrays
    nxt = Array.new(@cap, 0)
    prv = Array.new(@cap, 0)
    fnc = Array.new(@cap, TH_NULL)
    dat = Array.new(@cap, -1)
    # The live list, including the sentinel at both ends.
    ring = [0] + @chain
    @stale_next.each { |t, v| nxt[t] = v }
    ring.each_with_index do |t, i|
      nxt[t] = ring[(i + 1) % ring.length]
      prv[t] = ring[i - 1]            # Ruby's -1 is the last element: the sentinel's predecessor
    end
    # The free list, threaded through `th_prev` because a free slot has no
    # other use for that field. Recorded when the slot was freed, so a slot
    # taken back off the list keeps the value until the link step rewrites it.
    @link.each { |t, v| prv[t] = v }
    @func.each { |t, v| fnc[t] = v }
    @data.each { |t, v| dat[t] = v }
    { func: fnc, data: dat, next: nxt, prev: prv,
      state: [@free.empty? ? -1 : @free.last, @alloc] }
  end
end

# The mobj slots: the same allocator with no list to link into, over the array
# a live mobj uses for its sector link.
class MobjModel
  def initialize(cap)
    @cap = cap
    @free = []
    @alloc = 0           # no sentinel here; slot 0 is an ordinary mobj
    # The same staleness the thinkers have, for the same reason: taking a slot
    # OFF the free list reads its link and does not clear it, so the cell still
    # holds whatever the free list's head was when the slot went on. Asked of
    # this model's own stack at the moment of freeing, not copied from the
    # original's assignment -- and, like the thinker one, found by disagreeing.
    @link = {}
  end

  def alloc
    if @free.empty?
      raise CoreFail, :capacity if @alloc >= @cap
      m = @alloc
      @alloc += 1
      m
    else
      @free.pop
    end
  end

  def free(m)
    @link[m] = @free.empty? ? -1 : @free.last
    @free.push(m)
  end

  def arrays
    nxt = Array.new(@cap, -1)
    @link.each { |t, v| nxt[t] = v }
    { thing_next: nxt, state: [@free.empty? ? -1 : @free.last, @alloc] }
  end
end
