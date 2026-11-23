# This was the first add_mlir_dialect use on both hosts; earlier checks invoked
# mlir-tblgen directly. Build issues were recorded in the failure ledger.
# Root: SpBPFOps.td; outputs SpBPFOps{,Types,Dialect}.{h,cpp}.inc;
# target: MLIRSpBPFOpsIncGen.
add_mlir_dialect(SpBPFOps spbpf)
