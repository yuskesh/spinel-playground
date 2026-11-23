#ifndef SPINEL_MLIR_SUPPORT_INT64_ALLOW_H
#define SPINEL_MLIR_SUPPORT_INT64_ALLOW_H

// Decision 0019, revised 2026-10-21: on a 32-bit target `# spinel: int64` is
// accepted only for a source listed in tools/core/int64-allow.tsv. A row is
// `path<TAB>reason`, the path relative to the repository the table is in.
// A source is listed when its bytes are a listed file's current bytes: the
// lanes compile copies, so the path a tool is given says nothing.

#include "spinel-mlir/Support/IntegerWidth.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"

#include <set>
#include <string>

namespace spinel_mlir {

struct Int64Allow {
  std::string table;  ///< the table read, for the diagnostic
  std::string error;  ///< non-empty: the table is wrong, and nothing is allowed
  bool listed = false;
};

/// The table `--int64-allow` names, or else tools/core/int64-allow.tsv in the
/// first ancestor of the running executable that has one.
inline std::string defaultInt64AllowTable() {
  std::string exe = llvm::sys::fs::getMainExecutable(nullptr, nullptr);
  llvm::SmallString<256> dir(exe);
  while (!dir.empty()) {
    llvm::sys::path::remove_filename(dir);
    llvm::SmallString<256> candidate(dir);
    llvm::sys::path::append(candidate, "tools", "core", "int64-allow.tsv");
    if (llvm::sys::fs::exists(candidate))
      return std::string(candidate);
    if (llvm::sys::path::parent_path(dir) == dir)
      break;
  }
  return "tools/core/int64-allow.tsv";
}

/// Whether `source` is listed. The whole table is checked on every read, so
/// a malformed row, a path that does not exist, a listed file that does not
/// declare `# spinel: int64`, or a path listed twice refuses every source.
inline Int64Allow int64Allowed(llvm::StringRef source, llvm::StringRef tablePath) {
  Int64Allow r;
  r.table = tablePath.empty() ? defaultInt64AllowTable() : tablePath.str();
  auto buf = llvm::MemoryBuffer::getFile(r.table);
  if (!buf) {
    r.error = r.table + ": cannot read the table: " + buf.getError().message();
    return r;
  }
  // tools/core/int64-allow.tsv -> the repository root
  llvm::SmallString<256> root(r.table);
  for (int k = 0; k < 3; ++k)
    llvm::sys::path::remove_filename(root);
  std::set<std::string> seen;
  llvm::StringRef rest = (*buf)->getBuffer();
  unsigned lineNo = 0;
  while (!rest.empty()) {
    auto [line, tail] = rest.split('\n');
    rest = tail;
    ++lineNo;
    line = line.rtrim("\r");
    if (line.empty() || line.starts_with("#"))
      continue;
    const std::string at = r.table + ":" + std::to_string(lineNo) + ": ";
    auto [path, reason] = line.split('\t');
    if (path.empty() || reason.trim().empty() || reason.contains('\t')) {
      r.error = at + "a row is a path and a reason, separated by one tab";
      return r;
    }
    if (!seen.insert(path.str()).second) {
      r.error = at + path.str() + " is listed twice";
      return r;
    }
    llvm::SmallString<256> file(root);
    llvm::sys::path::append(file, path);
    auto listed = llvm::MemoryBuffer::getFile(file);
    if (!listed) {
      r.error = at + path.str() + " does not exist";
      return r;
    }
    if (!declaresInt64((*listed)->getBuffer())) {
      r.error = at + path.str() + " does not start with `# spinel: int64`";
      return r;
    }
    if ((*listed)->getBuffer() == source)
      r.listed = true;
  }
  return r;
}

} // namespace spinel_mlir
#endif
