#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
// Shared runtime scalars: register once from Group G's aggregate registration.
void registerGroupGRuntime(Registry &);
}
