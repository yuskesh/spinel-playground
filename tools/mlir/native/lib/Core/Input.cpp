#include "spinel-mlir/Core/Input.h"

#include "spinel-mlir/Contract/Reader.h"
#include "spinel-mlir/Core/BufferSpelling.h"
#include "spinel-mlir/Core/Prelude.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/Signals.h"
#include <unistd.h>

#include <array>

using namespace llvm;

namespace spinel_mlir::core {
namespace {

/// The single-file input boundary, enforced by the LIBRARY rather than by a
/// caller. This slice compiles one file; a reader that opened anything else has
/// read something the caller never named, and no tool built on this should be
/// able to skip the check by not asking for a ledger.
///
/// Records are NUL-separated paths. Malformed means: empty, or not ending in a
/// NUL -- a trailing record without its terminator is a truncated write, and
/// reading it as a path would accept a prefix of one.
bool checkLedger(StringRef ledgerPath, StringRef source, StringRef face,
                 function_ref<void(StringRef)> diag) {
  auto say = [&](const Twine &m) {
    diag(("spinel: input ledger (" + face + "): " + m).str());
    return false;
  };
  auto buf = MemoryBuffer::getFile(ledgerPath);
  if (!buf) return say("the reader wrote no ledger");
  StringRef text = (*buf)->getBuffer();
  if (text.empty()) return say("the reader wrote an empty ledger");
  if (text.back() != '\0') return say("the ledger does not end in a NUL; it is truncated");

  SmallString<256> want;
  if (sys::fs::real_path(source, want))
    return say("cannot resolve the source path " + source);

  bool sawSource = false;
  size_t records = 0;
  while (!text.empty()) {
    size_t nul = text.find('\0');
    StringRef path = text.substr(0, nul);
    text = text.substr(nul + 1);
    if (path.empty()) return say("the ledger holds an empty record");
    ++records;
    if (path == want.str()) { sawSource = true; continue; }
    return say("the reader opened " + path +
               ", which is not the source it was given; this slice compiles one file");
  }
  if (records == 0) return say("the ledger holds no records");
  if (!sawSource)
    return say("the ledger does not name the source the reader was given, so it "
               "does not describe that run");
  return true;
}

} // namespace

std::string defaultContractReader(const char *argv0, void *anchor) {
  const auto exe = sys::fs::getMainExecutable(argv0, anchor);
  SmallString<256> dir(sys::path::parent_path(exe));
  while (!dir.empty()) {
    SmallString<256> candidate(dir);
    sys::path::append(candidate, "tools/contract/build/spinel-typedump");
    if (sys::fs::can_execute(candidate)) return std::string(candidate);
    const auto parent = sys::path::parent_path(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return {};
}

std::unique_ptr<contract::ContractModule>
loadContract(StringRef source, StringRef reader,
             function_ref<void(StringRef)> diag, StringRef inputsOut, unsigned integerBits,
             bool withPrelude, ArrayRef<std::string> keepMethods) {
  auto fail = [&](const Twine &m) -> std::unique_ptr<contract::ContractModule> {
    diag(m.str());
    return nullptr;
  };
  auto before = MemoryBuffer::getFile(source);
  if (!before) return fail("cannot read source " + source);
  // A copy, not the buffer: a memory-mapped buffer can reflect in-place changes
  // to the file, so comparing it against itself would always agree.
  const std::string snapshot = (*before)->getBuffer().str();

  SmallString<256> tmp;
  if (auto ec = sys::fs::createUniqueDirectory("spinel-core-input", tmp))
    return fail("cannot create temporary directory: " + ec.message());
  // Decision 0042 stage 4: the copy the reader reads instead, when the
  // source names an intrinsic and the caller asked for the prelude.
  std::string copyPath;
  bool copyBeside = false;
  auto cleanup = [&] {
    if (copyBeside) {
      sys::fs::remove(copyPath);
      sys::DontRemoveFileOnSignal(copyPath);
    }
    sys::fs::remove_directories(tmp);
  };
  auto tempFile = [&](StringRef name) {
    SmallString<256> p(tmp); sys::path::append(p, name); return std::string(p);
  };
  // Decision 0045: Core::Buffer and Core::Table become the Array.new the
  // analysis reads, on the same lines (Core/BufferSpelling.h), before the
  // prelude is placed; the record goes on the module.
  BufferRewrite spelled = rewriteBufferSpellings(snapshot);
  PreludeCopy copy;
  if (withPrelude)
    copy = insertPrelude(spelled.text, preludeFor(spelled.text));
  if (copy.preludeLine == 0) copy.text = spelled.text;
  if (copy.preludeLine > 0 || spelled.changed) {
    // Beside the source only when a relative load needs that directory; a
    // dot name keeps it out of the driver's globs, and it is removed on
    // every exit, a signal included.
    int fd = -1;
    SmallString<256> path;
    if (snapshot.find("require_relative") != std::string::npos) {
      SmallString<256> dir(sys::path::parent_path(source));
      if (dir.empty()) dir = ".";
      SmallString<256> model(dir);
      sys::path::append(model, ".spinel-prelude.%%%%%%%%.rb");
      if (auto ec = sys::fs::createUniqueFile(model, fd, path)) {
        cleanup();
        return fail("cannot write the reader's copy of " + source +
                    " beside it: the directory " + dir + " is not writable (" +
                    ec.message() + "); the copy goes there because the source "
                    "uses require_relative");
      }
      copyBeside = true;
      sys::RemoveFileOnSignal(path);
    } else {
      SmallString<256> model(tmp);
      sys::path::append(model, sys::path::filename(source));
      if (auto ec = sys::fs::openFileForWrite(model, fd)) {
        cleanup();
        return fail("cannot write the reader's copy of " + source + ": " + ec.message());
      }
      path = model;
    }
    copyPath = std::string(path);
    {
      raw_fd_ostream os(fd, /*shouldClose=*/true);
      os << copy.text;
      os.close();
      if (os.has_error()) {
        os.clear_error();
        cleanup();
        return fail("cannot write the reader's copy of " + source);
      }
    }
  }
  // What the reader is handed: the copy when there is one, else the source.
  const StringRef readerInput = copyPath.empty() ? source : StringRef(copyPath);
  // Both are held still across the faces: the source against its snapshot,
  // and the copy, when there is one, against the text written to it. A
  // ledger names the file that was read, not the bytes it held, so a copy
  // changed under the reader would otherwise pass as the source's analysis.
  auto unchanged = [&]() -> bool {
    auto current = MemoryBuffer::getFile(source);
    if (!current || snapshot != (*current)->getBuffer()) {
      diag("source changed while obtaining analysis");
      return false;
    }
    if (copyPath.empty()) return true;
    auto read = MemoryBuffer::getFile(copyPath);
    if (!read || copy.text != (*read)->getBuffer()) {
      diag("the reader's copy of " + source.str() +
           " (the source and the intrinsics' prelude) changed while obtaining "
           "analysis");
      return false;
    }
    return true;
  };

  const std::array<StringRef, 4> modes = {"ast", "nodes", "locals", "methods"};
  std::string firstLedger;
  std::array<std::unique_ptr<MemoryBuffer>, 4> buffers;
  for (size_t i = 0; i < modes.size(); ++i) {
    const std::string out = tempFile(modes[i]), err = tempFile("stderr");
    // A ledger for EVERY face, always -- not only the first, and not only when
    // the caller wants a copy. These are four separate processes; that they read
    // the same files is the thing being checked, not an assumption the check may
    // rest on. `inputsOut` selects whether a copy is also written for the
    // caller; it does not decide whether the constraint applies.
    const std::string ledger = tempFile(("inputs." + modes[i]).str());
    const std::string ledgerArg = "--inputs-out=" + ledger;
    // The ledger flag goes BEFORE the mode: the mode has always been the last
    // argument, and a wrapper around the reader may key on that. Appending
    // after it broke an existing test that did.
    const std::string widthArg = "--int-width=" + std::to_string(integerBits);
    // The kept methods go before the mode too, one --keep-method=NAME each.
    std::vector<std::string> keepArgs;
    for (const std::string &k : keepMethods) keepArgs.push_back("--keep-method=" + k);
    std::vector<StringRef> args = {reader, readerInput, ledgerArg, widthArg};
    for (const std::string &k : keepArgs) args.push_back(k);
    args.push_back(modes[i]);
    const std::optional<StringRef> redirects[] = {StringRef(""), out, err};
    std::string detail;
    // NO TIME LIMIT, AND THAT IS THE POINT. The reader is bounded by the source
    // it reads, not by the clock: it runs once per face over the whole packed
    // CORE source, which only grows. A wall-clock limit therefore makes a busy
    // machine indistinguishable from a broken reader -- and it fails with
    // "reader failed", which reads as a defect in the tree. One pass over the
    // packed entries was measured at 17.4 s on Debian under light load, against
    // a limit of 30, so the margin was already thin; a loaded host closes it
    // with nothing wrong in the code.
    //
    // AND NOT A BIGGER NUMBER: a limit sized to today's source is a limit that
    // expires, so raising it is the same mistake with a later date on it.
    //
    // The five other ExecuteAndWait calls in this tree all wait indefinitely,
    // and spinel-fs-check/main.cpp writes /*SecondsToWait=*/0 explicitly. This
    // is that answer, in the one place that had drifted from it.
    const int rc =
        sys::ExecuteAndWait(reader, args, std::nullopt, redirects,
                            /*SecondsToWait=*/0, /*MemoryLimit=*/0, &detail);
    if (rc != 0) {
      // The copy's lines after the prelude are the source's, moved down.
      if (auto b = MemoryBuffer::getFile(err))
        diag(sourceColumns(sourceLines((*b)->getBuffer(), copyPath, copy), copyPath,
                           spelled.inserts));
      cleanup();
      return fail("reader failed for " + modes[i] + " (exit " + Twine(rc) + "): " + detail);
    }
    auto b = MemoryBuffer::getFile(out);
    if (!b || (*b)->getBuffer().empty()) { cleanup(); return fail("empty reader output: " + modes[i]); }
    buffers[i] = std::move(*b);
    // Checked here, for this face, before the next one runs. A ledger examined
    // only at the end could not say which face read what.
    if (!checkLedger(ledger, readerInput, modes[i], diag)) { cleanup(); return nullptr; }
    if (i == 0) firstLedger = ledger;
    if (!unchanged()) { cleanup(); return nullptr; }
  }
  if (!unchanged()) { cleanup(); return nullptr; }
  contract::ContractInputs inputs{buffers[0]->getBuffer(), buffers[1]->getBuffer(),
                                  buffers[2]->getBuffer(), buffers[3]->getBuffer()};
  inputs.preludeLine = copy.preludeLine;
  inputs.preludeLines = copy.preludeLines;
  inputs.preludeColumns = copy.firstColumns;
  inputs.columnInserts = spelled.inserts;
  auto module = contract::readContract(inputs, diag);
  if (!module) { cleanup(); return fail("invalid analysis contract"); }
  module->setBufferSpellings(std::move(spelled.spelled));
  if (!copyPath.empty()) {
    // The module describes the source, not the copy that was read.
    if (module->sourceFile() == copyPath) module->setSourceFile(source);
    module->renameSources([&](StringRef p) {
      return p == copyPath ? source.str() : p.str();
    });
    // The ledger the caller gets names the source: every face's named the
    // copy and nothing else, and the copy is the source's bytes, with the
    // prelude compiled into this tool and the buffer calls rewritten in place.
    SmallString<256> real;
    if (sys::fs::real_path(source, real)) {
      cleanup();
      return fail("cannot resolve the source path " + source);
    }
    std::error_code ec;
    raw_fd_ostream led(firstLedger, ec);
    if (ec) { cleanup(); return fail("cannot rewrite the input ledger: " + ec.message()); }
    led << real << '\0';
    led.close();
    if (led.has_error()) {
      led.clear_error();
      cleanup();
      return fail("cannot rewrite the input ledger");
    }
  }

  // The caller's copy is published LAST, once every face and the contract have
  // been accepted. Copying it after the first face left a new ledger behind --
  // replacing an existing one -- for a run that then failed on a later face or
  // on the contract, so the file on disk described a build that did not happen.
  //
  // Published through a file created in the destination's own directory and
  // renamed there: a copy straight onto the destination truncates it before a
  // complete replacement exists, and a rename across filesystems is a copy and
  // a delete.
  if (!inputsOut.empty()) {
    SmallString<256> dir(sys::path::parent_path(inputsOut));
    if (dir.empty()) dir = ".";
    SmallString<256> tmp;
    int fd = -1;
    if (auto e = sys::fs::createUniqueFile(dir + "/.spinel-inputs.%%%%%%", fd, tmp)) {
      cleanup();
      return fail("cannot create a temporary file beside " + inputsOut + ": " + e.message());
    }
    ::close(fd);
    if (auto e = sys::fs::copy_file(firstLedger, tmp)) {
      sys::fs::remove(tmp); cleanup();
      return fail("cannot stage the input ledger: " + e.message());
    }
    if (auto e = sys::fs::rename(tmp, inputsOut)) {
      sys::fs::remove(tmp); cleanup();
      return fail("cannot publish the input ledger " + inputsOut +
                  "; the existing file, if any, is unchanged: " + e.message());
    }
  }
  cleanup();
  return module;
}

} // namespace spinel_mlir::core
