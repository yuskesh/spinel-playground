#pragma once
#include "spinel/Analysis/RecordLayout.h"
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
// The caller supplies the index in the used-record sequence, not its declaration
// index. The closure owns the layout and never borrows Consumer or facts nodes.
ExportFields recordExport(std::shared_ptr<const record::Layout> layout,
                          size_t usedIndex, bool schema);
}
