// Ruby source to linked module.
#include "spinel-mlir/Realtime/WholeModule.h"

#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Linker/Linker.h"
#include "llvm/Object/Archive.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"

#include <map>

using namespace llvm;

namespace spinel_mlir::realtime {
namespace {

// Frozen run() sends build stdout to stderr, reserving stdout for verdict TSV. Print + cmd only
// under -v.
int runStage(ArrayRef<StringRef> cmd, bool verbose, StringRef stage,
             StringRef work, std::string &error) {
  if (verbose) {
    std::string line;
    for (size_t i = 0; i < cmd.size(); ++i) {
      if (i)
        line += " ";
      line += cmd[i].str();
    }
    errs() << "+ " << line << "\n";
  }
  SmallString<128> outFile(work);
  sys::path::append(outFile, "stage.out");
  std::optional<StringRef> redirects[] = {StringRef(""), StringRef(outFile),
                                          std::nullopt};
  std::string execError;
  int rc = sys::ExecuteAndWait(cmd[0], cmd, std::nullopt, redirects, 0, 0,
                               &execError);
  auto buf = MemoryBuffer::getFile(outFile);
  StringRef out = buf ? (*buf)->getBuffer() : StringRef();
  if (!execError.empty()) {
    error = ("stage '" + stage + "' failed (exit 1)").str();
    return 1;
  }
  if (verbose && !out.empty())
    errs() << out;
  if (rc != 0) {
    if (!out.empty() && !verbose)
      errs() << out;
    error = ("stage '" + stage + "' failed (exit " + Twine(rc) + ")").str();
  }
  return rc;
}

} // namespace

std::unique_ptr<Module> parseInput(StringRef path, LLVMContext &ctx,
                                   std::string &error) {
  SMDiagnostic err;
  auto m = parseIRFile(path, err, ctx);
  if (!m) {
    std::string s;
    raw_string_ostream os(s);
    err.print("spinel-rtcheck", os);
    error = s;
  }
  return m;
}

std::unique_ptr<Module> buildWholeModule(StringRef source,
                                         const BuildOptions &opts,
                                         LLVMContext &ctx,
                                         std::string &error) {
  StringRef base = sys::path::stem(source);
  SmallString<128> cfile(opts.work);
  sys::path::append(cfile, base + ".c");

  // 1. spinel -c
  {
    SmallVector<StringRef, 8> cmd{opts.spinelBin, source, "-c", "-o", cfile};
    std::string ov = opts.intOverflow;
    if (!ov.empty()) {
      cmd.push_back("--int-overflow");
      cmd.push_back(ov);
    }
    if (runStage(cmd, opts.verbose, "spinel -c", opts.work, error) != 0)
      return nullptr;
  }

  // Read SPINEL_CFLAGS/SPINEL_USES_THREADS from the first 400 KB of generated C.
  bool threads = false;
  std::vector<std::string> cflags;
  {
    auto buf = MemoryBuffer::getFile(cfile);
    if (!buf) {
      error = "cannot read " + cfile.str().str();
      return nullptr;
    }
    StringRef head = (*buf)->getBuffer().substr(0, 400000);
    threads = head.contains("/* SPINEL_USES_THREADS */");
    SmallVector<StringRef, 64> lines;
    head.split(lines, '\n');
    for (StringRef l : lines) {
      StringRef rest = l;
      if (!rest.consume_front("/* SPINEL_CFLAGS: "))
        continue;
      size_t end = rest.find("*/");
      if (end == StringRef::npos)
        continue;
      StringRef flags = rest.substr(0, end).rtrim();
      SmallVector<StringRef, 8> parts;
      flags.split(parts, ' ', -1, false);
      for (StringRef p : parts)
        if (!p.empty())
          cflags.push_back(p.str());
    }
  }

  // 3. clang -O0 -g -disable-llvm-passes -S -emit-llvm
  SmallString<128> tu(opts.work);
  sys::path::append(tu, base + ".tu.ll");
  {
    std::string mode = opts.intOverflow == "wrap"      ? "WRAP"
                       : opts.intOverflow == "promote" ? "PROMOTE"
                                                       : "RAISE";
    SmallString<128> clang(opts.llvmBin);
    sys::path::append(clang, "clang");
    SmallString<128> inc1(opts.spinelDir), inc2(opts.spinelDir);
    sys::path::append(inc1, "lib");
    sys::path::append(inc2, "lib", "regexp");
    std::string i1 = ("-I" + inc1).str(), i2 = ("-I" + inc2).str();
    std::string dmode = "-DSP_INT_OVERFLOW_MODE_" + mode;
    SmallVector<StringRef, 24> cmd{clang, "-O0", "-g", "-Xclang",
                                   "-disable-llvm-passes", "-S", "-emit-llvm",
                                   "-Wno-everything", "-fno-strict-aliasing",
                                   i1, i2, dmode};
    if (threads) {
      cmd.push_back("-DSP_THREADS");
      cmd.push_back("-ftls-model=initial-exec");
    }
    for (const std::string &f : cflags)
      cmd.push_back(f);
    cmd.push_back(cfile);
    cmd.push_back("-o");
    cmd.push_back(tu);
    if (runStage(cmd, opts.verbose, "clang -emit-llvm", opts.work, error) != 0)
      return nullptr;
  }

  auto whole = parseInput(tu, ctx, error);
  if (!whole)
    return nullptr;
  return linkRuntime(std::move(whole), threads, opts, ctx, error);
}

std::unique_ptr<Module> linkRuntime(std::unique_ptr<Module> whole, bool threads,
                                    const BuildOptions &opts, LLVMContext &ctx,
                                    std::string &error) {
  // Open the runtime bitcode archive and link members in name order in process. Frozen llvm-ar x
  // then sorted(path) overwrites duplicate member names; retain only the last by name to match it.
  SmallString<128> arch(opts.bcDir);
  sys::path::append(arch, threads ? "libspinel_rt_mt_lto.a" : "libspinel_rt_lto.a");
  if (!sys::fs::exists(arch)) {
    error = ("no runtime bitcode at " + arch +
             " -- run tools/llvm/build_rt_bc.sh first").str();
    return nullptr;
  }


  auto archBuf = MemoryBuffer::getFile(arch);
  if (!archBuf) {
    error = "cannot read " + arch.str().str();
    return nullptr;
  }
  auto archive = object::Archive::create(archBuf.get()->getMemBufferRef());
  if (!archive) {
    error = toString(archive.takeError());
    return nullptr;
  }
  std::map<std::string, MemoryBufferRef> members;
  Error err = Error::success();
  for (const object::Archive::Child &c : (*archive)->children(err)) {
    auto name = c.getName();
    if (!name) {
      consumeError(name.takeError());
      continue;
    }
    if (!StringRef(*name).ends_with(".o"))
      continue;
    auto buf = c.getMemoryBufferRef();
    if (!buf) {
      consumeError(buf.takeError());
      continue;
    }
    members[name->str()] = *buf; // Last same-name member wins, matching llvm-ar x overwrite.
  }
  if (err) {
    error = toString(std::move(err));
    return nullptr;
  }
  Linker linker(*whole);
  for (const auto &kv : members) {
    auto m = parseBitcodeFile(kv.second, ctx);
    if (!m) {
      error = toString(m.takeError());
      return nullptr;
    }
    if (linker.linkInModule(std::move(*m))) {
      error = "stage 'llvm-link' failed (exit 1)";
      return nullptr;
    }
  }
  for (const std::string &extra : opts.linkBc) {
    auto m = parseInput(extra, ctx, error);
    if (!m)
      return nullptr;
    if (linker.linkInModule(std::move(m))) {
      error = "stage 'llvm-link' failed (exit 1)";
      return nullptr;
    }
  }
  return whole;
}

} // namespace spinel_mlir::realtime
