// Tensor table/dispatch output preserves frozen table_h/gen_rb whitespace and newlines for byte
// parity.
#include "Emit.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/raw_ostream.h"

#include <set>
#include <algorithm>
#include <map>

namespace spinel_mlir::tensor {
namespace {

/// EXTERN_DTYPES.
const std::map<std::string, int> kDtypeCode = {
    {"f32", 0}, {"u8", 1}, {"f16", 2}, {"i8", 3}, {"i32", 4}};

std::string join(const std::vector<std::string> &v, llvm::StringRef sep) {
  std::string out;
  for (const std::string &s : v) {
    if (!out.empty()) out += sep.str();
    out += s;
  }
  return out;
}

} // namespace

uint64_t fnv1a64(llvm::StringRef text) {
  uint64_t h = 0xCBF29CE484222325ULL;
  for (unsigned char b : text) {
    h ^= b;
    h *= 0x100000001B3ULL;
  }
  return h & 0x7FFFFFFFFFFFFFFFULL;
}

std::vector<std::string> Entry::tensors() const {
  std::vector<std::string> out;
  for (const std::string &p : params)
    if (p != "scalar") out.push_back(p);
  return out;
}

int Entry::nscalar() const {
  int n = 0;
  for (const std::string &p : params)
    if (p == "scalar") ++n;
  return n;
}

int Entry::tensorDest() const {
  if (dest < 0) return -1;
  int idx = 0;
  for (int64_t i = 0; i < static_cast<int64_t>(params.size()); ++i) {
    if (params[i] == "scalar") continue;
    if (i == dest) return idx;
    ++idx;
  }
  return -1;
}

std::string Entry::ranks() const {
  std::string out;
  for (const std::string &t : tensors())
    out += std::to_string(rankOf(t));
  return out;
}

std::string Entry::dtypeCodes() const {
  const std::vector<std::string> ts = tensors();
  if (dtypes.empty())
    return std::string(ts.size(), '0');
  std::string out;
  for (const std::string &d : dtypes) {
    auto it = kDtypeCode.find(d);
    out += std::to_string(it == kDtypeCode.end() ? 0 : it->second);
  }
  return out;
}

uint64_t Entry::sig() const {
  if (explicitSig) return *explicitSig;
  // Add |fq= only for foreign modules and |dt= only for nonuniform f32, preserving recorded
  // signature hashes.
  std::string extra;
  if (fq != "module." + name)
    extra = "|fq=" + fq + "|nin=" + std::to_string(nin());
  const std::string codes = dtypeCodes();
  if (codes != std::string(tensors().size(), '0'))
    extra += "|dt=" + codes;
  std::string text = name + "|" + join(params, ",") +
                     "|dest=" + std::to_string(tensorDest()) +
                     "|ret=" + std::to_string(retScalar) +
                     "|shape=" + constraints + extra;
  return fnv1a64(text);
}

static Entry buildPlainEntry(const TensorDecl &decl, const TensorBody &body) {
  Entry e;
  e.name = decl.name;
  e.fq = "module." + decl.name;
  e.params = decl.params;
  e.dest = decl.dest;
  e.retScalar = decl.returns == "scalar" ? 1 : 0;
  // Generated kernel regions are uniformly f32, so only explicit dtypes: declarations carry
  // tensor-side type codes.
  bool anyNonF32 = llvm::any_of(decl.dtypes,
                                [](const std::string &d) { return d != "f32"; });
  if (anyNonF32)
    for (size_t i = 0; i < decl.params.size(); ++i)
      if (decl.params[i] != "scalar") e.dtypes.push_back(decl.dtypes[i]);

  // Elementwise operands must match every dimension. Anchor the first appearing source and move
  // destination last, as frozen ordering does.
  auto tensorIndex = [&](llvm::StringRef nm) {
    int idx = 0;
    for (size_t i = 0; i < body.paramNames.size(); ++i) {
      if (decl.params[i] == "scalar") continue;
      if (body.paramNames[i] == nm) return idx;
      ++idx;
    }
    return -1;
  };
  const std::string destName =
      decl.dest >= 0 && decl.dest < static_cast<int64_t>(body.paramNames.size())
          ? body.paramNames[decl.dest]
          : std::string();
  std::vector<std::string> vecs;
  for (const TensorSource &s : body.sources) {
    std::string nm;
    if (s.kind == TensorSource::Kind::Param) {
      auto it = body.rank.find(s.name);
      if (it == body.rank.end() || it->second != body.ewRank) continue;
      nm = s.name;
    } else if (s.kind == TensorSource::Kind::Window) {
      // Window input images are not elementwise operands (regions read convolution results), but
      // remain tensor arguments whose shapes must match destination, so include them in these
      // equalities.
      nm = s.name;
    } else {
      continue;   // Handle matvec separately below.
    }
    if (!llvm::is_contained(vecs, nm)) vecs.push_back(nm);
  }
  if (!destName.empty()) {
    std::vector<std::string> reordered;
    for (const std::string &v : vecs)
      if (v != destName) reordered.push_back(v);
    reordered.push_back(destName);
    vecs = std::move(reordered);
  }
  std::vector<std::string> cons;
  if (!vecs.empty()) {
    const std::string anchor = vecs.front();
    for (size_t i = 1; i < vecs.size(); ++i)
      for (int dim = 0; dim < body.ewRank; ++dim)
        cons.push_back(std::to_string(tensorIndex(anchor)) + ":" +
                       std::to_string(dim) + "=" +
                       std::to_string(tensorIndex(vecs[i])) + ":" +
                       std::to_string(dim));
  }
  for (const TensorSource &s : body.sources) {
    if (s.kind != TensorSource::Kind::Matvec) continue;
    cons.push_back(std::to_string(tensorIndex(s.mat)) + ":1=" +
                   std::to_string(tensorIndex(s.vec)) + ":0");
    if (!destName.empty())
      cons.push_back(std::to_string(tensorIndex(s.mat)) + ":0=" +
                     std::to_string(tensorIndex(destName)) + ":0");
  }
  // n-mode product: three equalities and two alias prohibitions. IR does not identify dimension
  // meaning; only the shim can diagnose swapped axes or transposed weights. Order follows
  // sorted(mminfo).
  {
    std::vector<std::tuple<std::string, int, std::string>> mm;
    std::vector<std::tuple<std::string, int, std::string, std::string>> tp;
    std::vector<std::string> bl;
    for (const TensorSource &s : body.sources) {
      if (s.kind == TensorSource::Kind::Mode)
        mm.push_back({s.name, s.axis, s.mat});
      else if (s.kind == TensorSource::Kind::Tap)
        tp.push_back({s.name, s.axis, s.idx, s.wgt});
      else if (s.kind == TensorSource::Kind::Bilinear)
        bl.push_back(s.name);
    }
    std::sort(mm.begin(), mm.end());
    std::sort(tp.begin(), tp.end());
    std::sort(bl.begin(), bl.end());
    const std::string di =
        destName.empty() ? std::string() : std::to_string(tensorIndex(destName));
    for (const auto &k : mm) {
      const std::string src = std::get<0>(k), mat = std::get<2>(k);
      const int ax = std::get<1>(k);
      const std::string si = std::to_string(tensorIndex(src)),
                        mi = std::to_string(tensorIndex(mat));
      cons.push_back(mi + ":0=" + si + ":" + std::to_string(ax));
      if (destName.empty()) continue;
      cons.push_back(mi + ":1=" + di + ":" + std::to_string(ax));
      for (int j = 0; j < 3; ++j)
        if (j != ax)
          cons.push_back(si + ":" + std::to_string(j) + "=" + di + ":" +
                         std::to_string(j));
      if (src != destName) cons.push_back(si + "!" + di);
      if (mat != destName) cons.push_back(mi + "!" + di);
    }
    // Banded product: tap and weights agree with each other and destination resampling axis. Source
    // length on that axis is deliberately free: tap indexes it and the kernel clamps.
    for (const auto &k : tp) {
      const std::string src = std::get<0>(k), idx = std::get<2>(k),
                        wgt = std::get<3>(k);
      const int ax = std::get<1>(k);
      const std::string si = std::to_string(tensorIndex(src)),
                        ii = std::to_string(tensorIndex(idx)),
                        wi = std::to_string(tensorIndex(wgt));
      cons.push_back(ii + ":0=" + wi + ":0");
      cons.push_back(ii + ":1=" + wi + ":1");
      cons.push_back(ii + "!" + wi);
      if (destName.empty()) continue;
      cons.push_back(ii + ":0=" + di + ":" + std::to_string(ax));
      for (int j = 0; j < 3; ++j)
        if (j != ax)
          cons.push_back(si + ":" + std::to_string(j) + "=" + di + ":" +
                         std::to_string(j));
      if (src != destName) cons.push_back(si + "!" + di);
      cons.push_back(ii + "!" + di);
      cons.push_back(wi + "!" + di);
    }
    // bilinear constrains channels only; it may change both spatial axes, using the supplied
    // source/destination shapes.
    for (const std::string &src : bl) {
      if (destName.empty() || src == destName) continue;
      const std::string si = std::to_string(tensorIndex(src));
      cons.push_back(si + ":2=" + di + ":2");
      cons.push_back(si + "!" + di);
    }
    // hist adds no constraints; destination length is the bin count.
  }

  // Two additional constraints for window operations.
  const bool anyWindow = llvm::any_of(body.sources, [](const TensorSource &s) {
    return s.kind == TensorSource::Kind::Window;
  });
  if (anyWindow) {
    // Channel count is declared fact: constant filter shape makes C static in IR. Check the real
    // caller tensor too, or a three-channel image passed to channels:1 silently processes channel 0
    // only.
    if (!vecs.empty())
      cons.push_back(std::to_string(tensorIndex(vecs.front())) +
                     ":2=#" + std::to_string(decl.channels));
    // Runtime half of alias rejection. Static dst.assign(dst.conv2d(:k)) refusal cannot prevent
    // blur(img,img), the same unsafety through equal handles rather than equal names.
    if (!destName.empty()) {
      std::set<std::string> wsrc;
      for (const TensorSource &s : body.sources)
        if (s.kind == TensorSource::Kind::Window) wsrc.insert(s.name);
      for (const std::string &src : wsrc)   // std::set is lexically sorted.
        if (src != destName)
          cons.push_back(std::to_string(tensorIndex(src)) + "!" +
                         std::to_string(tensorIndex(destName)));
    }
  }
  e.constraints = join(cons, ";");
  return e;
}

std::vector<Entry> buildEntries(const TensorDecl &decl, const TensorBody &body) {
  if (decl.reduction != "fixed_tree")
    return {buildPlainEntry(decl, body)};

  // fixed_tree has two entries: __ft_pre evaluates the inner expression elementwise, adding
  // destination vec last; __ft_step handles one tree level. 0:0/B=1:0 asks the shim to check
  // rounded-up input/output length ratio B.
  auto tensorIndex = [&](llvm::StringRef nm) {
    int idx = 0;
    for (size_t i = 0; i < body.paramNames.size(); ++i) {
      if (decl.params[i] == "scalar") continue;
      if (body.paramNames[i] == nm) return idx;
      ++idx;
    }
    return -1;
  };
  int outTi = 0;
  for (const std::string &p : decl.params)
    if (p != "scalar") ++outTi;

  Entry pre;
  pre.name = decl.name + "__ft_pre";
  pre.fq = "module." + pre.name;
  pre.params = decl.params;
  pre.params.push_back("vec");
  pre.dest = static_cast<int64_t>(pre.params.size()) - 1;
  pre.retScalar = 0;
  std::vector<std::string> cons;
  for (const TensorSource &s : body.sources) {
    if (s.kind != TensorSource::Kind::Param) continue;
    cons.push_back(std::to_string(tensorIndex(s.name)) + ":0=" +
                   std::to_string(outTi) + ":0");
  }
  pre.constraints = join(cons, ";");

  Entry step;
  step.name = decl.name + "__ft_step";
  step.fq = "module." + step.name;
  step.params = {"vec", "vec"};
  step.dest = 1;
  step.retScalar = 0;
  step.constraints = "0:0/" + std::to_string(decl.treeArity) + "=1:0";
  return {pre, step};
}

Entry buildExternEntry(const TensorExtern &x) {
  Entry e;
  e.name = x.name;
  e.fq = x.vmModule + "." + x.entry;
  // Ruby tensor sequence is arguments plus result storage. Push arguments only, so nin is one less,
  // matching len(self.inputs).
  e.params = x.params;
  e.params.push_back(x.returns);
  e.dest = static_cast<int64_t>(x.params.size());
  e.explicitNin = static_cast<int>(x.params.size());
  e.retScalar = 0;
  for (size_t i = 0; i < x.params.size(); ++i)
    e.dtypes.push_back(i < x.dtypes.size() ? x.dtypes[i] : x.dtype);
  e.dtypes.push_back(x.returnsDtype.empty() ? x.dtype : x.returnsDtype);

  // Translate declared shapes into existing shim a:d=b:e / a:d=#K constraints. Infer nothing;
  // restate declarations.
  std::vector<std::vector<TensorExtern::Dim>> shapes = x.shapes;
  shapes.push_back(x.returnsShape);
  std::vector<std::string> cons;
  std::map<std::string, std::pair<size_t, size_t>> first;
  for (size_t i = 0; i < shapes.size(); ++i)
    for (size_t d = 0; d < shapes[i].size(); ++d) {
      const TensorExtern::Dim &v = shapes[i][d];
      if (v.fixed) {
        cons.push_back(std::to_string(i) + ":" + std::to_string(d) + "=#" +
                       std::to_string(v.value));
      } else {
        auto it = first.find(v.sym);
        if (it != first.end())
          cons.push_back(std::to_string(i) + ":" + std::to_string(d) + "=" +
                         std::to_string(it->second.first) + ":" +
                         std::to_string(it->second.second));
        else
          first[v.sym] = {i, d};
      }
    }
  e.constraints = join(cons, ";");
  return e;
}

std::string externDispatch(const std::vector<TensorExtern> &externs) {
  std::string out;
  for (const TensorExtern &x : externs) {
    const Entry e = buildExternEntry(x);
    const size_t nin = x.params.size();
    std::string args;
    for (size_t i = 0; i < nin; ++i) args += "t" + std::to_string(i) + ", ";
    args += "dest";
    std::string handles;
    for (size_t i = 0; i < nin; ++i)
      handles += "t" + std::to_string(i) + ".handle, ";
    handles += "dest.handle, ";
    for (size_t i = nin + 1; i < 4; ++i) handles += "0, ";
    out += "\n# tensor_extern: " + e.fq +
           " lives in a .vmfb spinel-mlirgen did not write.\n";
    out += "# " + std::to_string(nin) +
           " argument(s) are pushed; the result is adopted into `dest`.\n";
    out += "def " + x.name + "(" + args + ")\n";
    out += "  rc = SPT.sp_t_invoke(\"" + x.name + "\", " +
           std::to_string(e.sig()) + ", 0.0, " + handles + "dest.length)\n";
    out += "  if rc != 0\n";
    out += "    raise TensorError, \"" + x.name + ": #{SPT.sp_t_last_error}\"\n";
    out += "  end\n  dest\nend\n";
  }
  return out;
}

std::string tableHeader(llvm::StringRef sourceName,
                        const std::vector<Entry> &entries) {
  std::string s;
  llvm::raw_string_ostream os(s);
  auto line = [&](llvm::StringRef t) { os << t << "\n"; };
  os << "/* Generated by tools/mlir/spinel-mlirgen --tensor from " << sourceName
     << " -- do not edit.\n";
  line(" * The entry table sp_tensor_shim.c dispatches through: one row per");
  line(" * .vmfb entry, matching the func.func of the same name. */");
  line("#ifndef SP_TENSOR_TABLE_H_");
  line("#define SP_TENSOR_TABLE_H_");
  line("");
  line("typedef struct {");
  line("  const char *name;");
  line("  const char *fq;/* fully-qualified VM name: `module.<name>` for an");
  line("                    entry we generated, `<module>.<entry>` for one");
  line("                    a tensor_extern points at (E034)            */");
  line("  int nscalar;   /* leading f32 scalars pushed as vm values      */");
  line("  int ntensor;   /* Ruby-visible tensors of this entry           */");
  line("  int nin;       /* how many of them are PUSHED as arguments:");
  line("                    ntensor for a destination-passing kernel we");
  line("                    generated, ntensor-1 for a foreign export");
  line("                    that returns its result (E034)              */");
  line("  int dest;      /* index into the tensor list, or -1            */");
  line("  int ret_scalar;/* 1 = the entry returns f32, not a buffer view */");
  line("  const char *ranks;  /* '1'/'2' per tensor argument             */");
  line("  const char *dtypes; /* SP_T_* element-type code per tensor:");
  line("                         '0' f32 '1' u8 '2' f16 '3' i8 '4' i32.");
  line("                         All '0' for a kernel we generated (E037) */");
  line("  const char *shape;  /* 'a:d=b:e' / 'a:d/B=b:e' / 'a:d=#K' /");
  line("                         'a!b' (E042: a and b must be DIFFERENT");
  line("                         buffers -- a window op reads a");
  line("                         neighbourhood), ';'-separated          */");
  line("  long long sig; /* FNV-1a of the declaration; the dispatch must");
  line("                    present the same one (E033 s4)              */");
  line("} sp_t_entry_t;");
  line("");
  line("static const sp_t_entry_t SP_T_TABLE[] = {");
  for (const Entry &e : entries)
    os << "  {\"" << e.name << "\", \"" << e.fq << "\", " << e.nscalar() << ", "
       << e.tensors().size() << ", " << e.nin() << ", " << e.tensorDest() << ", "
       << e.retScalar << ", \"" << e.ranks() << "\", \"" << e.dtypeCodes()
       << "\", \"" << e.constraints << "\", " << e.sig() << "LL},\n";
  line("};");
  os << "#define SP_T_TABLE_N " << entries.size() << "\n";
  line("");
  line("#endif");
  return s;
}

std::string generatedRuby(llvm::StringRef sourceName,
                          const std::vector<TensorDecl> &decls,
                          const std::vector<TensorBody> &bodies,
                          const std::vector<std::vector<Entry>> &entriesPerDecl,
                          llvm::StringRef fuseSourceName,
                          llvm::StringRef fuseDispatch) {
  std::vector<std::string> out = {
      (llvm::Twine("# Generated by tools/mlir/spinel-mlirgen --tensor from ") +
       sourceName + " -- do not edit.").str(),
      "#",
      "# One `def` per tensor_def, dispatching through the entry table in",
      (llvm::Twine("# sp_tensor_shim.c.  The declaration bodies in ") + sourceName +
       " are NEVER required").str(),
      "# into a program: spinel rejects a duplicate top-level `def`, and the",
      "# tensor expressions in them are kernel-world only (they raise).",
      "#",
      "# The literal after the kernel name is the SIGNATURE HASH of the",
      "# declaration this dispatch was generated from.  The shim refuses to",
      "# invoke an entry whose table row carries a different one, which is what",
      "# catches a stale .gen.rb paired with a fresher table/.vmfb (E033 s4).",
      ""};
  if (!fuseDispatch.empty()) {
    out.push_back((llvm::Twine("# E038: dispatches for the FUSED statements of ") +
                   fuseSourceName + ".  The statements").str());
    out.push_back("# themselves were rewritten into calls to these; compile the "
                  "rewritten file.");
    out.push_back("");
    // Fuse.cpp supplies the body; its text hash determines kernel identity.
    llvm::StringRef rest = fuseDispatch;
    rest.consume_back("\n");
    llvm::SmallVector<llvm::StringRef> lines;
    rest.split(lines, '\n');
    for (llvm::StringRef line : lines)
      out.push_back(line.str());
    // Keep the final newline: frozen gen_rb joins a sequence ending with an empty string.
    out.push_back("");
  }
  for (size_t i = 0; i < decls.size(); ++i) {
    const TensorDecl &d = decls[i];
    const TensorBody &b = bodies[i];
    if (d.reduction == "fixed_tree") {
      // Host tree driver runs pre once, then step until one element remains. N determines level
      // count, but addition order is device-independent, the whole guarantee of this mode.
      const Entry &pre = entriesPerDecl[i][0];
      const Entry &step = entriesPerDecl[i][1];
      std::vector<std::string> tens;
      for (size_t k = 0; k < d.params.size(); ++k)
        if (d.params[k] != "scalar") tens.push_back(b.paramNames[k]);
      std::vector<std::string> hs;
      for (const std::string &t : tens) hs.push_back(t + ".handle");
      hs.push_back("a.handle");
      while (hs.size() < 4) hs.push_back("0");
      const std::string empty =
          b.root == "sum"
              ? "    0.0"
              : "    raise TensorError, \"" + d.name + ": an empty tensor has no " +
                    b.root + "\"";
      const int64_t B = d.treeArity;
      out.push_back("def " + d.name + "(" + join(b.paramNames, ", ") + ")");
      out.push_back("  # reduction: :fixed_tree -- B=" + std::to_string(B) +
                    ", device-independent order.");
      out.push_back("  n = " + tens.front() + ".length");
      out.push_back("  if n == 0");
      out.push_back(empty);
      out.push_back("  else");
      out.push_back("    a = Tensor.vec(:f32, n)");
      out.push_back("    rc = SPT.sp_t_invoke(\"" + pre.name + "\", " +
                    std::to_string(pre.sig()) + ", 0.0, " + hs[0] + ", " + hs[1] +
                    ", " + hs[2] + ", " + hs[3] + ", n)");
      out.push_back("    if rc != 0");
      out.push_back("      raise TensorError, \"" + pre.name +
                    ": #{SPT.sp_t_last_error}\"");
      out.push_back("    end");
      out.push_back("    m = n");
      out.push_back("    while m > 1");
      out.push_back("      mm = (m + " + std::to_string(B - 1) + ") / " +
                    std::to_string(B));
      out.push_back("      b = Tensor.vec(:f32, mm)");
      out.push_back("      rc = SPT.sp_t_invoke(\"" + step.name + "\", " +
                    std::to_string(step.sig()) +
                    ", 0.0, a.handle, b.handle, 0, 0, mm)");
      out.push_back("      if rc != 0");
      out.push_back("        raise TensorError, \"" + step.name +
                    ": #{SPT.sp_t_last_error}\"");
      out.push_back("      end");
      out.push_back("      a.free!");
      out.push_back("      a = b");
      out.push_back("      m = mm");
      out.push_back("    end");
      out.push_back("    v = a.to_f32_a");
      out.push_back("    a.free!");
      out.push_back("    v[0]");
      out.push_back("  end");
      out.push_back("end");
      out.push_back("");
      continue;
    }
    const Entry &e = entriesPerDecl[i][0];
    std::vector<std::string> scal, tens;
    for (size_t k = 0; k < d.params.size(); ++k)
      (d.params[k] == "scalar" ? scal : tens).push_back(b.paramNames[k]);
    const std::string s0 = scal.empty() ? "0.0" : scal.front();
    std::vector<std::string> hs;
    for (const std::string &t : tens) hs.push_back(t + ".handle");
    while (hs.size() < 4) hs.push_back("0");
    const std::string nlen =
        d.dest >= 0 ? b.paramNames[d.dest] : (tens.empty() ? "0" : tens.front());
    out.push_back("def " + d.name + "(" + join(b.paramNames, ", ") + ")");
    const std::string sig = std::to_string(e.sig());
    if (e.retScalar == 1) {
      out.push_back("  SPT.sp_t_invoke_f(\"" + e.name + "\", " + sig + ", " + s0 +
                    ", " + hs[0] + ", " + hs[1] + ", " + hs[2] + ", " + hs[3] +
                    ", " + nlen + ".length)");
    } else {
      out.push_back("  rc = SPT.sp_t_invoke(\"" + e.name + "\", " + sig + ", " + s0 +
                    ", " + hs[0] + ", " + hs[1] + ", " + hs[2] + ", " + hs[3] +
                    ", " + nlen + ".length)");
      out.push_back("  if rc != 0");
      out.push_back("    raise TensorError, \"" + d.name +
                    ": #{SPT.sp_t_last_error}\"");
      out.push_back("  end");
      out.push_back("  " + b.paramNames[d.dest]);
    }
    out.push_back("end");
    out.push_back("");
  }
  return join(out, "\n");
}

} // namespace spinel_mlir::tensor
