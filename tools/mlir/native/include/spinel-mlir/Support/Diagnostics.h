// Register with MLIRContext's DiagnosticEngine and route every diagnostic to
// one callback. Its severity-int/message-string shape matches the C ABI
// SpMlirDiagnosticCallback, so CAPI wraps it without exposing MLIR types.
#ifndef SPINEL_MLIR_SUPPORT_DIAGNOSTICS_H
#define SPINEL_MLIR_SUPPORT_DIAGNOSTICS_H

#include "mlir/IR/Diagnostics.h"
#include "mlir/IR/MLIRContext.h"

#include <functional>
#include <string>

namespace spinel_mlir {

// Map mlir::DiagnosticSeverity to C ABI SpMlirSeverity values.
int toCSeverity(mlir::DiagnosticSeverity severity);

// One string: <location>: <message>, followed by notes separated by newlines.
using DiagnosticFn = std::function<void(int severity, const std::string &message)>;

// RAII (resource acquisition is initialization): while alive, sends every context diagnostic to fn
// rather than the default handler.
class DiagnosticSink {
public:
  DiagnosticSink(mlir::MLIRContext &ctx, DiagnosticFn fn);
  ~DiagnosticSink();
  DiagnosticSink(const DiagnosticSink &) = delete;
  DiagnosticSink &operator=(const DiagnosticSink &) = delete;

private:
  mlir::MLIRContext &ctx_;
  mlir::DiagnosticEngine::HandlerID id_;
};

} // namespace spinel_mlir

#endif // SPINEL_MLIR_SUPPORT_DIAGNOSTICS_H
