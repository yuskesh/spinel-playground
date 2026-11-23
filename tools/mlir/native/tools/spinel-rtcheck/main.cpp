// Native allocation-proof tool matches frozen rtcheck stdout/stderr/status and all four -o files
// byte for byte; preserve wording/order.
#include "spinel-mlir/Realtime/MayAllocate.h"
#include "spinel-mlir/Realtime/WholeModule.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>
#include <map>
#include <string>
#include <vector>

using namespace llvm;
namespace rt = spinel_mlir::realtime;

namespace {

const char *kProg = "spinel-rtcheck";

int die(const Twine &msg) {
  errs() << kProg << ": " << msg << "\n";
  return 2;
}

std::string envOr(const char *k, const std::string &fallback) {
  if (const char *v = std::getenv(k))
    return v;
  return fallback;
}

/// Doom::Game#g_ticker -> sp_Game_g_ticker.
std::string rubyName(StringRef m) {
  std::string out;
  for (char c : m) {
    if (c == '?') { out += "_p"; continue; }
    if (c == '!') { out += "_b"; continue; }
    if (c == '=') { out += "_set"; continue; }
    out += c;
  }
  return out;
}

std::string mangle(StringRef spec, const rt::ModuleModel &mod) {
  if (mod.funcs().count(spec.str()))
    return spec.str();
  auto lastComponent = [](StringRef s) {
    size_t i = s.rfind("::");
    return i == StringRef::npos ? s : s.substr(i + 2);
  };
  size_t h = spec.find('#');
  if (h != StringRef::npos)
    return ("sp_" + lastComponent(spec.substr(0, h)) + "_" +
            rubyName(spec.substr(h + 1))).str();
  size_t d = spec.find('.');
  if (d != StringRef::npos)
    return ("sp_" + lastComponent(spec.substr(0, d)) + "_" +
            rubyName(spec.substr(d + 1))).str();
  // Spinel Extended: the pinned compiler (vendor 6d69d010) emits a top-level
  // method whose plain name could collide with a runtime symbol as
  // `sp_rb_<name>` (`str_build` -> `sp_rb_str_build`). The predecessor's pin
  // did not, so the plain spelling is tried first and the prefixed one second.
  std::string plain = "sp_" + rubyName(spec);
  if (!mod.funcs().count(plain)) {
    std::string prefixed = "sp_rb_" + rubyName(spec);
    if (mod.funcs().count(prefixed))
      return prefixed;
  }
  return plain;
}

std::string fmtPath(const rt::ModuleModel &mod,
                    ArrayRef<rt::Analysis::Hop> path) {
  std::string out;
  for (size_t i = 0; i < path.size(); ++i) {
    if (i)
      out += "\n";
    std::string arrow;
    for (size_t k = 0; k < i; ++k)
      arrow += "  ";
    if (i == 0) {
      out += arrow + path[i].first;
    } else {
      std::string w = mod.where(path[i].second);
      out += arrow + "-> " + path[i].first;
      if (!w.empty())
        out += "   [called at " + w + "]";
    }
  }
  return out;
}

// Left-justify formats such as %-40s, matching Python.
std::string padRight(StringRef s, size_t n) {
  std::string out = s.str();
  while (out.size() < n)
    out += ' ';
  return out;
}

struct Row {
  std::string verdict, entry, cause, detail;
};

class ScopedTempDir {
public:
  ~ScopedTempDir() {
    if (!keep_ && !path_.empty())
      sys::fs::remove_directories(path_);
  }
  std::error_code create() {
    SmallString<128> model;
    sys::path::system_temp_directory(true, model);
    sys::path::append(model, "rtcheck.");
    return sys::fs::createUniqueDirectory(model, path_);
  }
  StringRef path() const { return path_; }
  void keep() { keep_ = true; }

private:
  SmallString<128> path_;
  bool keep_ = false;
};

} // namespace

