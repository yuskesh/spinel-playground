# Reserve harness (non-deliverable)

A Zephyr application for `mps2/an521/cpu0` (and, for its `.su` files only,
`frdm_mcxn947/mcxn947/cpu0`) that does two things for decision 0014 §9 and
the plan's Task 9:

1. **Built with `CONFIG_STACK_USAGE=y`**, its build directory holds GCC's
   `.su` files for every Zephyr function in the configuration -- the frame
   sizes the reserve paths under `paths/` are summed from.
   `tests/app/reserves.sh` builds it for both boards under both fragments
   (`prod.conf`, `verify.conf`) and recomputes every row of
   `../reserves.tsv` from the paths, refusing a row whose bytes moved.
   `boards/mps2_an521_cpu0.overlay` adds the acceptance configuration's
   `adc-emul` node, so the an521 build carries `adc_emul.c`'s frames for
   `drv_adc_read` (FRDM's LPADC is on the board).
2. **Run under QEMU** on `mps2/an521`, it paints its stacks
   (`CONFIG_INIT_STACKS=y`, and its own repaint of the interrupt stack
   before the paths), drives the SysTick dispatch (a timer expiring over a
   spinning thread, then with the thread waiting on it) and the scheduler
   thread's kernel-call chain (a sleep, a timer start and stop, UART
   polling), and compares the high-water marks of its worker thread and of
   the interrupt stack with the reserves it was built against
   (`reserves.h`, generated from `reserves.tsv`). A mark above a reserve
   refutes the attestation and the harness prints `RESERVES_REFUTED`; a
   mark below prints `RESERVES_HELD` and confirms nothing beyond that run.
   The result is falsification evidence, never the reserve.

   **What the run does not drive, and so cannot refute:** the
   `isr_<driver>` rows (no UART input reaches QEMU's console, so the
   console interrupt never runs, and the FRDM rows run on no host); the
   `thread_switch` frame at the mark (on the worker's stack the kernel-call
   chain is deeper than the exception frame, so the mark never rests on the
   frame the row attests); `svc` (its only path ends the run); and any
   nesting -- a single SysTick over a thread is the deepest interrupt chain
   here, so the interrupt inequality's nested hardware frames are not
   exercised. The marks measured on Debian on 2026-09-23 decompose exactly:
   the worker's 168 = 40 (the harness's own two frames) + 128
   (`thread_kernel_calls`); the interrupt stack's 136 sits below the
   time-slice branch (144) that `timer_dispatch` attests; the
   `CONFIG_TIMESLICING=n` control in `reserves.sh` lowers it to 112, so the
   slice branch is one that raises the mark. The 112 stood 16 bytes above
   the k_timer branch as the note of that path file then enumerated it
   (96), and `settle/` below settled where those bytes go: the periodic
   timer's own re-arm, `z_add_timeout` 40, which that enumeration omitted.
   The harness budgets no nested entry, and needs none here: the settling
   probe shows this path takes none.

   **How the budgets map to 0014 §9.** The worker's budget is the thread
   inequality's attested terms -- `thread_switch` (the exception frame on
   the thread's stack), `thread_kernel_calls`, `uart_calls`, `guard_area`
   -- plus the harness's own frames in place of an entry's; `pendsv`, the
   context switch's cost on the interrupt stack, is in the interrupt
   budget with `isr_entry_exit`, `timer_dispatch` and the expiry function's
   frame. The `thread_switch` item therefore names the frame the switch
   pushes on the thread's stack, and `pendsv` the handler's own cost, which
   is how §9's "context switch" and "hardware exception frame" terms are
   split between the two stacks.

The fragments: `prod.conf` is the production configuration the application
build uses (the 64-bit cycle counter, GPIO, ADC, PWM where the board has
them); `verify.conf` adds the emulators the verification build enables. The
Zephyr paths the reserves sum are the same under both; the rows say which
symbols they depend on.

## `settle/`: the interrupt-stack settling probe

A second, smaller application beside the harness, run by hand and by no
suite. It exists because the harness's interrupt-stack marks (136 with
time slicing, 112 without) stood 16 bytes above the `timer_dispatch`
note's enumeration of the k_timer branch, and that gap had to be settled
before the milestone's claim rested on `.su` sums: either a nested entry's
hardware frame (which §9's inequality carries explicitly) or cost the
`.su` frames cannot see (which would make every row optimistic).

It drives the system timer's dispatch only, paints the interrupt stack
immediately before its window and reads the mark immediately after, and
has three modes: `-DSPC_FORCE_NESTING=0` excludes nesting (the scheduler
lock is held, so no PendSV can ever be pending), `=1` forces it (two
threads yield to each other while the timer expires), `=3` repeats the
excluded run with one measurement inside the expiry callback.

From the repository root, with the Zephyr environment `docs/building.md`
describes (the workspace's venv first on `PATH`). `-t run` does not return
by itself, so each run is bounded; the probe prints `SETTLE_END` when it is
done.

```sh
export ZEPHYR_BASE=$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr
export ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1
export PATH=$HOME/toolchains/zephyr-v4.4.2/.venv/bin:$PATH
H=tools/app/zephyr/v4.4.2/reserve-harness
for m in 0 1 3; do
  west build -p always -b mps2/an521/cpu0 "$H/settle" -d "/tmp/settle-$m" -- \
       -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" -DSPC_FORCE_NESTING=$m
  timeout 60 west build -d "/tmp/settle-$m" -t run | grep SETTLE
done
```

Measured on Debian, `mps2/an521` under QEMU, 2026-09-23:

```
SETTLE mode=excluded isr_used=112 expiries=20 ...
SETTLE mode=forced   isr_used=144 expiries=20 ...
SETTLE depth_at_callback=73        (mode 3, isr_used=112 again)
```

Forced minus excluded is 32, exactly one Cortex-M hardware exception frame,
so nesting is visible to the method and the excluded run has none of it.
The 112 is `sys_clock_isr` 16 + `sys_clock_announce_locked` 32 +
`z_timer_expiration_handler` 24 + `z_add_timeout` 40 -- the last being the
periodic timer re-arming itself, which runs on the ENTRY path, before the
callback (`kernel/timer.c:107` at the pin, against `expiry_fn` at `:125`);
SysTick has no `_isr_wrapper` frame under
`CONFIG_CORTEX_M_SYSTICK_INSTALL_ISR=y`. `depth_at_callback` 73 is what is
LIVE when the callback runs -- 72 below it plus one byte into the
instrumented callback's own 8-byte frame -- so it places the entry frames
and rules the re-arm out of the live set there; it does not say when the
re-arm ran.

So this mark is explained to the byte by frames the `.su` method can see,
and the 16 bytes were an incomplete enumeration in the path file's note,
which now names the re-arm. That settles this row; it establishes nothing
about rows with no QEMU run behind them (the list above). One figure comes
free: 144 − 112 − 32 = 0 is `z_arm_pendsv`'s own use of this stack, which
is what the `pendsv` row asserts as a literal and this suite cannot
recompute. Decision 0014 records the conclusion.
