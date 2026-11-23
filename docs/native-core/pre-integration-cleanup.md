# Historical commit metadata

The integration retains published history. Correcting the metadata below
would require a separately reviewed history rewrite; it is not part of the
native core integration.

## Commit trailers contrary to AGENTS.md

`AGENTS.md:50` states: "Do not add author signatures, `Co-Authored-By` trailers,
or session URLs to commits."

The commits listed below carry a `Co-Authored-By` trailer and a session URL,
contrary to that rule. No such metadata is added to new integration commits.

Affected, in this repository:

`17bc65c`, `d0159ab`, `bebbf3d`, `e0fe3df`, `0731b9e`, `9913c3a`, `07ba1c7`,
`0ff9497`, `bddd6f6`, `cd347fd`, `056303d`

and in `yuskesh/spinel`:

`cd5331fc`, `5f90226e`, `5bc45ec1`

Not affected: `fa933068` on `core/selected-root-seam`, and everything from that
commit onwards.

**Not fixed here, deliberately.** Every one of these is pushed, several are on
`main`, and one is the pin another branch depends on. Removing the trailers
means rewriting those commits and force-pushing, which would break the pin and
every reference to those SHAs in the decision records and reports. The cost of
the fix is larger than the defect.

What is done instead: no commit from `fa933068` onwards carries them, and this
note records the state so a reader of the history is not left to guess whether
the rule was known and ignored. A future metadata cleanup must account for those published references; the
current integration performs no history rewrite.
