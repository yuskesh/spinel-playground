#!/bin/sh
# tests/npu/stm32mp2/board.sh DIR -- run on the board. DIR holds app,
# nodelegate.so, onenode.so and the TFLite, delegate and TIM-VX libraries. Capture stdout and
# stderr together; tests/npu/stm32mp2/run.rb reads the capture.
cd "$1" || exit 2
LD_LIBRARY_PATH=$PWD:/vendor/lib
export LD_LIBRARY_PATH
echo "=== run"
./app 2>&1; echo "rc=$?"
echo "=== missing"
SPINEL_NPU_DELEGATE=$PWD/no-such-delegate.so ./app 2>&1; echo "rc=$?"
echo "=== nodelegate"
SPINEL_NPU_DELEGATE=$PWD/nodelegate.so ./app 2>&1; echo "rc=$?"
echo "=== onenode"
SPINEL_NPU_DELEGATE=$PWD/onenode.so ./app 2>&1; echo "rc=$?"
