#include "spinel/Conversion/GroupGProbe.h"
#include "spinel/Conversion/GroupGRuntime.h"
namespace spinel::consumer {
void registerGroupGSocket(Registry &);
void registerGroupGKernel(Registry &);
void registerGroupG(Registry &registry) {
  registerGroupGRuntime(registry);
  registerGroupGProbe(registry);
  registerGroupGSocket(registry);
  registerGroupGKernel(registry);
}
} // namespace spinel::consumer
