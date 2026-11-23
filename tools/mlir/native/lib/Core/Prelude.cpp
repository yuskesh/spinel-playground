#include "spinel-mlir/Core/Prelude.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringExtras.h"

#include <set>
#include <vector>

namespace spinel_mlir::core {
namespace {

#include "spinel-mlir/Core/HostedPrelude.inc"

struct Definition {
  llvm::StringRef name;
  llvm::StringRef text; ///< from `def` to its `end` line, with the newline
};

/// The prelude's top-level definitions, in order. A definition starts at a
/// line `def NAME(` and ends at the first line that is exactly `end`; the
/// file is written that way (one level of `def`, no `end` at column 0
/// inside a body).
std::vector<Definition> definitions() {
  std::vector<Definition> out;
  llvm::StringRef rest = kHostedPrelude;
  while (!rest.empty()) {
    size_t at = 0;
    if (!rest.starts_with("def ")) {
      at = rest.find("\ndef ");
      if (at == llvm::StringRef::npos) break;
      ++at; // past the newline, to the `def`
    }
    llvm::StringRef body = rest.substr(at);
    size_t end = body.find("\nend\n");
    if (end == llvm::StringRef::npos) break;
    Definition d;
    d.text = body.substr(0, end + 5);
    llvm::StringRef header = d.text.substr(4);
    d.name = header.take_while([](char c) { return llvm::isAlnum(c) || c == '_'; });
    if (!d.name.empty()) out.push_back(d);
    rest = body.substr(end + 5);
  }
  return out;
}

bool wordChar(char c) { return llvm::isAlnum(c) || c == '_'; }

/// Whether `text` spells `name` as a whole word: not inside a longer
/// identifier, and not a different method that adds `?` or `!`.
bool spells(llvm::StringRef text, llvm::StringRef name) {
  if (name.empty()) return false;
  for (size_t at = text.find(name); at != llvm::StringRef::npos;
       at = text.find(name, at + 1)) {
    const size_t after = at + name.size();
    const bool before = at > 0 && wordChar(text[at - 1]);
    const bool next = after < text.size() &&
                      (wordChar(text[after]) || text[after] == '?' || text[after] == '!');
    if (!before && !next) return true;
  }
  return false;
}

} // namespace

llvm::StringRef hostedPrelude() { return kHostedPrelude; }

std::string preludeFor(llvm::StringRef source) {
  const std::vector<Definition> defs = definitions();
  std::set<llvm::StringRef> picked;
  std::vector<llvm::StringRef> pending;
  for (const Definition &d : defs)
    if (spells(source, d.name) && picked.insert(d.name).second) pending.push_back(d.name);
  // A picked definition brings every other name it spells, to the closure.
  while (!pending.empty()) {
    llvm::StringRef name = pending.back();
    pending.pop_back();
    for (const Definition &from : defs)
      if (from.name == name)
        for (const Definition &d : defs)
          if (d.name != name && spells(from.text, d.name) && picked.insert(d.name).second)
            pending.push_back(d.name);
  }
  std::string out;
  for (const Definition &d : defs)
    if (picked.count(d.name)) {
      out += d.text;
      out += "\n";
    }
  return out;
}

PreludeCopy insertPrelude(llvm::StringRef source, llvm::StringRef prelude) {
  PreludeCopy copy;
  if (prelude.empty()) {
    copy.text = source.str();
    return copy;
  }
  // A byte order mark first, then the leading lines that are blank or
  // comments, whole.
  const size_t bom = source.starts_with("\xEF\xBB\xBF") ? 3 : 0;
  size_t head = bom;
  int64_t headLines = 0;
  while (head < source.size()) {
    size_t eol = source.find('\n', head);
    llvm::StringRef line =
        source.slice(head, eol == llvm::StringRef::npos ? source.size() : eol);
    llvm::StringRef body = line.ltrim(" \t").rtrim("\r");
    if (!body.empty() && !body.starts_with("#")) break;
    ++headLines;
    head = eol == llvm::StringRef::npos ? source.size() : eol + 1;
  }
  copy.text = source.substr(0, head).str();
  if (head > bom && copy.text.back() != '\n') copy.text += '\n';
  if (bom && headLines == 0) copy.firstColumns = static_cast<int64_t>(bom);
  std::string part = prelude.str();
  if (part.back() != '\n') part += '\n';
  copy.preludeLine = headLines + 1;
  copy.preludeLines = static_cast<int64_t>(llvm::count(part, '\n'));
  copy.text += part;
  copy.text += source.substr(head).str();
  return copy;
}

std::string sourceLines(llvm::StringRef text, llvm::StringRef copyPath,
                        const PreludeCopy &copy) {
  if (copy.preludeLines == 0 || copyPath.empty()) return text.str();
  const int64_t last = copy.preludeLine + copy.preludeLines - 1;
  const std::string key = (copyPath + ":").str();
  std::string out;
  size_t at = 0;
  while (true) {
    size_t hit = text.find(key, at);
    if (hit == llvm::StringRef::npos) break;
    size_t digits = hit + key.size(), end = digits;
    while (end < text.size() && llvm::isDigit(text[end])) ++end;
    out += text.slice(at, digits).str();
    int64_t line = 0;
    if (end > digits && !text.slice(digits, end).getAsInteger(10, line) && line > last) {
      out += std::to_string(line - copy.preludeLines);
      // The program's first line on line 1 counts the byte order mark too.
      size_t cdigits = end + 1, cend = cdigits;
      while (cend < text.size() && llvm::isDigit(text[cend])) ++cend;
      int64_t col = 0;
      if (line == last + 1 && copy.firstColumns > 0 && end < text.size() &&
          text[end] == ':' && cend > cdigits &&
          !text.slice(cdigits, cend).getAsInteger(10, col)) {
        out += ":" + std::to_string(col + copy.firstColumns);
        end = cend;
      }
    } else {
      out += text.slice(digits, end).str();
    }
    at = end;
  }
  out += text.substr(at).str();
  return out;
}

} // namespace spinel_mlir::core
