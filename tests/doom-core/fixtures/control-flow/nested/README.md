# A statement-position `if` with no else, inside another `if`

    def dc_entry(a)
      if a > 0
        if a > 1
          x = 7
        end
      else
        x = 9
      end
      x
    end

    CRuby  dc_entry(1) -> nil
    CORE   dc_entry(1) -> OK, 0

Reported by Mac review of 4a8ba23 with this exact source, and reproduced
verbatim. A wrong answer under a successful status and no diagnostic.

**The cause** was `Ty::NoReturn` standing for two different things. The inner
`if` has no `else` and sits in statement position, so `Eligibility.cpp`
answered `NoReturn` — but `NoReturn` means *control never leaves this arm*,
and the environment join reads it that way: an arm that reports `NoReturn` has
its bindings **discarded**, because a `return` really does contribute none. A
missing `else` contributes plenty. So the outer `if` threw away the
then-environment and typed `x` from the else arm alone, where it is bound.
`x` read as a well-typed integer.

`Ty::NilValue` says "no value" without also saying "does not fall through".
The environments join, `x` comes out conflicting, and the READ is refused.

`dc_nested_pre.rb` is the control: the same shape with `x = 3` ahead of it.
Both sides give 3, and it must keep compiling — that is what says the fix
refuses the nil path and not the shape.
