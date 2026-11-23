# Decision 0014 Task 12: production primitives under preemption.
#
# Built exactly as production -- no recorder, no masks, no SPC_VERIFY. The
# concurrency is the real one, in both directions at once:
#
#   interrupt producer, thread consumer: `produce` runs the telemetry ring's
#   `put` in interrupt context while the transport thread drains the ring;
#
#   thread producer, interrupt consumer: the transport thread fills the
#   commands ring from UART input while `consume` runs its `get` in
#   interrupt context.
#
# CONTENT. Every message carries a sequence number and a checksum, so a torn
# copy or a slot published before it was filled is visible in the bytes:
# `tests/app/stress.sh` checks the telemetry frames off the wire, and
# `consume` checks the commands here -- the checksum, and that the sequence
# only rises (a stale slot re-read shows as a sequence that did not). The
# shared word carries its low half and the complement of the same half, so a
# half-written cross-context word is visible to `check`, which reads it from
# the thread context.
#
# THE SAMPLER is not here: it is the build's own source, `--stress`, a CMSDK
# timer whose period is not a multiple of the tick, so it samples the phases
# between ticks as well. A sampler called from an interrupt entry would see
# only tick boundaries, where the transport thread has not been scheduled yet
# -- measured, 20000 samples, every one of them the idle loop. `Stress.fail`
# is the harness's, and prints a content failure where the check sees it;
# `Stress.seen` counts what `consume` received, so a run whose consumer never
# got a message cannot pass for one whose checks all held.
require "spinel/core"
require "spinel/net"

state :seq, :u32, 1
state :frame, :u8, 16
state :shared, :u32, 2
state :command, :u8, 8
state :last, :u32, 1

channel :telemetry, :out, size: 16, depth: 4, uart: true
channel :commands, :in, size: 8, depth: 2, uart: true

module Stress
  core_extern :fail, params: {kind: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/stress.c"
  core_extern :seen, params: {seq: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/stress.c"
end

every_us 200, :produce, context: :interrupt
every_us 300, :consume, context: :interrupt
every_ms 1, :check

# interrupt context: a message whose bytes carry their own check, and a
# cross-context word whose halves carry theirs.
def produce(seq, frame, shared)
  s = seq[0] + 1
  seq[0] = s
  n = put_i32(frame, 0, s & 0x7fffffff)
  # (s * 2654435761) & 0x7fffffff at 32 bits: -1640531535 is 2654435761 - 2**32,
  # so the wrapping product has the same low 32 bits (decision 0022's
  # core_w32_mul; decision 0019, revised 2026-10-21, has no 64-bit body here)
  # and the frame the wire checker reads is unchanged.
  n = put_i32(frame, n, core_w32_mul(s, -1640531535) & 0x7fffffff)
  Telemetry.put(frame, n)
  shared[0] = s & 0xffff
  shared[1] = (s & 0xffff) ^ 0xffff
  0
end

# interrupt context: the commands ring's consumer. Kind 1 is a checksum that
# does not match, kind 3 a sequence that did not rise.
def consume(command, last)
  n = Commands.get(command)
  if n > 0
    got = command[0] + (command[1] * 256)
    want = (got * 7 + 11) & 0xffff
    have = command[2] + (command[3] * 256)
    if have != want
      Stress.fail(1)
    end
    if got <= last[0]
      Stress.fail(3)
    end
    last[0] = got
    Stress.seen(got)
  end
  0
end

# thread context: the cross word's reader. Kind 2 is a half-written word.
def check(shared)
  lo = shared[0]
  hi = shared[1]
  if (lo ^ 0xffff) != hi
    Stress.fail(2)
  end
  0
end
