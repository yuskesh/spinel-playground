# Architecture direction

This document records the agreed project direction. Detailed APIs, memory semantics, and implementation choices remain proposals until explicitly decided and validated.

## Responsibility

Produce usable artifacts from Ruby source for a selected execution environment, including analysis, boundary checks, compilation, runtime integration, and reproducible validation.

Spinel supplies the language frontend and type analysis. LLVM, MLIR, IREE, and libbpf are potential implementation dependencies for relevant capabilities; these backend dependencies are not installed by this repository. Spinel is pinned under `vendor/spinel` as a Git submodule. The project owns the contracts and integration between its components rather than reimplementing those upstream systems.

## Boundaries

| Component | Responsibility | Boundary to preserve |
|---|---|---|
| Frontend support | Obtain source structure, inferred types, and source identity | A coherent analysis snapshot with explicit ownership |
| Lane compiler | Interpret declarations, select code, and check lane semantics | A validated program and explicit ABI |
| Transformations | Apply optimizations or differentiation where valid | Numeric, allocation, and failure semantics |
| Artifact generation | Emit target code and required metadata | Target, ABI, and artifact compatibility |
| Runtime integration | Link, load, attach, invoke, and release resources | Lifetime and platform-specific behavior |
| Product driver | Run the required steps in order | Reproducible inputs and a complete artifact set |
| Validation | Check behavior and contracts | Independent evidence and explicit coverage |

These are logical responsibilities, not a requirement to create a directory or framework for every row.

## Memory tiers

The initial separation is between `core` and `full`.

| Tier | Intended contract | Status |
|---|---|---|
| `core` | No dynamic allocation and no Spinel runtime or GC dependency; explicit boundary types and external functions | Connected to `full` on Debian x86_64 and macOS arm64, using the pinned compiler: a CLI-selected method of an ordinary Ruby program becomes an object with no undefined symbols, and the hosted program calls it. Also reachable the older way, as a declared function callable from C. The product driver checks the object before linking |
| `full` | Hosted Spinel behavior with its runtime and GC | Pinned hosted compiler links the checked core object |
| `arena` | Allocation with an explicit lifetime and bulk reclamation, without GC for those allocations | Deferred. Not to be confused with the implemented **process-lifetime** arena, which reclaims nothing until exit and refuses GC operations and threads; that one is a build-time choice, not a scoped lifetime |

Tier is not a target name. A core object can potentially target a native host, WASM, or an MCU. Actual supported combinations must be implemented and tested individually.

GC inactivity is weaker than GC independence. A function can avoid allocation while still borrowing GC-managed objects. Such a function must not be classified as standalone core merely because no collection occurs during its execution.

Platform availability is another axis. A core function may call an explicitly declared external function, but that call must have a defined effect and ABI contract. Unknown external behavior must not silently count as allocation-free.

## First end-to-end slice

The first slice runs entirely on a native host:

1. Build an ordinary hosted Ruby program with a pinned Spinel dependency.
2. Compile a selected allocation-free function into a standalone core object.
3. Verify the function and reachable dependencies against the core contract.
4. Link the hosted program with the core object through a checked ABI.

Implemented on Debian and macOS as six stages that each refuse rather than continue:
snapshot, eligibility, hosted half, core half, artifact gate, link. The symbol
is not derived twice — the compiler writes one mapping and the hosted
declaration, the hosted call and the core definition are all generated from it.
The ABI it agrees on is **internal**: a symbol name, parameter list, return type
and calling convention for one target, regenerated per build. No public numeric
interface is added, but an interface is created, and a boundary the two halves
disagreed about linked silently until the prototype was checked against what the
core path can define.
5. Compare behavior with the reference and reject invalid boundary usage.

Scalar values were the first boundary candidate. The explicit buffer boundary that follows them is now decided and implemented for the stage-1 subset: [decision 0007](decisions/0007-doom-core-preparation.md) fixes borrowed buffers with a named per-buffer element count, an explicit `in`/`inout` mode, overlap rules that refuse any aliasing involving a written buffer, and a five-value status ABI in place of a trap. Full owns the storage and core borrows it for the call; this document still does not authorize passing Ruby object pointers into core code.

The detailed design must decide numeric behavior, failure behavior, declaration syntax, external-function effects, and the compiler/runtime split before implementation changes those contracts.

## Later integration

Tensor, graphics, raster jobs, WASM, differentiation, and eBPF have different execution models. They may share frontend information and build infrastructure without sharing one universal intermediate representation or runtime ABI.

Retain the ordinary C-based hosted path. Introduce MLIR where its transformations, validation, or multiple lowering routes provide demonstrated value. Do not require all backends to use MLIR for visual consistency.

The predecessor projects remain migration references. Their implementations and tests are imported selectively. The new project must not require their checkouts or private experiment archives to build and validate an accepted capability.

## Public repository shape

Keep the maintained repository small and self-contained: product code, necessary dependencies and notices, executable tests, essential fixtures, minimal examples, and current documentation. Do not copy experimental history into the product tree.

Important design reasons and provenance must survive the migration. Historical logs are not needed for daily development, but a contributor must be able to understand the contract and reproduce its validation from this repository.
