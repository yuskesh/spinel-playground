//===- Report.h - the per-entry, per-target CORE build report ----*- C++ -*-===//
//
// Decision 0010. One versioned JSON document per entry and target, holding the
// profile, each property's mode, and each evaluated property's verdict and
// evidence. The schema is tools/mlir/native/schema/core-report-v1.schema.json
// and docs/core/core-report.md describes it.
//
// Step 1 evaluates the loop bound property only. Every other property is
// written with its mode and `evaluated: false`, and carries no verdict: a
// verdict without the evidence that decided it would be a claim this report
// does not make.
//
// Writing a report changes nothing about the object. It is produced after the
// object exists, from the admitted eligibility report and the analysed source,
// and reads the object only to digest it.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_REPORT_H
#define SPINEL_MLIR_CORE_REPORT_H

#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Eligibility.h"
#include "spinel-mlir/Core/Emit.h"
#include "spinel-mlir/Core/Profile.h"
#include "spinel-mlir/Core/StackBudget.h"

#include <cstdint>
#include <string>
#include <vector>

namespace spinel_mlir::core {

struct CoreReportRequest {
  std::string path;          ///< the report to write
  std::string profile;       ///< kHostedStage2Profile or kRealtimeProfile
  std::string revision;      ///< the source revision, or empty for null
  std::string contractPath;  ///< its file name is recorded
  std::string objectPath;    ///< digested; its file name is recorded
  std::string readerPath;    ///< the contract reader, digested
  std::string kernelPath;    ///< this executable, digested
  std::string clangPath;
  std::vector<std::string> clangArgs;  ///< the caller's, for the target triple
  /// The IR code generation consumed -- what the object was generated from,
  /// left by the two-step emission. Decision 0010 requires the final call
  /// graph to come from it, and the frame sizes are measured from the same
  /// file so that the graph and the sizes cannot describe different programs.
  std::string optimisedIrPath;
  FixtureStackProfile fixtureStack;
  /// Decision 0014 (version 2 contracts): the configuration the extern
  /// evidence must be bound to, `<dts>:<config>:<flags>` as three sha256
  /// digests, from `--config-binding`. Required for a version 2 report; an
  /// evidence file is accepted only if its three digests, its target and its
  /// symbol match, and otherwise the extern's stack and effects are unknown.
  std::string configBinding;
  /// Decision 0014: an admission-only report, written by `--admit-only`
  /// before a version 2 entry can be lowered (Task 5). It carries no object:
  /// `object` is null and the properties that read one are unevaluated.
  bool admissionOnly = false;
  /// Decision 0014 §10: in a verification build the entry calls the recorder's
  /// two hooks (spc_record_load / spc_record_store) in place of its
  /// cross-context accesses. Their frame, measured by the build from the
  /// recorder unit's .su, is attested here; negative means no hooks.
  long recordCrossFrame = -1;
};

CoreEmitStatus writeCoreReport(const PreparedBoundary &prepared,
                               const EligibilityReport &admitted,
                               const CoreReportRequest &request,
                               RunToolFn runTool, TempPathFn tempPath,
                               CoreDiagnosticFn diag);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_REPORT_H
