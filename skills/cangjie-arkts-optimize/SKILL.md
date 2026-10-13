---
name: cangjie-arkts-optimize
description: "Find and apply performance optimizations at a Cangjie and ArkTS interop boundary using ohos.ark_interop. Use for repeated property paths, string conversions, persistent temporaries, immediate waits, and short posted tasks, or for adapting these interop benchmark patterns to another codebase."
---

# Optimize Cangjie and ArkTS interop

Find the applicable patterns in the user's target codebase, implement behavior-preserving changes when requested, and measure the result. For an audit or explanation request, inspect and report without changing the target. Work within the requested component and preserve its public contracts.

## Read the relevant guidance

The self-contained [handoff](references/interop_optimization_handoff.md) includes applicability rules, before and after examples, complete Cangjie and ArkTS source files, registration, declarations, dependencies, and recorded benchmark measurements. Paths in this skill resolve relative to this directory. The reference does not require the originating repository.

Read its **Ownership and execution rules** section before editing. Then read the sections relevant to the candidate pattern and the corresponding complete source blocks. Read **Combining the transformations in applications** when optimizing a read compute write pipeline, and **Verification and measurements** before evaluating results. Load the large source appendix selectively rather than reading every benchmark into context.

| Candidate | Guidance section | Complete source blocks |
| --- | --- | --- |
| Literal keys or repeated string values | Caching property keys and immutable strings | B03 cached keys; B08 Cangjie and ArkTS |
| Non-escaping heap intermediates | Keeping temporaries local to their scope | B07 Cangjie and ArkTS |
| Nested property paths | Coalescing a nested property path | B03 Cangjie and ArkTS |
| Several fields read together | Coalescing several fields of a record | B09 reader and read branches |
| Immediate waits on independent operations | Delaying waits with bounded futures | B01; reliable number future adaptation |
| Many small scheduled operations | Batching operations into one posted task | B01 batch worker; B09 read batches |
| Combined application pipeline | Combining the transformations in applications | B09 search; B12 graph |

Find section and source locations with `rg -n '^##|^###|^<!-- embedded-file:'` on the reference, then read those ranges. To work with individual source files, optionally run:

```bash
python3 /path/to/cangjie-arkts-optimize/scripts/extract_examples.py /tmp/new-interop-example-entry
```

The script locates the bundled reference automatically and creates the 22 embedded files only in a new directory. `--list` lists the file names without writing. These files are integration examples for an existing DevEco project, not a complete new application. Merge registration and declarations into the target as appropriate.

## Identify and apply transformations

Trace both sides of the boundary and determine where each operation runs, what its result depends on, and when it is consumed. Search Cangjie source for `getProperty`, `getElement`, `setProperty`, `callMethod`, `asObject`, `asArray`, `asString`, `runtime.string`, `postJSTask`, immediate waits, and operator equivalents inside loops. Inspect abstractions that wrap these calls.

Choose transformations from actual hot paths or representative measurements. Use the reference implementations to preserve the API and SDK idioms; adapt their data schemas and error handling. Apply and measure changes separately when useful, then evaluate the combined implementation. Explain candidates whose preconditions cannot be established or whose measurements do not justify the change.

Keep these non-obvious invariants:

- Engine operations and handle conversion run on the owning ArkTS thread. A posted task opens its scope there. Workers consume copied Cangjie values and completion slots.
- Heap-backed local `JSValue` handles do not outlive their scope or escape into later tasks. Retain persistent wrappers for roots, functions, and cached strings needed later. Preserve validation removed with an `asX` conversion.
- Cache key representations and immutable strings, not mutable field values. Bound value caches and own every engine handle by its runtime. The benchmark's global cache is not a multi-runtime implementation.
- Coalescing helpers are specific to a path or schema, but reusable across objects and Cangjie callers within the same runtime. Pass receivers as arguments, share identical helper code, and obtain separate handles in separate runtimes. Preserve getter order, side effects, null checks, exceptions, and method `this` binding.
- Pipelining requires independent inputs and equivalent state-observation order. Preserve consumption and output ordering. Keep the ArkTS event loop free while workers wait, bound pending work, and complete every required write before exposing completion.
- Batching reduces posted tasks while retaining each inner interop operation. Coalescing reduces inner accesses. Do not replace individual results with a sum unless the target only needs that sum.
- Settle completion slots and exported Promises on ordinary failures using the target's error and cancellation conventions. Original B01 and B12 callbacks can leave slots unfinished on exceptions; B09 counts some errors and substitutes defaults. These controlled-fixture behaviors are not production error policies.
- B12 coordinate packing assumes a fixed grid and bounded values. Use an appropriate general transfer representation when the target cannot preserve that encoding exactly.

## Validate and report

Compile both languages with the destination SDK and keep exports, declaration files, and `.so` imports consistent. Exercise the behavior affected by each transformation: distinct receivers and callers, mutation and getters, escaping values, cold and warm caches, empty and partial batches, output order, and failure completion. Use the destination's existing checks and add focused coverage only for material untested behavior.

Compare the same workload, device, and build configuration before and after, including the application-relevant setup costs. Track memory and UI task duration when caching or batching changes them. The bundled source declares Cangjie 1.1.3; verify the installed SDK rather than assuming signatures transfer unchanged. Recorded benchmark speedups explain candidate selection and do not predict the target's results.

Report the implemented transformations, any specialized ArkTS helpers and their reuse scope, correctness checks, measured results, and unresolved validation. This skill needs ordinary repository tools and the target's build environment; it has no MCP server or account dependency.
