#pragma once
#include "spinel/Conversion/Consumer.h"
namespace spinel::consumer {
LogicalResult prepareSubprograms(Consumer &, ArrayRef<Operation *> top,
                                ArrayRef<Operation *> rootEntries);
LogicalResult collectSubprogramMaps(Consumer &, Operation *rootDef);
LogicalResult analyzeSubprograms(Consumer &, ModuleOp staging);
LogicalResult noteSubprogramWrite(Consumer &, Operation *write,
                                 ReadOrigin destination,
                                 ArrayRef<ReadOrigin> reads);
void registerSubprograms(Registry &);
bool isSubprogramCall(Consumer &, Operation *);
// Source-only loop check, before speculative range transfer.
LogicalResult checkSubprogramLoopCall(Consumer &, Operation *);
LogicalResult prepareSubprogramSemantics(Consumer &);
void prepareSubprogramRecovery(Consumer &, Operation *statements);
bool skipRejectedSubprogramStatement(Consumer &, Operation *);
} // namespace spinel::consumer