int main(int argc, char **argv) {
  std::string input;
  std::vector<std::string> entrySpecs, linkBc;
  std::string entriesFile, outdir, intOverflow, clangPath;
  std::string indirect = "conservative";
  bool allRuby = false, allowAbort = false, keep = false, printRegion = false;
  int linkRt = 0; // 1: --link-runtime, 2: --link-runtime-mt (an .ll input)
  bool quiet = false, verbose = false;

  for (int i = 1; i < argc; ++i) {
    StringRef a = argv[i];
    auto val = [&](const char *what) -> std::string {
      if (i + 1 >= argc) {
        errs() << kProg << ": " << what << " needs an argument\n";
        std::exit(2);
      }
      return argv[++i];
    };
    if (a == "--entry") entrySpecs.push_back(val("--entry"));
    else if (a == "--entries") entriesFile = val("--entries");
    else if (a == "--all-ruby") allRuby = true;
    else if (a == "--allow-abort") allowAbort = true;
    else if (a == "--indirect") indirect = val("--indirect");
    else if (a == "--int-overflow") intOverflow = val("--int-overflow");
    else if (a == "--link-bc") linkBc.push_back(val("--link-bc"));
    else if (a == "-o" || a == "--outdir") outdir = val("--outdir");
    else if (a == "--keep") keep = true;
    else if (a == "--link-runtime") linkRt = 1;
    else if (a == "--link-runtime-mt") linkRt = 2;
    else if (a == "--print-region") printRegion = true;
    else if (a == "-q" || a == "--quiet") quiet = true;
    else if (a == "-v" || a == "--verbose") verbose = true;
    else if (a == "--clang") clangPath = val("--clang");
    else if (a.starts_with("-")) {
      errs() << kProg << ": unrecognized argument " << a << "\n";
      return 2;
    } else if (input.empty()) {
      input = a.str();
    } else {
      errs() << kProg << ": unrecognized argument " << a << "\n";
      return 2;
    }
  }
  if (input.empty())
    return die("an input (.rb, .ll or .bc) is required");

  std::vector<std::string> specs = entrySpecs;
  if (!entriesFile.empty()) {
    auto buf = MemoryBuffer::getFile(entriesFile);
    if (!buf)
      return die(entriesFile + ": " + buf.getError().message());
    SmallVector<StringRef, 32> lines;
    (*buf)->getBuffer().split(lines, '\n');
    for (StringRef l : lines) {
      StringRef s = l.split('#').first.trim();
      if (!s.empty())
        specs.push_back(s.str());
    }
  }
  if (specs.empty() && !allRuby)
    return die("no --entry given (nothing to prove)");

  ScopedTempDir work;
  if (std::error_code ec = work.create())
    return die("temp-dir-failed: " + ec.message());
  if (keep)
    work.keep();

  // Environment variable spellings match frozen Python.
  std::string llvmPrefix = envOr("LLVM_PREFIX", envOr("LLVM", "/opt/homebrew/opt/llvm"));
  SmallString<128> exe(sys::fs::getMainExecutable(argv[0], (void *)&main));
  std::string repo;
  {
    SmallString<128> dir(sys::path::parent_path(exe));
    while (!dir.empty()) {
      SmallString<128> c(dir);
      sys::path::append(c, "vendor", "spinel");
      if (sys::fs::exists(c)) {
        repo = std::string(dir);
        break;
      }
      StringRef parent = sys::path::parent_path(dir);
      if (parent == dir)
        break;
      dir = parent;
    }
  }
  rt::BuildOptions opts;
  opts.spinelDir = envOr("SPINEL_DIR", repo + "/vendor/spinel");
  opts.spinelBin = envOr("SPINEL_BIN", opts.spinelDir + "/bin/spinel");
  opts.llvmBin = llvmPrefix + "/bin";
  opts.bcDir = envOr("BC_DIR", repo + "/tools/llvm/build");
  opts.intOverflow = intOverflow;
  opts.linkBc = linkBc;
  opts.work = work.path().str();
  opts.verbose = verbose;

  LLVMContext ctx;
  std::string error;
  std::unique_ptr<Module> whole;
  if (StringRef(input).ends_with(".rb"))
    whole = rt::buildWholeModule(input, opts, ctx, error);
  else {
    whole = rt::parseInput(input, ctx, error);
    // A TU the caller compiled itself still needs the runtime it calls, as
    // the .rb path links it, or every runtime callee is an opaque external.
    if (whole && linkRt)
      whole = rt::linkRuntime(std::move(whole), linkRt == 2, opts, ctx, error);
  }
  if (!whole) {
    if (keep)
      errs() << kProg << ": intermediates in " << work.path() << "\n";
    return die(error);
  }

  rt::ModuleModel mod(*whole);
  if (allRuby) {
    for (const auto &kv : mod.funcs())
      if (mod.isRuby(kv.first))
        specs.push_back(kv.first);
  }
  if (verbose)
    errs() << kProg << ": " << mod.funcs().size() << " defined, "
           << mod.declared().size() << " declared-only, " << mod.addrTaken().size()
           << " address-taken\n";

  rt::Indirect ind = indirect == "address-taken" ? rt::Indirect::AddressTaken
                                                 : rt::Indirect::Conservative;
  rt::Analysis alloc(mod, rt::seedsAlloc(), ind);
  rt::Analysis pause(mod, rt::seedsPause(), ind);
  bool normalMode = allowAbort;

  std::vector<Row> rows;
  std::vector<std::string> paths;
  std::vector<std::tuple<std::string, std::string, std::vector<std::string>>> regions;
  std::vector<std::tuple<std::string, std::string, std::vector<rt::Analysis::Site>>> allSites;
  size_t bad = 0;

  for (const std::string &spec : specs) {
    std::string sym = mangle(spec, mod);
    if (!mod.funcs().count(sym)) {
      rows.push_back({"ERROR", spec, "no such function",
                      "'" + sym + "' is not defined in the linked module (check "
                      "the spelling, or that the method is actually reachable "
                      "from main and so was emitted)"});
      ++bad;
      continue;
    }
    std::set<std::string> region = alloc.region(sym, normalMode);
    regions.push_back({spec, sym, std::vector<std::string>(region.begin(), region.end())});

    if (allowAbort) {
      auto sj = alloc.setjmpIn(region);
      if (!sj.empty()) {
        rows.push_back({"REJECT", spec, "setjmp in region",
                        ("--allow-abort is unsound here: " + sj[0].caller +
                         " calls " + sj[0].callee +
                         ", so a longjmp can land back inside the region and the "
                         "allocation that preceded it is on a path that DOES "
                         "return (" + Twine(sj.size()) + " site(s))").str()});
        ++bad;
        continue;
      }
    }

    bool allocates = alloc.table(sym, normalMode);
    bool pauses = pause.table(sym, normalMode);
    if (!allocates) {
      rows.push_back({std::string("PROVEN") + (allowAbort ? "-MODULO-ABORT" : ""),
                      spec, "no allocation reachable",
                      (Twine(region.size()) +
                       " functions in the region, 0 reach an allocator; "
                       "SEEDS_PAUSE reachable: " + (pauses ? "yes" : "no")).str()});
      continue;
    }

    ++bad;
    auto causes = alloc.witness(sym, normalMode);
    auto sites = alloc.boundarySites(sym, normalMode);
    std::map<std::string, size_t> kinds;
    for (const auto &kv : causes)
      ++kinds[kv.first.first];
    std::string summary;
    for (const auto &kv : kinds) {
      if (!summary.empty())
        summary += "; ";
      summary += kv.first + "=" + std::to_string(kv.second);
    }
    rows.push_back({"REJECT", spec, "allocation reachable",
                    (Twine(sites.size()) + " Ruby call site(s) reach an allocator; " +
                     Twine(causes.size()) + " distinct terminal cause(s) [" + summary +
                     "] over a region of " + Twine(region.size()) + " functions").str()});
    allSites.push_back({spec, sym, sites});
    paths.push_back("=== " + spec + "  (" + sym + ")");
    paths.push_back(("  -- the Ruby call sites at the frontier (" +
                     Twine(sites.size()) + ") --").str());
    for (const auto &s : sites)
      paths.push_back("  " + padRight(s.where, 40) + " " + padRight(s.caller, 34) +
                      " -> " + s.callee + "  [" + s.kind + "]");
    paths.push_back("");
    for (const auto &kv : causes) {
      const std::string &kind = kv.first.first, &what = kv.first.second;
      std::string head;
      if (kind == "alloc")
        head = "ALLOC  " + what + " -- " + rt::allocReason(what).str();
      else if (kind == "external")
        head = "EXTERNAL  " + what +
               " -- no body in the linked module and not on the libc allow-list, "
               "so it is assumed to allocate";
      else
        head = "INDIRECT  in " + what +
               " -- a call through a function pointer; the target is not known "
               "statically";
      paths.push_back("  " + head);
      paths.push_back(fmtPath(mod, kv.second));
      paths.push_back("");
    }
  }

  outs() << "verdict\tentry\tcause\tdetail\n";
  for (const Row &r : rows) {
    if (quiet && StringRef(r.verdict).starts_with("PROVEN"))
      continue;
    outs() << r.verdict << "\t" << r.entry << "\t" << r.cause << "\t" << r.detail
           << "\n";
  }

  if (!outdir.empty()) {
    sys::fs::create_directories(outdir);
    auto open = [&](StringRef name) {
      SmallString<128> p(outdir);
      sys::path::append(p, name);
      std::error_code ec;
      return std::make_unique<raw_fd_ostream>(p, ec);
    };
    {
      auto os = open("verdict.tsv");
      *os << "verdict\tentry\tcause\tdetail\n";
      for (const Row &r : rows)
        *os << r.verdict << "\t" << r.entry << "\t" << r.cause << "\t" << r.detail
            << "\n";
    }
    {
      auto os = open("paths.txt");
      for (size_t i = 0; i < paths.size(); ++i)
        *os << paths[i] << (i + 1 == paths.size() ? "" : "\n");
      *os << "\n";
    }
    {
      auto os = open("sites.tsv");
      *os << "entry\twhere\tcaller\tcallee\tkind\n";
      for (const auto &t : allSites)
        for (const auto &s : std::get<2>(t))
          *os << std::get<0>(t) << "\t" << s.where << "\t" << s.caller << "\t"
              << s.callee << "\t" << s.kind << "\n";
    }
    if (printRegion) {
      auto os = open("region.tsv");
      *os << "entry\tsymbol\tfunction\tmay_alloc_any\tmay_alloc_normal\n";
      for (const auto &t : regions)
        for (const std::string &fn : std::get<2>(t))
          *os << std::get<0>(t) << "\t" << std::get<1>(t) << "\t" << fn << "\t"
              << (alloc.any(fn) ? 1 : 0) << "\t" << (alloc.normal(fn) ? 1 : 0)
              << "\n";
    }
  } else if (!paths.empty() && !quiet) {
    for (size_t i = 0; i < paths.size(); ++i)
      errs() << paths[i] << (i + 1 == paths.size() ? "" : "\n");
    errs() << "\n";
  }

  if (!alloc.externalUnknown().empty() && verbose) {
    std::string joined;
    size_t n = 0;
    for (const std::string &s : alloc.externalUnknown()) {
      if (n++ >= 40)
        break;
      if (!joined.empty())
        joined += ", ";
      joined += s;
    }
    errs() << "unknown externals (assumed allocating): " << joined << "\n";
  }
  if (bad)
    errs() << kProg << ": " << bad << " of " << specs.size()
           << " entries not proved allocation-free\n";
  if (keep)
    errs() << kProg << ": intermediates in " << work.path() << "\n";
  return bad ? 1 : 0;
}
