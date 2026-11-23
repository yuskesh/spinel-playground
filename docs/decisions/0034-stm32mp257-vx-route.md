# 0034: The STM32MP257 NPU through TFLite and the VX delegate

- Date: 2026-11-10
- Status: Accepted by the owner on 2026-11-10.
- Scope: `--board stm32mp257f-dk` in `tools/npu/spinel-npu`, `tools/npu/stm32mp2/`,
  `tests/npu/stm32mp2/`. It adds a board to [decision 0032](0032-neutron-npu-route.md)
  and takes the model form of [decision 0033](0033-npu-def.md).

## Decision

The same Ruby program, with the same `npu_def` or `npu_extern` and the same
`Tensor` calls, builds for the STM32MP257F-DK as an aarch64 Linux executable. An
IREE dispatch calls C++ through `hal.import.static`. That code runs the model
with TFLite 2.18 and the VX delegate, which reach the GCNano NPU through TIM-VX
and ST's OpenVX libraries.

## Choices

- **Keep IREE in the path.** Calling TIM-VX directly would be a shorter route. It
  would also leave the `Tensor` surface and the shape that decision 0032 gave the
  program, so the IREE route was chosen.
- **The delegate is the compiler.** There is no converter step. The tool checks the
  declaration against the model at build time, and the program checks the graph
  when it starts.
- **The whole model or nothing.** The program stops if the delegate cannot be
  loaded, or if it does not take every operator as one partition. `partial:` is
  refused. A fallback to TFLite's CPU kernels would look the same to the program.
  This covers TFLite's kernels only: what runs inside the delegate is decided by
  the driver and ovxlib, and is not checked.
- **A dynamic link to the board's stack.** TFLite, the delegate, TIM-VX and OpenVX
  stay shared libraries on the board. ST's and Vivante's libraries are not tracked,
  and the delegate is opened by name at run time.
- **Hosted Linux runtime.** The Zephyr host layer is not used. Spinel's runtime is
  built for glibc as it is, with GC on.

## Acceptance

`ruby tests/npu/stm32mp2/run.rb` checks the refusals and the build. Given a capture
of `tests/npu/stm32mp2/board.sh`, it also checks that the capture belongs to the
program it built, the hand-computed outputs of `tests/npu/sides.rb` (`left 27 0`,
`right 0 27`, `dark 0 0`), and that an absent delegate and a stand-in delegate
taking no operator or only one all stop the program before any output.

## Which engine ran

In one run of `tests/npu/sides.rb`, the driver's own profile display named the NN engine as the target of the
convolution and of the fully connected layer on the board. It named the shader
for the int8 to uint8 conversions at the input and output, which the driver
inserts, and the tensor processor for a transpose. This comes from the driver's
report, not from an independent counter, and the suite does not check it.

## Limitations

- Only `tests/npu/sides.rb` has run. Which other models the delegate takes whole is
  decided on the board at start-up.
- The cross tools and sysroot are taken from an OpenSTLinux build and are not
  pinned by this repository. The tool checks only that they are present.
- Licences of the board's OpenVX libraries must be read again before anything is
  published, including the section above, which reports a closed driver's behaviour.
