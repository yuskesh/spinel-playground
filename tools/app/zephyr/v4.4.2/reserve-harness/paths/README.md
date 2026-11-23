# Reserve paths

One file per board and reserve item, `paths/<board>/<item>.tsv`, three
columns: `function`, `source`, `note`. The reserve is the sum of the
frames along the path, and `tests/app/reserves.sh` recomputes it from a
fresh `CONFIG_STACK_USAGE=y` build of the harness (GCC `.su` files) and
refuses a `reserves.tsv` row whose bytes differ.

- `source` is `su` when the frame comes from the function's `.su` entry of
  the pinned build (the function's name must be found there, once), or
  `su:<file>` when the name is defined in more than one file (a weak
  default beside a driver's own) and the path names which;
  `asm:<bytes>` when the function is assembly with no `.su` entry, the bytes
  read from its pushes at the pinned commit, with the note naming the file
  and lines; `hw:<bytes>` for the hardware exception frame the core pushes
  (32 bytes without an FPU, plus up to 4 bytes of alignment).
- The path is the deepest chain of calls on the item's operation, traced by
  hand from the source at the pinned commit; each indirect call on it is
  resolved from this configuration's driver and device tables and the note
  says how. A branch that is not the deepest is not listed.
- The harness (`src/main.c`) drives each path with painted stacks and
  compares its high-water marks with the sums: a mark above a reserve
  refutes it. A mark below confirms nothing beyond that run.
