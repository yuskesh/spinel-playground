# Conditional first binding

A local whose FIRST binding is inside a conditionally-evaluated expression,
read afterwards. On the path where the binding did not happen Ruby has still
DEFINED the local — the parser does that — and reads `nil`.

Mac review of 270fa5a reported this and it reproduced:

    def scint(buf, n_buf, flag)
      (flag != 0) && (t = buf[0]) > 0
      t
    end

    CRuby  flag=0 -> nil      flag=1 -> 5
    CORE   flag=0 -> OK, 0    flag=1 -> OK, 5

A wrong answer under a successful status and no diagnostic, which is the shape
nothing downstream has a reason to look at.

**The cause** was in `Eligibility.cpp`'s type derivation, not in the lowering.
`&&` and `||` derived BOTH sides into one environment, so a first binding made
in the right-hand side was recorded as if it always happened, and the later
read looked well-typed. Every local is seeded with zero at function entry to
keep the environment total for the merge blocks — a lowering necessity — and
with nothing refusing the read, that seed became the answer. The comment at the
seeding site already claimed "Ruby would see nil, which the subset rejects";
it did not.

`if`, `if`/`else` and `while` were already right: each forks the environment
and joins, so a name bound on one path only comes out conflicting. The short
circuit was the one conditional context not doing it. `bindif.rb`,
`bindelse.rb` and `bindwhile.rb` are here as the negative controls that were
ALREADY refused before the fix — they are what says the defect was specific to
the short circuit rather than general to conditional binding.
