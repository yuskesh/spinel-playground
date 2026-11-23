# macOS DOOM acceptance

Recorded on 2026-09-11 for implementation `4124dac`, with pinned Spinel
`cad0ad148af00b98a3de8a384c18a3cabe15bc1a`, Clang 23.1.1, macOS arm64 and
SDL2 2.32.10. The Mac validation reused an existing build of the pinned
compiler and runtime archive; it was not a clean compiler build.

## Real-window operation

The owner confirmed movement, turning, firing, door interaction and Escape
exit. The original key-event trace received modifier events rather than arrow
events; the cause was not established. At the owner's request, the SDL shim
added I/J/K/L movement mappings. After the Mac build and launch of `4124dac`,
the owner confirmed that these controls, including simultaneous I/J, worked.
This closes the requested playable-Mac check. No latency benchmark or diagnosis
of the original arrow-key translation is claimed.

## Automated evidence

- The Cocoa SDL scripted recording and headless replay matched all 350 frames,
  with exact keys 0..349, at `ee5208d`.
- The IJKL shim cases and compiled ticcmd checks passed on Mac at `4124dac`.
- The independent R007 reference output matched all 463,676 bytes of the
  preserved golden, including its SHA-256 column.
- Full DEMO1/2/3 reference comparisons covered 5026/3836/2134 game tics.
  Random calls, player rows and object rows matched. Applying the reviewed
  Mac allowances at `daebd13` returned exit 0 for every demo, with every
  declaration exercised and no other difference accepted.
- The compared frame counts after the documented initial exclusions were
  5024/3834/2132. DEMO1 has two declared differing tics, DEMO2 three, DEMO3 none.
  See [the baseline](frame-divergence-baseline.md) for exact values and limits.

Debian's additional reference differences remain unexplained and unaccepted.
The Mac result does not establish identical reference behavior across hosts.
The executable uses the hosted runtime and GC; no compiler or dependency pin
change is part of this import.
