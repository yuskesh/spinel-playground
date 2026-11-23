# Source-packing fixtures

Each directory is one input to `tools/doom/pack-core.rb`, driven by
`tests/doom-core/source-pack.sh`. The manifests are built by the test from the
files on disk, so a fixture cannot drift from its digests without the test
noticing.

| fixture | what it is for |
| --- | --- |
| `ok` | the plan's own two units and direct helper: `dc_twice` and `dc_pick`, whose native result must be 7 |
| `order` | the same two units, packed in both manifest orders, to show the order is the manifest's |
| `core` | two units whose helper IS core-eligible at this pin, for the kernel-tool lane |
| `dup-method` | the same method defined in two units |
| `dup-const` | the same constant assigned in two units |
| `require` | a unit that loads a sibling instead of being listed |
| `toplevel` | a unit that runs something at the top level |
| `endmarker` | a unit with `__END__`, which would hide everything packed after it |
| `syntax` | a unit that does not parse |
| `encoding-decl` | a unit declaring a coding that is not UTF-8 |
| `encoding-bytes` | a unit holding bytes that are not UTF-8 |
| `unlisted` | two units under the root with only one in the manifest |

`ok` and `core` differ on purpose. The plan's example is `a * 2` and `+ 1`. The
eligibility checker refused both as unproved arithmetic until decision 0015
admitted checked `+ - * / %`; the test now builds `dc_pick` as a core object and
keeps the refusal on a copy written with `a ** 2`, which 0015 still leaves
unproved. `core` carries a comparison-only helper, which the kernel-tool lane
accepted before 0015 too.
