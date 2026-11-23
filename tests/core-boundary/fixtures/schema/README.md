# Schema fixtures for the version-1 CORE boundary contract

Written **before** the parser, so the first thing the parser does is fail these
for the stated reason rather than pass them by not looking.

`ok-*.contract` must be accepted. Everything else must be refused, and the
runner requires the diagnostic to name the defect — a refusal for the wrong
reason is a failure, because it would pass again once the real defect is fixed.

Each refusal fixture is **one edit away from `ok-minimal.contract`** unless its
name says otherwise. That is what makes it a control: if it were three edits
away, a parser could reject it for any of them.

`src/` holds the Ruby sources the contracts name. They are inputs to the
analysis, not tests: `conditional.rb`, `heredoc.rb`, `in_module.rb`,
`duplicate.rb` and `optional_param.rb` exist so the entry resolution has
something to refuse, `typedefs.rb` names its parameters after C typedefs, and
`requires_sibling.rb` loads `sibling.rb` so the single-file snapshot has
something to reject.
