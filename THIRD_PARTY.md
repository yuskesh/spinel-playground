# Third-party code and licences

Generated from [`docs/imports.tsv`](docs/imports.tsv) and the files' SPDX lines by
`tools/provenance/third-party.rb`; do not edit by hand.

The project's own licence is Apache-2.0 WITH LLVM-exception: see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). It covers every file except
those listed in sections 1 and 2, which keep the licence named here.
Section 3 lists files the project licence covers although they were
ported from elsewhere.

## 1. Third-party files

Each directory or file keeps its original licence; the licence text sits
beside it or in a directory above it.

| files | licence | licence text | note |
| --- | --- | --- | --- |
| `vendor/spinel` | MIT | (in the linked repository) | a submodule entry; the pinned tree keeps its own notices |
| `vendor/spinel-modular` | Apache-2.0 | (in the linked repository) | a submodule entry (Apache-2.0 WITH LLVM-exception); the pinned tree keeps its own notices |
| `tools/contract/spinel_contract.h` | project-ported+MIT | `tools/contract/LICENSE.spinel` | reproduces two Spinel functions (MIT, Yukihiro Matsumoto): slc_file_path mirrors emit_file_path and slc_ty_tag reproduces ty_tag_into (src/codegen.c); their notice is LICENSE.spinel beside it |
| `tools/contract/LICENSE.spinel` | MIT | `tools/contract/LICENSE.spinel` | Spinel's LICENSE at 4e0a59bd999e, byte for byte |
| `tools/npu/host/shim/**/*` | MIT+project | `tools/npu/host/shim/LICENSE.spinel` | headers from vendor/spinel lib/wasi (the pinned upstream, MIT), with additions written here; LICENSE.spinel is Spinel's LICENSE at 4e0a59bd999e, byte for byte |
| `examples/ghostty-terminal/keys.rb` | MIT | `examples/ghostty-terminal/LICENSE.ghostty` | generated here from Ghostty's key header (docs/provenance.md); its notice is LICENSE.ghostty |
| `examples/spinel-vi/vendor/termbox2/**/*` | MIT | `examples/spinel-vi/vendor/termbox2/LICENSE` | termbox developers |
| `examples/spinel-vi/vendor/libgrapheme/data/**/*` | Unicode-3.0 | `examples/spinel-vi/vendor/libgrapheme/data/LICENSE` |  |
| `examples/spinel-vi/vendor/libgrapheme/{*,gen/**/*,src/**/*}` | ISC | `examples/spinel-vi/vendor/libgrapheme/LICENSE` | SNAPSHOT.md translated to English here (D1) |
| `tools/spinel-bpf-mlir/{.gitignore,go.mod,go.sum,LICENSE,NOTICE,{examples,internal,packaging,ruby,scripts}/**/*,cmd/spinelbpf/*,cmd/spinelbpf/testdata/*,cmd/spinelbpf/testdata/[!b]*/**/*,cmd/spinelbpf/testdata/bpfmlir/PROVENANCE}` | Apache-2.0 | `tools/spinel-bpf-mlir/LICENSE` | Apache-2.0 WITH LLVM-exception (LICENSE, NOTICE from the public v0.9.0, unchanged in v0.9.1); spinel-bpf-mlir v0.7.0 (04eee01), updated to main 4b936d5 (E152), to v0.8.0 (1ffc979), to main 9b914a8 (E160, E161 and its addendum), to main cf77cec (E161's addendum 2), to main 8b20ffa (its addendum 3), to main 7af1fd4 (E162, E163: English documents and messages) to main e14acc0 (E164: bml d879745) to c56a4915, the source_commit of the public v0.9.0 (GitHub yuskesh/spinel-bpf-mlir, commit 698e6319), and to 0e83966a, that of v0.9.1 (commit 511781de); generated example outputs not imported; examples/bcc/PROVENANCE.md has a one-line note added here |
| `tools/spinel-bpf-mlir/cmd/spinelbpf/testdata/bpfmlir/{m1fit_c5_end,nonroot_idx}/*` | Apache-2.0 | `tools/spinel-bpf-mlir/LICENSE` | bpf-mlir's test inputs, copied unchanged by spinel-bpf-mlir (E161's addendum 2); bpf-mlir is Apache-2.0 WITH LLVM-exception (its LICENSE and NOTICE), and the copy's PROVENANCE names the source paths and blobs |
| `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/{.gitignore,LICENSE,NOTICE,{cmd,include,scripts,shim,src,test}/**/*}` | Apache-2.0 | `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSE` | Apache-2.0 WITH LLVM-exception (LICENSE, NOTICE from the public bpf-mlir-loader v0.1.0); bml 295df2a, updated to a6da571, to fae2194, to d879745 (E059: English user-facing texts) and to 41ec56f1, the source_commit of the public v0.1.0 (https://github.com/yuskesh/bpf-mlir-loader, commit 0e72c24f), as source; its submodules are user-local |
| `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/libbpf.{BSD-2-Clause,LGPL-2.1,LICENSE}` | BSD-2-Clause+LGPL-2.1 | `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/libbpf.BSD-2-Clause`, `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/libbpf.LGPL-2.1`, `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/libbpf.LICENSE` | the licence texts of libbpf (LGPL-2.1 OR BSD-2-Clause), from the public bpf-mlir-loader v0.1.0; libbpf is linked, not vendored |
| `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/elfutils-libelf.*` | GPL-2.0+GPL-3.0+LGPL-3.0 | `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/elfutils-libelf.GPL-2.0`, `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/elfutils-libelf.GPL-3.0`, `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/elfutils-libelf.LGPL-3.0` | the licence texts of elfutils libelf (GPL-2.0-or-later OR LGPL-3.0-or-later; GPL-3.0 accompanies LGPL-3.0), from the public bpf-mlir-loader v0.1.0; libelf is linked, not vendored |
| `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/zlib.LICENSE` | zlib | `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/LICENSES/zlib.LICENSE` | the licence text of zlib, from the public bpf-mlir-loader v0.1.0; zlib is linked, not vendored |
| `examples/doom/{lib/**/*,bin/{bench_tic,doom,dump_jobs,dump_ppm,gpu_demo,gpu_reject,record_demo,sim_demo}.rb}` | GPL-2.0 | `examples/doom/LICENSE` |  |
| `examples/doom/LICENSE` | GPL-2.0 | `examples/doom/LICENSE` | doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte: spinel-llvm's Ruby DOOM followed doomgeneric at that commit (its R007 survey: the port's baseline is doomgeneric, not linuxdoom) and carried no licence file of its own; replaced the FSF text on 2026-11-16 |
| `examples/doom/{README.md,build.sh,bin/frame_ppm.rb,native/**/*}` | GPL-2.0 | `examples/doom/LICENSE` | written here inside the GPL-2.0 scope of examples/doom/NOTICE.md, with the code they derive from or drive; GPL-2.0 at publication (2026-11-20) |
| `examples/doom/core/src/**/*` | GPL-2.0 | `examples/doom/LICENSE` | written here, derived from examples/doom (examples/doom/core/NOTICE.md) |
| `examples/doom/core/{README.md,sources.tsv,*.tsv,board/**/*,entries/**/*,full/**/*,knot/**/*}` | GPL-2.0 | `examples/doom/LICENSE` | written here inside the GPL-2.0 scope of examples/doom/NOTICE.md, with the code they derive from or drive; GPL-2.0 at publication (2026-11-20) |
| `tests/doom/cases/**/*` | GPL-2.0 | `tests/doom/cases/LICENSE` | LICENSE is doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte, the same bytes as examples/doom/LICENSE |
| `tests/doom/fixtures/reference/**/*` | GPL-2.0 | `tests/doom/fixtures/reference/LICENSE` | the reference build's golden hashes: FNV-1a and SHA-256 of frames doomgeneric rendered from the shareware doom1.wad; hashes only, no WAD-derived content is shipped (owner, 2026-11-16); LICENSE is doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte |
| `tests/doom/reference/patches/**/*` | GPL-2.0 | `tests/doom/reference/LICENSE` |  |
| `tests/doom/reference/LICENSE` | GPL-2.0 | `tests/doom/reference/LICENSE` | doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte, the tree the patches apply to; replaced the FSF text on 2026-11-16 |
| `tests/core-boundary/fixtures/{capabilities,framebuffer,slots}/src/**/*` | GPL-2.0 | `tests/core-boundary/fixtures/LICENSE` |  |
| `tests/core-boundary/fixtures/LICENSE` | GPL-2.0 | `tests/core-boundary/fixtures/LICENSE` | doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte, the same bytes as examples/doom/LICENSE, whose files the extractions copy |
| `tests/doom-core/fixtures/source/src/**/*` | GPL-2.0 | `tests/doom-core/fixtures/source/src/LICENSE` | a copy of examples/doom/core/src/source.rb's dc_draw_column; LICENSE is doomgeneric's LICENSE at dcb7a8dbc7a1, byte for byte, the same bytes as examples/doom/LICENSE |
| `tests/doom-core/fork/fixtures/{*.rb,*.expected}` | MIT | `tests/doom-core/fork/fixtures/LICENSE.spinel` |  |
| `tests/doom-core/fork/fixtures/LICENSE.spinel` | MIT | `tests/doom-core/fork/fixtures/LICENSE.spinel` | the fork's LICENSE at ecbd0f2a7cd1, byte for byte (the full text NOTICE.md quotes) |
| `tests/app/fixtures/dts/{mps2_an521,frdm_mcxn947,frdm_imxrt1186,frdm_imxrt1186_cm7}/*` | Apache-2.0 | `tests/app/fixtures/dts/LICENSE.zephyr` | generated from Zephyr's devicetree sources; their licence text is LICENSE.zephyr |
| `tests/app/fixtures/dts/LICENSE.zephyr` | Apache-2.0 | `tests/app/fixtures/dts/LICENSE.zephyr` | Zephyr's LICENSE at dccb09599635, byte for byte |

