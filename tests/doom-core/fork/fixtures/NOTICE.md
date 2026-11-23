# Imported reproducers

These eleven programs and their expected outputs are copied verbatim from
the predecessor's spinel-fork, mirrored as branch
[`spinel-fork/c-emit-ir`](https://github.com/yuskesh/spinel/tree/spinel-fork/c-emit-ir) of `yuskesh/spinel`, at
`ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101`, where they live under `test/`.
Each was added by the bug-fix batch it belongs to, as the reproducer that
fails before that batch and passes after it. They are copied unchanged; the
byte digests in `../ledger.tsv` are the check.

They are not a build dependency of this repository, and nothing here reads the
predecessor checkout. They are fixtures: `tests/doom-core/fork-compat.sh`
compiles and runs them with the compiler this repository pins, to find out
which of the fork's defects the pin still has.

## Licence

The fork is a fork of Spinel, which carries:

    Copyright (c) 2024- Yukihiro Matsumoto (matz@ruby.or.jp)

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
    THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.

The full text is `LICENSE` at that revision.
