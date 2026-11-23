//===- Prelude.h - the Extended hosted prelude (decision 0042) ----*- C++ -*-===//
//
// tools/core/hosted-prelude.rb, embedded at configure time: a Ruby
// definition of every CORE intrinsic (Core/Intrinsics.h), written so that
// the pinned Spinel compiles it. Two readers of a source get its definitions
// placed before the program in their copy, after the source's leading
// comment lines, so that every intrinsic is defined before any call to it
// runs (upstream 1782a9e13 gives a call that runs before a method's first
// definition a NoMethodError arm):
//
//   * the contract reader, on `--core` and freestanding, so that a call to an
//     intrinsic has a type. ContractInputs::preludeLine and preludeLines drop
//     the prelude's nodes again and move the source's back to their own
//     lines before anything reads the analysis;
//   * the hosted compiler, through tools/core/spinel-core-build, so that
//     hosted code may call the intrinsics too.
//
// A copy gets only the definitions of the names the source spells, and of
// the names those definitions spell in turn. A source that spells none gets
// no copy at all and is read as it always was.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_PRELUDE_H
#define SPINEL_MLIR_CORE_PRELUDE_H

#include "llvm/ADT/StringRef.h"

#include <string>

namespace spinel_mlir::core {

/// The whole prelude, byte for byte as tools/core/hosted-prelude.rb.
llvm::StringRef hostedPrelude();

/// The definitions a copy of `source` gets, each followed by a newline, in
/// the prelude's order; empty when the source spells no name the prelude
/// defines. A name counts when it appears as a whole word anywhere in the
/// text, comments included: an extra definition is never called, and a
/// missing one would leave a call without a type.
std::string preludeFor(llvm::StringRef source);

/// A copy of a source with a prelude part inserted: the source's leading
/// lines that are blank or comments (a magic comment such as
/// `# spinel: int64` among them) stay first, then the prelude, then the rest
/// of the source. `preludeLine` is the copy's line at which the prelude
/// starts and `preludeLines` its number of lines (ContractInputs::
/// preludeLine and preludeLines): a source line after the comments is
/// `preludeLines` further down in the copy. `prelude` empty gives the source
/// unchanged and 0 for both.
///
/// A UTF-8 byte order mark stays the copy's first three bytes. The parser
/// counts it in the columns of line 1, so when the program itself starts on
/// line 1 that line loses three columns in the copy: `firstColumns` is then
/// 3 (ContractInputs::preludeColumns), and 0 otherwise.
struct PreludeCopy {
  std::string text;
  int64_t preludeLine = 0;
  int64_t preludeLines = 0;
  int64_t firstColumns = 0;
};
PreludeCopy insertPrelude(llvm::StringRef source, llvm::StringRef prelude);

/// Text a reader printed about the copy at `copyPath`, with each
/// `copyPath:LINE` after the prelude moved back to the source's line, so a
/// diagnostic names the line the user wrote. Lines inside the prelude and
/// every other text are left as they are.
std::string sourceLines(llvm::StringRef text, llvm::StringRef copyPath,
                        const PreludeCopy &copy);

} // namespace spinel_mlir::core

#endif // SPINEL_MLIR_CORE_PRELUDE_H
