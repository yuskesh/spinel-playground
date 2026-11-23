//===- Report.cpp - the per-entry, per-target CORE build report -----------===//
#include "spinel-mlir/Core/Report.h"

#include "spinel-mlir/Core/StackBudget.h"

#include "spinel-mlir/Core/Effects.h"
#include "spinel-mlir/Core/Kernel.h"
#include "spinel-mlir/Core/LoopBounds.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SHA256.h"
#include "llvm/Support/raw_ostream.h"

#include <array>
#include <fstream>
#include <optional>
#include <vector>

using namespace llvm;

namespace spinel_mlir::core {
namespace {

std::string line(StringRef category, const Twine &detail) {
  return ("spinel-core-kernel: " + category + ": " + detail).str();
}

std::optional<std::string> readFile(StringRef path) {
  auto buf = MemoryBuffer::getFile(path, /*IsText=*/false,
                                   /*RequiresNullTerminator=*/false,
                                   /*IsVolatile=*/true);
  if (!buf) return std::nullopt;
  return (*buf)->getBuffer().str();
}

/// Streamed: a compiler executable is hundreds of megabytes, and holding one
/// in memory per build to digest it is a cost the build does not need.
std::optional<std::string> fileDigest(StringRef path) {
  std::ifstream in(path.str(), std::ios::binary);
  if (!in) return std::nullopt;
  SHA256 h;
  std::vector<char> chunk(1 << 20);
  while (in) {
    in.read(chunk.data(), static_cast<std::streamsize>(chunk.size()));
    const std::streamsize got = in.gcount();
    if (got > 0)
      h.update(ArrayRef<uint8_t>(reinterpret_cast<const uint8_t *>(chunk.data()),
                                 static_cast<size_t>(got)));
  }
  if (in.bad()) return std::nullopt;
  return toHex(h.final(), /*LowerCase=*/true);
}

/// DECISION 0014: one extern's provider evidence, read once and bound.
///
/// The file is `<staging>/evidence/<symbol>.json` as the contract's `evidence`
/// path names it, relative to the contract. It is accepted only if its
/// format, symbol, target and the three configuration digests all match; the
/// first mismatch is the reason, and an unbound extern has no stack and no
/// effects in the report rather than a guess.
struct ExternEvidence {
  bool bound = false;
  std::string reason;      ///< why not, when not bound
  std::string file;        ///< the evidence file, as named
  std::string sha256;      ///< of the evidence file's bytes, when read
  uint64_t stackBytes = 0;
  std::string stackMethod;
  bool isrOk = false;
  bool blocking = false;
  std::string effectsRow;
  std::string provenance;
  std::string objectFile, objectSha256;
};

ExternEvidence readExternEvidence(const ExternDecl &e, StringRef contractDir,
                                  StringRef target, const std::array<std::string, 3> &binding) {
  ExternEvidence ev;
  ev.file = e.evidencePath;
  SmallString<256> path;
  if (sys::path::is_absolute(e.evidencePath)) path = e.evidencePath;
  else { path = contractDir; sys::path::append(path, e.evidencePath); }
  const auto text = readFile(path);
  if (!text) { ev.reason = "evidence file " + e.evidencePath + " cannot be read"; return ev; }
  ev.sha256 = llvm::toHex(SHA256::hash(llvm::arrayRefFromStringRef(*text)), /*LowerCase=*/true);
  auto parsed = json::parse(*text);
  if (!parsed) {
    llvm::consumeError(parsed.takeError());
    ev.reason = "evidence file " + e.evidencePath + " is not JSON";
    return ev;
  }
  const json::Object *o = parsed->getAsObject();
  if (!o) { ev.reason = "evidence file " + e.evidencePath + " is not a JSON object"; return ev; }
  auto strOf = [&](const json::Object &obj, StringRef key) -> std::string {
    if (auto s = obj.getString(key)) return s->str();
    return "";
  };
  if (strOf(*o, "format") != "spinel-provider-evidence" || o->getInteger("version") != 1) {
    ev.reason = "evidence file " + e.evidencePath + " is not spinel-provider-evidence version 1";
    return ev;
  }
  if (strOf(*o, "symbol") != e.symbol) {
    ev.reason = "evidence names symbol '" + strOf(*o, "symbol") + "', not " + e.symbol;
    return ev;
  }
  if (strOf(*o, "target") != target) {
    ev.reason = "evidence is for target " + strOf(*o, "target") + ", not " + target.str();
    return ev;
  }
  const char *keys[3] = {"dts_sha256", "config_sha256", "flags_sha256"};
  for (size_t i = 0; i < 3; ++i)
    if (strOf(*o, keys[i]) != binding[i]) {
      ev.reason = std::string("evidence is bound to another configuration: ") + keys[i] +
                  " differs";
      return ev;
    }
  const json::Object *stack = o->getObject("stack");
  const json::Object *effects = o->getObject("effects");
  const json::Object *object = o->getObject("object");
  if (!stack || !stack->getInteger("bytes") || !effects || !object) {
    ev.reason = "evidence file " + e.evidencePath + " lacks stack.bytes, effects or object";
    return ev;
  }
  const int64_t bytes = *stack->getInteger("bytes");
  if (bytes < 0) { ev.reason = "evidence stack.bytes is negative"; return ev; }
  ev.stackBytes = static_cast<uint64_t>(bytes);
  ev.stackMethod = strOf(*stack, "method");
  ev.isrOk = effects->getBoolean("isr_ok").value_or(false);
  ev.blocking = effects->getBoolean("blocking").value_or(true);
  ev.effectsRow = strOf(*effects, "row");
  ev.provenance = strOf(*o, "provenance");
  ev.objectFile = strOf(*object, "file");
  ev.objectSha256 = strOf(*object, "sha256");
  ev.bound = true;
  return ev;
}

/// The first line a tool prints, trimmed, or nullopt if it did not run.
std::optional<std::string> firstLine(RunToolFn runTool, TempPathFn tempPath,
                                     StringRef tool, ArrayRef<std::string> args,
                                     StringRef name) {
  const std::string out = tempPath((name + ".out").str());
  const std::string err = tempPath((name + ".err").str());
  std::vector<StringRef> argv;
  for (const std::string &a : args) argv.push_back(a);
  if (runTool(tool, argv, out, err) != 0) return std::nullopt;
  auto text = readFile(out);
  if (!text) return std::nullopt;
  StringRef first = StringRef(*text).split('\n').first.trim();
  if (first.empty()) return std::nullopt;
  return first.str();
}

/// Decision 0010's table, in its row order: the property name and its mode in
/// each of the two columns this build can be asked for.
struct PropertyMode {
  const char *name;
  const char *hostedStage2;
  const char *realtime;
};
constexpr PropertyMode kModes[] = {
    {"recursion", "enforce", "enforce"},
    {"allocation", "enforce", "enforce"},
    {"loop_bound", "observe", "enforce"},
    {"stack_budget", "observe", "enforce"},
    {"extern_effects", "enforce", "enforce"},
    {"undefined_symbols", "enforce", "enforce"},
};

} // namespace

CoreEmitStatus writeCoreReport(const PreparedBoundary &prepared,
                               const EligibilityReport &admitted,
                               const CoreReportRequest &request,
                               RunToolFn runTool, TempPathFn tempPath,
                               CoreDiagnosticFn diag) {
  const BoundaryContract &c = prepared.contract;
  if (request.path.empty())
    return diag(line("bad-request", "no report path")), CoreEmitStatus::BadRequest;
  const bool realtime = request.profile == kRealtimeProfile;
  if (request.profile != kHostedStage2Profile && !realtime) {
    diag(line("bad-request",
              "profile '" + request.profile +
                  "' is not implemented; this build reports under " +
                  kHostedStage2Profile + " and " + kRealtimeProfile));
    return CoreEmitStatus::BadRequest;
  }
  if (request.fixtureStack.given && !realtime) {
    diag(line("bad-request",
              "the fixture stack provision is accepted only under the " +
                  Twine(kRealtimeProfile) + " profile"));
    return CoreEmitStatus::BadRequest;
  }
  if (!admitted.checked()) {
    diag(line("internal", "the report was asked for an entry that was not admitted"));
    return CoreEmitStatus::BadRequest;
  }

  // DECISION 0014: a version 2 report names the configuration its extern
  // evidence is bound to; without one no evidence could be accepted, so the
  // request is refused rather than written with every extern unknown.
  const bool application = c.isApplication();
  std::array<std::string, 3> binding;
  if (application) {
    if (request.configBinding.empty()) {
      diag(line("bad-request",
                "a version 2 report needs --config-binding <dts>:<config>:<flags>, "
                "the digests its extern evidence is bound to"));
      return CoreEmitStatus::BadRequest;
    }
    SmallVector<StringRef, 4> parts;
    StringRef(request.configBinding).split(parts, ':');
    bool good = parts.size() == 3;
    for (StringRef p : parts)
      if (p.size() != 64 || p.find_first_not_of("0123456789abcdef") != StringRef::npos)
        good = false;
    if (!good) {
      diag(line("bad-request",
                "--config-binding is three lowercase sha256 digests, dts:config:flags"));
      return CoreEmitStatus::BadRequest;
    }
    for (size_t i = 0; i < 3; ++i) binding[i] = parts[i].str();
  }

  // The inputs a report names, each read or run once, here. An admission-only
  // report has no object to digest.
  const auto objectDigest = request.admissionOnly ? std::optional<std::string>("")
                                                  : fileDigest(request.objectPath);
  const auto kernelDigest = fileDigest(request.kernelPath);
  const auto readerDigest = fileDigest(request.readerPath);
  const auto clangDigest = fileDigest(request.clangPath);
  if (!objectDigest || !kernelDigest || !readerDigest || !clangDigest) {
    diag(line("report-failed", "cannot read " +
                                   Twine(!objectDigest   ? request.objectPath
                                         : !kernelDigest ? request.kernelPath
                                         : !readerDigest ? request.readerPath
                                                         : request.clangPath) +
                                   " to digest it"));
    return CoreEmitStatus::Infrastructure;
  }
  const auto clangVersion = firstLine(runTool, tempPath, request.clangPath,
                                      {request.clangPath, "--version"}, "clang-version");
  std::vector<std::string> tripleArgs{request.clangPath};
  tripleArgs.insert(tripleArgs.end(), request.clangArgs.begin(), request.clangArgs.end());
  tripleArgs.push_back("-print-target-triple");
  const auto target =
      firstLine(runTool, tempPath, request.clangPath, tripleArgs, "clang-triple");
  if (!clangVersion || !target) {
    diag(line("report-failed", "cannot ask " + request.clangPath +
                                   " for its version and target triple"));
    return CoreEmitStatus::Infrastructure;
  }

  const LoopBoundResult loops =
      deriveLoopBounds(*prepared.module, admitted, entryFactsFor(c));

  // DECISION 0014: the entry's effects, and each extern's evidence, read once
  // and bound to the configuration. An evidence file is accepted only when its
  // symbol, target and three digests match; otherwise the extern's stack and
  // effects are unknown, with the reason named. Nothing is defaulted.
  EntryEffects effects;
  std::vector<ExternEvidence> evidence;
  if (application) {
    effects = deriveEffects(*prepared.module, admitted, loops, c);
    const std::string contractDir = sys::path::parent_path(request.contractPath).str();
    for (const ExternDecl &e : c.externs)
      evidence.push_back(readExternEvidence(e, contractDir, *target, binding));
  }
  std::map<std::string, uint64_t> attested;
  for (size_t i = 0; i < evidence.size(); ++i)
    if (evidence[i].bound) attested[c.externs[i].symbol] = evidence[i].stackBytes;
  // 0014 §10: the recorder's hooks of a verification build, attested by the
  // build from the recorder unit's measured frames
  if (request.recordCrossFrame >= 0) {
    attested["spc_record_load"] = static_cast<uint64_t>(request.recordCrossFrame);
    attested["spc_record_store"] = static_cast<uint64_t>(request.recordCrossFrame);
  }

  // Decision 0010's stack budget, from the IR the object was generated from.
  // An entry built without that file -- nothing does today, the emission
  // always writes it -- reports the property unevaluated rather than guessing.
  StackBudgetResult stack;
  if (!request.optimisedIrPath.empty())
    stack = deriveStackBudget(request.optimisedIrPath, request.clangPath,
                              request.clangArgs, *target, runTool, tempPath, attested);
  else if (request.admissionOnly)
    stack.refusal = "no object: this is an admission-only report, and the frames "
                    "are measured from the IR an object is generated from";
  const StackVerdict verdict =
      decideStackBudget(request.profile, stack, request.fixtureStack);

  std::string text;
  {
    raw_string_ostream os(text);
    json::OStream J(os, 2);
    auto revision = [&]() -> json::Value {
      return request.revision.empty() ? json::Value(nullptr)
                                      : json::Value(request.revision);
    };
    auto artifact = [&] {
      J.attributeObject("artifact", [&] {
        J.attribute("file", c.rootPath);
        J.attribute("revision", revision());
        J.attribute("sha256", c.rootDigest);
      });
    };
    auto iterations = [&](const std::string &expression) {
      J.attributeObject("value", [&] {
        J.attribute("kind", "iterations");
        J.attribute("expression", expression);
      });
    };
    auto orNull = [](const std::string &s) {
      return s.empty() ? json::Value(nullptr) : json::Value(s);
    };

    // DECISION 0014: whether the extern effects pass. Every extern reached
    // admission declared (the checker refuses otherwise), isr_ok in interrupt
    // context and no cross buffer to an extern (likewise); what remains for
    // the report is that every call count is derived and every extern's
    // evidence is bound to this configuration. Anything less is `unknown`
    // with its reasons, never a pass by default.
    std::vector<std::string> effectReasons;
    for (size_t i = 0; i < c.externs.size(); ++i) {
      const std::string name = c.externs[i].module + "." + c.externs[i].fn;
      if (i < effects.externs.size() && !effects.externs[i].derived)
        effectReasons.push_back(name + ": call count not derived (" +
                                effects.externs[i].reason + ")");
      if (i < evidence.size() && !evidence[i].bound)
        effectReasons.push_back(name + ": " + evidence[i].reason);
    }

    J.object([&] {
      J.attribute("format", "spinel-core-report");
      J.attribute("version", application ? 2 : 1);
      J.attribute("entry", c.entry);
      J.attribute("target", *target);
      J.attribute("profile", request.profile);
      J.attributeObject("inputs", [&] {
        J.attributeObject("contract", [&] {
          J.attribute("file", sys::path::filename(request.contractPath).str());
          J.attribute("sha256", c.contractDigest);
        });
        J.attributeObject("source", [&] {
          J.attribute("file", c.rootPath);
          J.attribute("revision", revision());
          J.attribute("sha256", c.rootDigest);
        });
      });
      if (request.admissionOnly)
        J.attribute("object", nullptr);
      else
        J.attributeObject("object", [&] {
          J.attribute("file", sys::path::filename(request.objectPath).str());
          J.attribute("sha256", *objectDigest);
        });
      if (application) {
        J.attributeObject("application", [&] {
          J.attribute("context", c.context);
          J.attributeArray("buffers", [&] {
            for (const BufferParam &b : c.buffers)
              J.object([&] {
                J.attribute("name", b.name);
                J.attribute("element", elementTypeName(b.element));
                J.attribute("cross", b.cross);
                auto w = effects.bufferWritten.find(b.name);
                J.attribute("written", w != effects.bufferWritten.end() && w->second);
                J.attribute("elements", static_cast<int64_t>(b.constCount.value_or(0)));
              });
          });
          J.attributeArray("externs", [&] {
            for (size_t i = 0; i < c.externs.size(); ++i) {
              const ExternDecl &e = c.externs[i];
              const ExternUse *use = i < effects.externs.size() ? &effects.externs[i] : nullptr;
              const ExternEvidence *ev = i < evidence.size() ? &evidence[i] : nullptr;
              J.object([&] {
                J.attribute("name", e.module + "." + e.fn);
                J.attribute("symbol", e.symbol);
                J.attribute("calls", use && use->derived ? json::Value(use->callsExpr)
                                                         : json::Value(nullptr));
                J.attribute("calls_derived", use && use->derived);
                if (use && !use->derived) J.attribute("calls_reason", orNull(use->reason));
                J.attribute("sites", static_cast<int64_t>(use ? use->sites : 0));
                // The source's call sites of this extern, each with its
                // constant arguments (null where an argument is a buffer or
                // computed). `sites` above counts the loop expansion's
                // occurrences; this array is the source's, one per site.
                J.attributeArray("const_args", [&] {
                  for (const ExternCall &site : admitted.externCalls) {
                    if (site.externIndex != i) continue;
                    J.array([&] {
                      for (const auto &v : site.constArgs)
                        J.value(v ? json::Value(*v) : json::Value(nullptr));
                    });
                  }
                });
                J.attribute("isr_ok", e.isrOk);
                J.attribute("bound", e.bound);
                if (e.boundUnknown) J.attribute("bound_reason", e.boundReason);
                J.attributeArray("guards", [&] {
                  for (const Guard &g : e.guards)
                    J.value(g.lhs + " " + g.op + " " + g.rhs + " else " + g.onFalse);
                });
                J.attributeArray("statics", [&] {
                  for (const StaticRequirement &s : e.statics)
                    J.value(s.lhs + " " + s.op + " " + s.rhs + " else " + s.diagnostic);
                });
                J.attributeObject("stack", [&] {
                  if (ev && ev->bound) {
                    J.attribute("bytes", static_cast<int64_t>(ev->stackBytes));
                    J.attribute("evidence", "attestation");
                    J.attribute("method", ev->stackMethod);
                    J.attributeObject("artifact", [&] {
                      J.attribute("file", ev->file);
                      J.attribute("sha256", ev->sha256);
                    });
                    J.attributeObject("provider_object", [&] {
                      J.attribute("file", ev->objectFile);
                      J.attribute("sha256", ev->objectSha256);
                    });
                  } else {
                    J.attribute("bytes", nullptr);
                    J.attribute("evidence", "unknown");
                    J.attribute("reason", ev ? ev->reason : "no evidence read");
                  }
                });
                J.attributeObject("effects", [&] {
                  if (ev && ev->bound) {
                    J.attribute("isr_ok", ev->isrOk);
                    J.attribute("blocking", ev->blocking);
                    J.attribute("row", orNull(ev->effectsRow));
                    J.attribute("provenance", orNull(ev->provenance));
                  } else {
                    J.attribute("isr_ok", nullptr);
                    J.attribute("blocking", nullptr);
                    J.attribute("reason", ev ? ev->reason : "no evidence read");
                  }
                });
              });
            }
          });
          // DECISION 0041 STAGE 2: the context's data stack, as this entry
          // uses it.
          if (c.scratchBytes)
            J.attributeObject("scratch", [&] {
              J.attribute("bytes", static_cast<int64_t>(*c.scratchBytes));
              J.attribute("elements", admitted.scratchElements);
              J.attributeArray("arrays", [&] {
                for (const auto &a : admitted.arrayMakes)
                  J.object([&] {
                    J.attribute("method", a.method);
                    J.attribute("local", a.local);
                    J.attribute("line", a.line);
                    J.attribute("count", a.count ? json::Value(*a.count) : json::Value(nullptr));
                  });
              });
              J.attribute("worst_bytes", admitted.scratchWorstBytes ? json::Value(*admitted.scratchWorstBytes)
                                                                   : json::Value(nullptr));
              J.attribute("evidence", admitted.arrayMakes.empty() ? "unused"
                                      : admitted.scratchWorstBytes ? "static_proof"
                                                                   : "runtime_guard");
            });
          J.attributeObject("work_bound", [&] {
            J.attribute("expression", orNull(loops.work));
            J.attributeArray("extern_terms", [&] {
              for (const ExternTerm &t : loops.externTerms)
                J.object([&] {
                  J.attribute("extern", c.externs[t.externIndex].module + "." +
                                            c.externs[t.externIndex].fn);
                  J.attributeArray("context", [&] {
                    for (const std::string &step : t.context) J.value(step);
                  });
                  J.attribute("calls", orNull(t.calls));
                  J.attribute("reason", orNull(t.reason));
                  J.attribute("detail", orNull(t.detail));
                });
            });
          });
        });
      }
      J.attributeObject("tools", [&] {
        J.attributeObject("kernel", [&] { J.attribute("sha256", *kernelDigest); });
        J.attributeObject("reader", [&] { J.attribute("sha256", *readerDigest); });
        J.attributeObject("clang", [&] {
          J.attribute("version", *clangVersion);
          J.attribute("sha256", *clangDigest);
        });
      });
      J.attributeObject("properties", [&] {
        for (const PropertyMode &p : kModes) {
          J.attributeObject(p.name, [&] {
            J.attribute("mode", realtime ? p.realtime : p.hostedStage2);
            if (StringRef(p.name) == "stack_budget") {
              // THE DECISION IS NOT MADE HERE. `decideStackBudget` applies the
              // profile to the analysis, and the fixture tool prints the same
              // answer this renders -- one implementation of what 0010's
              // acceptance is about, two ways of showing it.
              const FixtureStackProfile &fx = request.fixtureStack;
              J.attribute("evaluated", verdict.evaluated);
              if (!verdict.evaluated) {
                J.attribute("reason", verdict.reason);
                return;
              }
              J.attribute("verdict", verdict.verdict);
              J.attribute("reason", verdict.reason);
              // A refused admission has a verdict and deliberately no number:
              // the frame it would have counted does not exist.
              if (!verdict.hasNumbers) {
                J.attributeArray("evidence", [&] {
                  J.object([&] {
                    J.attribute("kind", "static_proof");
                    J.attribute("subject", "dynamic stack allocation");
                    J.attribute("method",
                                "a non-static alloca in the IR the object was "
                                "generated from");
                    artifact();
                  });
                });
                return;
              }
              if (fx.given) {
                J.attribute("interrupt_reserve",
                            static_cast<int64_t>(fx.interruptReserve));
                J.attribute("provisioned_stack",
                            static_cast<int64_t>(fx.provisionedStack));
              }
              J.attribute("kernel_stack", static_cast<int64_t>(stack.kernelStack));
              J.attributeObject("call_overhead", [&] {
                J.attribute("bytes", static_cast<int64_t>(stack.callOverhead));
                J.attribute("target", stack.target);
                J.attribute("evidence", stack.overheadEvidence);
              });
              J.attributeArray("evidence", [&] {
                J.object([&] {
                  J.attribute("kind", "measurement");
                  J.attribute("subject", "frame sizes");
                  J.attribute("method",
                              "warn-stack-size=0 on a side compile of the IR "
                              "the object was generated from, with that "
                              "object's codegen line");
                  artifact();
                });
                J.object([&] {
                  J.attribute("kind", "static_proof");
                  J.attribute("subject", "worst path");
                  J.attribute("frame_total", static_cast<int64_t>(stack.frameTotal));
                  J.attribute("call_edges",
                              static_cast<int64_t>(stack.worstPath.empty()
                                                       ? 0
                                                       : stack.worstPath.size() - 1));
                  artifact();
                });
                J.object([&] {
                  J.attribute("kind", "declaration");
                  J.attribute("subject", "per-call stack overhead");
                  J.attribute("detail", stack.overheadEvidence);
                });
                // Arm, Thumb and x86-64: a call frame codegen did not
                // reserve, which the frame-size diagnostic leaves out, added
                // to its frame.
                for (const StackFunction &u : stack.unreserved)
                  J.object([&] {
                    J.attribute("kind", "measurement");
                    J.attribute("subject", "unreserved call frame in " + u.name);
                    J.attribute("bytes", static_cast<int64_t>(u.frameBytes));
                    J.attribute("method",
                                "sp moved by " + std::to_string(u.frameBytes) +
                                    " beyond the reported frame, in the "
                                    "assembly of the same IR and codegen "
                                    "line; added to the function's frame");
                    artifact();
                  });
                // DECISION 0014: a declared callee on the path took its frame
                // from bound evidence. The measurement behind that evidence
                // is the provider's, so what the entry's report holds is the
                // attestation, and it names the artifact it rests on.
                for (const StackFunction &a : stack.attested)
                  J.object([&] {
                    J.attribute("kind", "attestation");
                    J.attribute("subject", "extern " + a.name);
                    J.attribute("bytes", static_cast<int64_t>(a.frameBytes));
                    for (size_t i = 0; i < c.externs.size() && i < evidence.size(); ++i)
                      if (c.externs[i].symbol == a.name && evidence[i].bound)
                        J.attributeObject("artifact", [&] {
                          J.attribute("file", evidence[i].file);
                          J.attribute("sha256", evidence[i].sha256);
                        });
                  });
                // THE ARTIFACT SAYS SO, so that a report built with the proof
                // of concept's numbers cannot be read later as one built
                // against a decided target profile.
                if (fx.given)
                  J.object([&] {
                    J.attribute("kind", "declaration");
                    J.attribute("subject", "provisioned_stack and interrupt_reserve");
                    J.attribute("origin", "fixture");
                    J.attribute("detail",
                                "supplied by --fixture-stack-provision and "
                                "--fixture-interrupt-reserve for decision "
                                "0010's step 2 proof of concept; no target "
                                "profile in this tree declares either, and no "
                                "nesting assumption is attached to this "
                                "reserve");
                  });
              });
              J.attributeArray("worst_path", [&] {
                for (const std::string &fn : stack.worstPath) J.value(fn);
              });
              J.attributeArray("frames", [&] {
                for (const StackFunction &f : stack.functions)
                  J.object([&] {
                    J.attribute("function", f.name);
                    J.attribute("bytes", f.frameKnown
                                             ? json::Value(static_cast<int64_t>(f.frameBytes))
                                             : json::Value(nullptr));
                  });
              });
              return;
            }
            if (StringRef(p.name) == "extern_effects" && application) {
              J.attribute("evaluated", true);
              J.attribute("verdict", effectReasons.empty() ? "pass" : "unknown");
              J.attributeArray("reasons", [&] {
                for (const std::string &r : effectReasons) J.value(r);
              });
              J.attributeArray("evidence", [&] {
                for (size_t i = 0; i < c.externs.size() && i < evidence.size(); ++i) {
                  if (!evidence[i].bound) continue;
                  J.object([&] {
                    J.attribute("kind", "attestation");
                    J.attribute("subject", "extern " + c.externs[i].module + "." + c.externs[i].fn);
                    J.attributeObject("artifact", [&] {
                      J.attribute("file", evidence[i].file);
                      J.attribute("sha256", evidence[i].sha256);
                    });
                  });
                }
              });
              return;
            }
            if (StringRef(p.name) != "loop_bound") {
              J.attribute("evaluated", false);
              return;
            }
            J.attribute("evaluated", true);
            // DECISION 0021 (owner, 2026-10-20): an extern the entry calls
            // that declares `bound iterations unknown` leaves the entry's
            // work unbounded however its own loops derive; each is named
            // with its reason.
            std::vector<size_t> unknownExterns;
            for (size_t i = 0; i < c.externs.size(); ++i)
              if (c.externs[i].boundUnknown && i < effects.externs.size() &&
                  effects.externs[i].sites > 0)
                unknownExterns.push_back(i);
            const bool workBounded = loops.workKnown && unknownExterns.empty();
            J.attribute("verdict", workBounded ? "pass" : "unknown");
            // Written only when there is one, so a report with none is the
            // report it was before decision 0021.
            if (!unknownExterns.empty())
              J.attributeArray("unknown_externs", [&] {
                for (size_t i : unknownExterns)
                  J.object([&] {
                    J.attribute("extern", c.externs[i].module + "." + c.externs[i].fn);
                    J.attribute("reason", c.externs[i].boundReason);
                  });
              });
            J.attributeArray("evidence", [&] {
              if (!workBounded) return;
              J.object([&] {
                J.attribute("kind", "static_proof");
                J.attribute("subject", "work " + c.entry);
                iterations(loops.work);
                artifact();
              });
            });
            J.attributeObject("work_bound", [&] {
              J.attribute("expression", orNull(loops.work));
              J.attribute("limit", orNull(loops.limit));
              J.attributeArray("terms", [&] {
                for (const WorkTerm &t : loops.terms)
                  J.object([&] {
                    J.attribute("loop", t.loop);
                    J.attributeArray("context", [&] {
                      for (const std::string &step : t.context) J.value(step);
                    });
                    J.attribute("iterations", orNull(t.iterations));
                    J.attribute("reason", orNull(t.reason));
                    J.attribute("detail", orNull(t.detail));
                  });
              });
            });
            J.attributeArray("loops", [&] {
              for (const LoopFinding &l : loops.loops)
                J.object([&] {
                  J.attribute("id", l.id);
                  J.attribute("method", l.method);
                  J.attribute("ordinal", static_cast<int64_t>(l.ordinal));
                  J.attribute("digest", l.digest);
                  J.attribute("digest_version", static_cast<int64_t>(kLoopDigestVersion));
                  J.attribute("label", nullptr);
                  J.attribute("header", l.header);
                  J.attribute("location", c.rootPath + ":" + std::to_string(l.line) +
                                              ":" + std::to_string(l.column));
                  J.attribute("parent", orNull(l.parent));
                  J.attribute("verdict", l.pass ? "pass" : "unknown");
                  J.attribute("reason", orNull(l.reason));
                  J.attribute("detail", orNull(l.detail));
                  if (l.conjunct)
                    J.attributeObject("conjunct", [&] {
                      J.attribute("index", static_cast<int64_t>(l.conjunct->index));
                      J.attribute("rendering", l.conjunct->rendering);
                    });
                  else
                    J.attribute("conjunct", nullptr);
                  J.attributeArray("evidence", [&] {
                    if (!l.pass) return;
                    J.object([&] {
                      J.attribute("kind", "static_proof");
                      J.attribute("subject", "loop " + l.id);
                      iterations(l.bound);
                      artifact();
                    });
                  });
                });
            });
          });
        }
      });
    });
    os << "\n";
  }

  // Through a temporary name and a rename, so a reader never sees half a
  // report and a failed write leaves no file that looks like one.
  const std::string partial = request.path + ".partial";
  {
    std::error_code ec;
    raw_fd_ostream out(partial, ec, sys::fs::OF_Text);
    if (ec) {
      diag(line("report-failed", "cannot write " + partial + ": " + ec.message()));
      return CoreEmitStatus::Infrastructure;
    }
    out << text;
    out.close();
    if (out.has_error()) {
      diag(line("report-failed", "cannot write " + partial + ": " +
                                     out.error().message()));
      sys::fs::remove(partial);
      return CoreEmitStatus::Infrastructure;
    }
  }
  if (auto ec = sys::fs::rename(partial, request.path)) {
    diag(line("report-failed", "cannot rename " + partial + " to " + request.path +
                                   ": " + ec.message()));
    sys::fs::remove(partial);
    return CoreEmitStatus::Infrastructure;
  }
  return CoreEmitStatus::Ok;
}

} // namespace spinel_mlir::core
