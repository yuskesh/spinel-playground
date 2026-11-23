#include "spinel-mlir/Core/Input.h"
#include "spinel-mlir/Core/Eligibility.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <array>
#include <optional>
#include <string>

using namespace llvm;
using namespace spinel_mlir;

namespace {
int error(const Twine &s) { errs() << "spinel-core-check: " << s << "\n"; return 2; }
std::string cell(StringRef s) {
  // TSV cells cannot introduce another row or column, even in source paths.
  std::string out;
  const char hex[] = "0123456789ABCDEF";
  for (unsigned char c : s) {
    if (c <= 32 || c == '%' || c == 127) {
      if (c == ' ') { out += ' '; continue; }
      out += '%'; out += hex[c >> 4]; out += hex[c & 15];
    } else out += c;
  }
  return out;
}
std::string defaultReader(const char *argv0) {
  const auto exe = sys::fs::getMainExecutable(argv0, reinterpret_cast<void *>(&defaultReader));
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
struct Temp {
  SmallString<256> path;
  ~Temp() { if (!path.empty()) sys::fs::remove_directories(path); }
  std::string file(StringRef name) const {
    SmallString<256> p(path); sys::path::append(p, name); return std::string(p);
  }
};
}

int main(int argc, char **argv) {
  std::string source, method, reader, inputsOut;
  for (int i = 1; i < argc; ++i) {
    const StringRef arg(argv[i]);
    if (arg == "--help") {
      outs() << "usage: spinel-core-check SOURCE --method NAME [--typedump PATH]\n"
                "Source eligibility only; no object emission or exported ABI.\n";
      return 0;
    }
    if (arg == "--inputs-out") {
      if (i + 1 >= argc) return error("--inputs-out needs a path");
      inputsOut = argv[++i];
      continue;
    }
    if (arg == "--method" || arg == "--typedump") {
      if (i + 1 == argc) return error("missing value for " + arg);
      auto &dest = arg == "--method" ? method : reader;
      if (!dest.empty()) return error("duplicate option " + arg);
      dest = argv[++i];
    } else if (arg.starts_with("-") || !source.empty()) {
      return error("unexpected argument " + arg);
    } else source = arg.str();
  }
  if (source.empty() || method.empty()) return error("SOURCE and --method NAME are required");
  if (reader.empty()) reader = defaultReader(argv[0]);
  if (reader.empty()) return error("reader missing; build tools/contract or pass --typedump PATH");
  // The contract is obtained through the SHARED loader, which enforces the
  // single-file input boundary itself. This tool used to run the reader inline,
  // so the boundary lived only in the driver and a standalone run of the
  // checker accepted a program with dependencies -- measured: a `require` of an
  // empty file was CHECKED here. A second copy of a boundary is a second place
  // for it to not be applied.
  // Decision 0042 stage 4: the reader reads the source with the prelude's
  // definitions of the intrinsics it names, which `--core` admits.
  auto module = core::loadContract(source, reader,
                                   [](StringRef s) { errs() << s << "\n"; },
                                   inputsOut, 64, /*withPrelude=*/true, {method});
  // 2, as this tool has always answered for a contract it could not obtain:
  // a reader that failed, produced nothing usable, or read something it was not
  // given is not a verdict about the source.
  if (!module) return 2;
  const auto report = core::checkEligibility(*module, method);
  outs() << "#scope\tsource-eligibility\t#integer\tnon-null-host-int\n"
            "#verdict\tmethod\tlocation\treason\tpath\tdetail\n";
  for (const auto &d : report.diagnostics)
    outs() << cell(d.verdict) << '\t' << cell(d.method) << '\t' << cell(d.location)
           << '\t' << cell(d.reason) << '\t' << cell(d.path) << '\t' << cell(d.detail) << '\n';
  if (report.checked())
    for (const auto &name : report.methods)
      outs() << "CHECKED\t" << cell(name) << '\t' << cell(source)
             << "\tsupported-subset\t" << cell(method) << "\tsource constraints checked; no artifact claim\n";
  outs() << "#methods\t" << report.methods.size() << "\t#checked\t"
         << (report.checked() ? report.methods.size() : 0) << "\t#nodes\t" << report.nodes
         << "\t#diagnostics\t" << report.diagnostics.size() << '\n';
  return report.checked() ? 0 : 1;
}