## 2. This project's files with a per-file licence

These files are the project's own and state their licence in an
`SPDX-License-Identifier` line; the text is in the `LICENSES/` named. That
licence is settled: section 3 does not reopen it, though the same globs
appear there.

| licence | directory | licence text |
| --- | --- | --- |
| Apache-2.0 | `tools/ebpf` | `tools/ebpf/LICENSES/Apache-2.0` |
| GPL-2.0 | `tools/ebpf` | `tools/ebpf/LICENSES/GPL-2.0` |

## 3. Ported from the owner's earlier repositories

These came from the project owner's earlier repositories, which stated no
licence. The owner put them under the project licence on 2026-11-20, except
for the files with an SPDX line, which keep it and which section 2 lists.

| files | note |
| --- | --- |
| `third_party/spinel-mlir/SPINEL_MLIR_PATCHES.md` | verbatim from spinel-mlir 4624b901: E083's English text of f96ac6d's (3accdcd's text with M4's entry); spinel-mlir states no licence, and the owner put this copy under the project licence (2026-11-20) |
| `third_party/spinel-mlir/spinel_facts.md` | from spinel-mlir 4624b901 with one local change (one call-sign replaced by its role, 2026-11-16; docs/provenance.md): E083's English text of f96ac6d's (3accdcd's text with E076's and the typing probe's (E078, E079) sections); spinel-mlir states no licence, and the owner put this copy under the project licence (2026-11-20) |
| `tools/contract/spinel_contract.h` | reproduces two Spinel functions (MIT, Yukihiro Matsumoto): slc_file_path mirrors emit_file_path and slc_ty_tag reproduces ty_tag_into (src/codegen.c); their notice is LICENSE.spinel beside it |
| `tools/contract/{build.sh,README.md,spinel_typedump.c}` |  |
| `tools/freestanding/spinel/**/*` |  |
| `tools/freestanding/profiles/{cortex-m33-zephyr,riscv32-zephyr,wasm32-worker,workers-wasm32,zephyr-cortex-m33,zephyr-riscv32}.yaml` |  |
| `tools/realtime/alloc_vocabulary.tsv` |  |
| `tools/realtime/{README.md,spinel-rtcheck,test/**/*,ab/**/*}` | README.md translated here from the source's Japanese one |
| `tools/mlir/native/{CMakeLists.txt,build.sh,cmake/**/*}` | build.sh rewritten here (provenance: local change 5) |
| `tools/mlir/native/include/spinel-mlir/{Contract,Conversion,Dialect,Scalar,Target}/**/*` |  |
| `tools/mlir/native/include/spinel-mlir/Freestanding/{Declaration,Diagnostics,Emit,PlatformLedger,Profile,UndefGate}.h` |  |
| `tools/mlir/native/include/spinel-mlir/Freestanding/{GradDeclaration,GradPipeline,GradShim}.h` |  |
| `tools/mlir/native/include/spinel-mlir/Support/Diagnostics.h` |  |
| `tools/mlir/native/include/spinel-mlir/{Passes.h,Realtime/**/*}` |  |
| `tools/mlir/native/include/spinel-mlir-c/**/*` |  |
| `tools/mlir/native/lib/{CMakeLists.txt,Contract/**/*,Conversion/**/*,Dialect/**/*,Frontend/**/*}` |  |
| `tools/mlir/native/lib/Freestanding/{CMakeLists.txt,Declaration.cpp,Diagnostics.cpp,Emit.cpp,PlatformLedger.cpp,ProfileReader.cpp,ProfileYaml.h,UndefGate.cpp}` |  |
| `tools/mlir/native/lib/Freestanding/{GradDeclaration,GradPipeline,GradShim}.cpp` |  |
| `tools/mlir/native/lib/Realtime/**/*` |  |
| `tools/mlir/native/lib/Tensor/**/*` |  |
| `tools/mlir/native/lib/{Target,CAPI}/**/*` |  |
| `tools/mlir/native/lib/Core/SubsetRefusals.cpp` | the imported subset table's entries, moved here from lib/Frontend/Scalar/SubsetTables.cpp by decision 0026 step 5 and rewritten into this form |
| `tools/mlir/native/tools/{CMakeLists.txt,spinel-fs-emit/**/*,spinel-fs-check/**/*}` |  |
| `tools/mlir/native/tools/spinel-fs-grad/**/*` |  |
| `tools/mlir/native/tools/spinel-rtcheck/**/*` |  |
| `tools/mlir/native/tools/spinel-tensor-import/**/*` |  |
| `tools/mlir/native/tools/{spbpf-compile,spbpf-opt,spinel-mlir-capi-smoke}/**/*` |  |
| `tools/mlir/native/{test,unittests}/**/*` |  |
| `tools/platform/{arena.yaml,menus.yaml,profiles/**/*,spinel-capcheck,spinel_platform.rb,ab/**/*}` |  |
| `tools/platform/README.md` | translated here from the source's Japanese README |
| `tools/wasm/{.gitignore,README.md,fix_bigint.h,raise_stubs.c,reactor.c,shim_flockfile.h,spinel_host.mjs,spinel-wasm,sp_wasm_host.c,stubs.c,wasi_shim.mjs,worker.mjs,fastly/**/*,legacy/**/*,lib/**/*,shim/**/*,worker-template/**/*}` | the READMEs translated here from the source's Japanese ones |
| `examples/{hello-http,fetch-kv,r2-d1,hello-fastly,gatekeeper,edge-twin,tools}/**/*` | the READMEs translated here from the source's Japanese ones |
| `tools/tensor/{sp_tensor_shim.c,spinel/**/*}` |  |
| `tools/tensor/README.md` | translated here from the source's Japanese README |
| `examples/{tensor,image}/**/*` | the READMEs translated here from the source's Japanese ones |
| `tools/census/**/*` | README.md translated here from the source's Japanese one |
| `tools/grad/**/*` | README.md translated here from the source's Japanese one |
| `tools/llvm/passes/**/*` | README.md translated here from the source's Japanese one |
| `tests/grad/{e076,e082}/**/*` |  |
| `tests/freestanding/e040/{build_all.sh,e040_kern.rb,mkcases.rb,oracle/**/*,run_gates.sh,run_reject.sh,zephyr/**/*}` |  |
| `tests/freestanding/{e063,e077,e081,profiles}/**/*` |  |
| `tests/freestanding/e083/**/*` |  |
| `tests/freestanding/{e079,e084}/**/*` |  |
| `tools/raster/{*.c,*.h,*.rb,spinel-*,ab/**/*}` |  |
| `tools/gcmon/{gcmon_contract.h,gcmon_probe.c,gcmon_stub.rb,malloc_count.c,spinel-gcmon,run_gcmon_gate.sh}` |  |
| `tools/gcmon/README.md` | README.md rewritten here |
| `tests/gcmon/{probe_noninvasive,probe_properties}.rb` |  |
| `tools/shader/{draw.c,draw_metal.m,run_shader_gate.sh,spinel-rb2spv,spinel-shader-attrib,spinel-shader-cmp,spinel-shader-vcmp,golden/**/*,test/**/*}` |  |
| `tools/llvm/{spinel-llvm,cc-lto-shim,build_rt_bc.sh}` |  |
| `examples/spinel-vi/{app.rb,build-editor.sh,build-probe.sh,build.sh,editor.rb,.gitignore,run-editor.sh,run-probe.sh,run.sh,lib/**/*,probes/**/*,shim/**/*,test/**/*}` |  |
| `examples/mvc-blog/{app.rb,build.sh,.gitignore,VALIDATION.md,wrangler.toml,app/**/*,framework/**/*,native/**/*}` | VALIDATION.md translated to English here, except its measured data lines (D1) |
| `examples/ebpf-go/**/*` | the READMEs rewritten here, replacing the source's; user-facing messages in main.go translated to English here (D2) |
| `tools/ebpf/go/**/*` | user-facing messages translated to English here (D2) |
| `tools/ebpf/{*,{benchmarks,bin,examples,include,profiles,scripts,src,tools}/**/*,tests/{codegen_c,fixtures,golden,spinel_ebpf}/**/*,tests/runtime/{[!m]*,mock_cuda.c}}` | README.md rewritten here (it lists the local changes); the 19 Japanese Markdown documents translated to English here (D1); user-facing messages translated to English here (D2) |
| `tools/metal/{examples/**/*,tests/*}` | moved from tools/ebpf/{examples/gpu,tests/runtime}, with paths and command names updated; user-facing messages translated to English here (D2) |
| `tools/spinel-mlir/{.gitignore,CMakeLists.txt,{cmake,include,lib,tools,tests,test,scripts}/**/*}` | spinel-mlir 7db284d, updated to f96ac6d, to c86ce1ae (E082: neutral fixture source paths) and to a8abbdc3 (E084: bpf-mlir v1.21.0): the consumer, its tests and scripts; the lit configuration and 10 experiment scripts not imported |
