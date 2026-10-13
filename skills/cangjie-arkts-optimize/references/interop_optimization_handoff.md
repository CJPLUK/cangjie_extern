# Applying Cangjie and ArkTS interop optimizations in another codebase

Use this handoff to find and implement repeated interop work in a Cangjie and ArkTS application. It includes before and after examples, the complete Cangjie and ArkTS implementations of the relevant benchmarks, their support code, and instructions for adapting them. The receiving agent does not need access to the source repository.

The examples use `ohos.ark_interop`. The source project declares Cangjie 1.1.3 and builds an OHOS dynamic library through DevEco. Adapt package names, module imports, declarations, and build configuration to the destination project and its installed SDK. These techniques do not require the proposed `Extern<ArkTS>` compiler feature.

## Instructions for the receiving agent

Find and apply the applicable optimizations in the destination repository. Read its project instructions and build configuration first. Inspect both Cangjie and ArkTS callers, then trace hot operations through the interop boundary. Preserve observable behavior, public contracts, and error handling. Make the changes and run the project's relevant correctness checks and before and after measurements.

1. Establish the current behavior and identify a representative workload. Record whether the code already runs on the ArkTS thread, which operations post work, where results are consumed, and which values cross scopes or threads.
2. Find repeated property paths, repeated conversion of literal keys or strings, temporary `asObject` / `asArray` / `asString` promotions, and immediate waits on posted operations.
3. For each candidate, record the source location, proposed transformation, applicable conditions, shared machinery, any specialized ArkTS helper, and a correctness check. Apply changes where the conditions are established. Explain candidates you cannot safely transform.
4. Introduce small transformations separately so their effects can be measured. Deduplicate helpers for identical access patterns within an ArkTS runtime. Keep caches and function handles owned by that runtime.
5. Measure individual changes and the combined implementation on the same workload and device. Retain improvements supported by the destination workload. Report changed files, behavior, verification, and measured results.

Treat the embedded code as concrete implementation references. The benchmark programs assume controlled fixtures; the production adaptations described below are part of the task.

## Finding candidates

Start with these searches and then inspect enclosing loops, call chains, and module registration. A match identifies a candidate, not proof that a change is valid.

```bash
rg -n --glob '*.cj' 'postJSTask|\.wait\(|\.get\(' .
rg -n --glob '*.cj' 'asObject\(|asArray\(|asString\(|asFunction\(' .
rg -n --glob '*.cj' 'getProperty\(|setProperty\(|getElement\(|callMethod\(' .
rg -n --glob '*.cj' '\.string\(|\.toJSValue\(' .
rg -n --glob '*.ets' 'readNode|writeNode|reader|Promise|lib.*\.so' .
```

Search operator forms such as `o["field"]`, `arr[i]`, and their wrappers too. If the destination uses an interop abstraction, trace it to the operations above before changing it.

| Pattern | Transformation | ArkTS implementation change | Reference implementation |
| --- | --- | --- | --- |
| Repeated literal property keys | Create `JSString` keys once | None | B03 cached keys and B08 names |
| Repeated immutable string values | Cache `String` to `JSString` conversions | None | B08 names and values |
| Heap temporaries consumed inside one scope | Keep scope-local `JSValue` handles | None | B07 objects and strings |
| Repeated nested property path | One specialized accessor call for the whole path | Add a path helper | B03 calls with `k = d` |
| Several fields read from one record | One specialized reader returning the required fields | Add a schema helper | B09 reader |
| Post one operation and wait immediately | Delay consumption with bounded futures | Usually existing callback unchanged | B01 optimized worker |
| Many short posts | Execute several operations in one posted task | Existing callback unchanged | B01 batch worker |
| Read compute write application | Combine techniques with explicit phase boundaries | Schema helpers where useful | B09 search and B12 graph |

## Ownership and execution rules

Run engine operations on the owning ArkTS thread. Worker threads may schedule tasks through `postJSTask`, wait for completion, and compute with Cangjie data. Create the engine scope inside the posted task, after execution reaches the owning thread.

A heap-backed `JSValue` obtained by `getProperty`, `getElement`, or an ArkTS call is scope-local. Consume it in that scope. Return copied Cangjie values such as `String`, `Float64`, or a Cangjie record containing copies. A `JSObject`, `JSArray`, `JSString`, or `JSFunction` created or promoted by the APIs used here has persistent lifetime, and its wrapper must remain alive while later tasks need it. Calling `toJSValue()` on a retained wrapper does not make unrelated local handles safe to escape.

| Use | Appropriate ownership |
| --- | --- |
| Intermediate object used immediately | Local `JSValue` inside `newScope` |
| String converted to Cangjie and consumed by a worker | Cangjie `String` copied inside the ArkTS scope |
| Root object or function needed by later posted tasks | Persistent wrapper retained in per-run or per-runtime state |
| Cached key or immutable string | Persistent `JSString` owned by that runtime |
| Result that must survive a scope | Copy to Cangjie or retain an appropriate persistent wrapper |

Do not wait on the ArkTS thread for a task posted to that same thread. Existing asynchronous APIs can return a Promise while a Cangjie coordinator waits on workers. A synchronous exported API needs a transformation that preserves its synchronous contract; moving it to workers and returning a Promise is an API change.

Use bounded scopes in long loops to release local handles periodically. Preserve persistent ownership for values that escape, callbacks, and function handles. Cache lookup must not replace a receiver-bound method call with an unbound function call: keep `callMethod` semantics where `this` matters.

## Caching property keys and immutable strings

The baseline repeatedly converts the key and the string value:

```cangjie
o.setProperty("name", rt.string(r.name).toJSValue())
list.callMethod("push", [o.toJSValue()])
```

Create the keys once with `B08Names(rt)`, and use `B08ValueCache` and `b08Cached` from the embedded B08 implementation:

```cangjie
// Set up on the owning ArkTS thread and retain for this runtime.
let keys = B08Names(rt)
let values = B08ValueCache()

// Inside the loop on that thread.
o.setProperty(keys.name, b08Cached(rt, values, r.name).toJSValue())
list.callMethod(keys.push, [o.toJSValue()])
```

The full baseline, key-only, and key-and-value variants are `b08Naive`, `b08Names`, and `b08NamesValues`. Their ArkTS input and result format is identical.

Cache the key representation, not the property's value or its containing object. Each access still resolves the current property on its current receiver, so rebinding a property remains visible. Cache immutable string values by their contents. In production, bound a value cache by entries or memory, or use a finite domain such as status names. A stream of unique strings can make hashing and retention cost more than conversion.

The benchmark's `B08_STATE` is module-global and assumes one runtime. Use per-runtime state in an application with several runtimes, and clear it during teardown. Perform all accesses to engine-backed entries on their owning thread. Do not share a `JSString` or `JSFunction` handle between separate ArkTS runtimes.

## Keeping temporaries local to their scope

The complete before and after functions for the object case are:

```cangjie
func b07ObjectsUser(rt: JSContext, xs: JSValue): Float64 {
    rt.newScope({ =>
        let arr = xs.asArray()
        var sum = 0.0
        for (i in 0..arr.size) {
            let b = arr[i].asObject()
            let c = b["inner"].asObject()
            sum += c["v"].toNumber()
        }
        sum
    })
}

func b07ObjectsGenerated(rt: JSContext, xs: JSValue): Float64 {
    rt.newScope({ =>
        let n = Int64(xs.getProperty("length").toNumber())
        var sum = 0.0
        for (i in 0..n) {
            let b = xs.getElement(i)
            let c = b.getProperty("inner")
            sum += c.getProperty("v").toNumber()
        }
        sum
    })
}
```

For a string argument and result used immediately, the corresponding loop body changes from:

```cangjie
let arg = rt.string(B06_NAMES[j & 15])
let res = f.call(arg.toJSValue()).asString()
total += Float64(res.toString().size)
```

to:

```cangjie
let arg = B06_NAMES[j & 15].toJSValue(rt)
let res = f.call(arg)
total += Float64(res.toString().size)
```

Both bodies execute inside `rt.newScope`. The complete B07 source includes the wrappers and registration. Its ArkTS array and `exclaim` callback are unchanged. The name `Generated` denotes the cheaper variant in this benchmark; these are ordinary functions in the embedded source, not evidence of an installed compiler pass.

Apply this only when a lifetime audit proves the removed persistent wrapper never escapes the active scope. Storage in a field, collection, closure, later task, or asynchronous continuation requires persistent ownership or a Cangjie copy. Also preserve any observable validation previously performed by `asObject`, `asArray`, or `asString`; establish the expected input type or keep equivalent checks for invalid inputs. Keep `asFunction()` where this SDK requires `JSFunction` to call a function.

## Coalescing a nested property path

The baseline crosses the boundary at every level:

```cangjie
var v = root
for (level in 0..8) {
    v = v.getProperty(B03_KEYS[level])
}
let result = v.toNumber()
```

The ArkTS fixture declares classes `L0` through `L7`, and a helper object with:

```typescript
class B03Fns {
  s0_8 = (o: L0): number => o.k0.k1.k2.k3.k4.k5.k6.k7;
}
const FNS = new B03Fns();
```

Cangjie obtains the helper once and calls it for each root:

```cangjie
// Fetch outside the hot loop, on the owning ArkTS thread.
let readPath = fns.getProperty("s0_8").asFunction()

// Inside an engine scope on that thread.
let result = readPath.call(root).toNumber()
```

The embedded B03 source contains all classes, intermediate getters, baseline functions, and the benchmark driver. `b03_calls(root, FNS, { d: 8, k: 8, n: 20000 })` selects one call for the whole path. `k: 1` makes one function call per level and is a comparison variant, not the desired coalescing transformation.

Specialize the helper to a path and its type contract. Pass the root as an argument, rather than closing over one object. All Cangjie callers within the same ArkTS runtime can use that function with compatible objects. Distinct object instances do not need distinct helpers. Different paths or contracts need distinct helpers. Separate runtimes can load the same helper code but must obtain their own handles.

For example, a destination path `order.customer.address.postcode` needs one helper for that path. It does not need one helper per order, Cangjie class, worker, or call site. Keep a small ArkTS helper module and expose the shared accessor object or function through the project's existing module interface.

The helper must preserve property order, getter effects, null handling, and exceptions. Do not combine accesses if intervening Cangjie code mutates a relevant property or has observable effects. Use the original direct lookup syntax in the helper, and add equivalent checks where the original bridge performed validation. Hoist the helper handle only if the program's binding is stable; otherwise honor replacement of that binding.

## Coalescing several fields of a record

The search baseline reads an item, its `meta` and `price` objects, and then five fields. The ArkTS helper is:

```typescript
export const reader = (list: Object[], i: number): Object[] => {
  const it = list[i] as B09ItemTS;
  return [it.id, it.meta.title, it.meta.brand, it.price.amount, it.meta.description];
};
```

Its Cangjie counterpart, executed in `newScope`, is:

```cangjie
let r = st.reader.call([st.list.toJSValue(), rt.number(Float64(i)).toJSValue()])
it.id = r.getElement(0).toNumber()
it.title = r.getElement(1).toString()
it.brand = r.getElement(2).toString()
it.amount = r.getElement(3).toNumber()
it.description = r.getElement(4).toString()
```

`it` is a `B09Item` containing Cangjie values, so a worker can compute with it after the scope closes. This helper still requires five element reads of the returned array; it is not a single native multi-value conversion. Measure whether helper entry, allocation, and unpacking beat the original accesses.

Adapt the field list, return order, and Cangjie conversion together. The baseline B09 implementation fetches `meta` and `price` before its leaf values, while the helper uses a different lookup sequence and rereads `meta`. The fixture has ordinary stable fields. For effectful getters or mutable receiver expressions, first generate a helper with the same evaluation order and reuse the same intermediates as the destination baseline. Do not treat arbitrary object schemas as interchangeable.

## Delaying waits with bounded futures

The baseline worker issues an operation, waits immediately, then performs Cangjie work:

```cangjie
for (i in 0..n) {
    let f = b01PostDirect(runtime, fn, Float64(base + i))
    b01TimedWait(f, st)
    b01TimedWork(workNs, st)
}
```

The optimized worker issues ahead of consumption and drains pending results at the end:

```cangjie
let ring = Array<?B01Future>(d + 1, repeat: None)
for (i in 0..n) {
    ring[i % (d + 1)] = b01PostDirect(runtime, fn, Float64(base + i))
    if (i >= d) {
        b01TimedWait(ring[(i - d) % (d + 1)].getOrThrow(), st)
    }
    b01TimedWork(workNs, st)
}
let from = if (n > d) { n - d } else { 0 }
for (i in from..n) {
    b01TimedWait(ring[i % (d + 1)].getOrThrow(), st)
}
```

The full B01 implementation embeds the mutex and condition variable, posting functions, worker coordinator, Promise resolution, and registration. ArkTS uses the same `jsOp(x) { return x * 2 + 1; }` for all variants.

The implementation's `d` means results are consumed `d` iterations after issue; up to `d + 1` operations have been issued before a wait. With `d = 0`, the worker waits immediately. Preserve consumption order where callers observe it. Do not pipeline a recurrence whose next arguments depend on the previous result. Delaying reads or writes can change what shared mutable ArkTS state is observed; use a stable snapshot or establish an equivalent ordering before applying this to mutable data.

Validate `n >= 0`, `d >= 0`, and `t >= 1`, and impose workload-appropriate bounds. A real application must settle every future on both success and failure and reject its exported Promise when a worker fails. The embedded `reliable_number_future.cj` supplies an adaptation example that reports ordinary `Exception` failures, including failures while scheduling. Use the destination's cancellation and runtime teardown mechanism for tasks that will never execute.

The original B01 and B12 posted callbacks do not complete their result slots if an operation throws. B09 counts some callback exceptions and substitutes defaults. Preserve the destination's error semantics instead of copying either benchmark behavior unchanged. B09 also retains all write futures until the end; bound that queue for large workloads.

## Batching operations into one posted task

`b01PostBatch` posts several calls together:

```cangjie
runtime.postJSTask({ =>
    var sum = 0.0
    for (j in 0..m) {
        sum += runtime.newScope({ =>
            fn.call(runtime.number(x0 + Float64(j)).toJSValue()).toNumber()
        })
    }
    b01Complete(f, sum)
})
```

The ArkTS callback is unchanged. This removes scheduling and waiting overhead: it still makes `m` interop function calls. Path coalescing, by comparison, reduces the number of interop accesses inside a task. The two techniques can be combined.

The benchmark needs only the sum, so it stores one aggregate result. If the destination needs each result, use a Cangjie array or record containing every copied result, following `B09ReadFuture`; preserve order and per-operation errors. Group only independent operations, or sequential operations whose grouping does not change externally observable interleaving. Do not move Cangjie computation after a batch when that computation affects the next call.

Validate `b >= 1`, handle the partial final batch, and drain completion before resolving. Tune task sizes against UI responsiveness as well as throughput. Batching and futures should be evaluated independently: one waits after each group, the other overlaps issue and consumption.

## Combining the transformations in applications

The embedded search benchmark demonstrates baseline and optimized code behind independent flags:

```typescript
const before: B09Config = {
  futures: false, coalesce: false, scoped: false, cache: false,
  d: 8, t: 1, b: 1
};
const after: B09Config = {
  futures: true, coalesce: true, scoped: true, cache: true,
  d: 8, t: 1, b: 8
};
await b09_run(before, list, baselineResults, reader, query);
await b09_run(after, list, optimizedResults, reader, query);
```

The full ArkTS driver defines the classes, catalogue, reference computation, checksums, and flag sweeps. Both configurations receive the same `reader`; the baseline does not invoke it. Thus the ArkTS harness is shared across runs, while the coalescing helper is specialized to this search schema.

Multiple workers in B09 may push results in a different order. The fixture checks results independent of order. If the destination requires input order, preserve indexed result placement or reorder by the original index before publishing. Its example computation uses nonempty ASCII queries; validate a nonempty query and include the destination's Unicode semantics in equivalence checks.

For graph layout, `b12StepSync` has baseline and `tactical` branches. The latter uses ArkTS `readNode` and `writeNode` accessors. `b12StepAsync` additionally batches posted reads and writes around parallel Cangjie computation. The complete implementations and ArkTS helpers are embedded below.

The graph uses a 1/1024 coordinate grid in all configurations and packs bounded coordinates and flags into an exactly represented integer. This is a domain-specific mock of multi-value transfer. It is valid only for its grid, bounds, and encoding: coordinates are in `[-16384, 16384)`, read results use 51 bits, and write arguments use 52 bits. Keep arbitrary floating-point values intact in a general application, using an appropriate tuple, record, array, or supported bulk API, then measure transfer costs. Do not introduce quantization to claim equivalent behavior.

The graph's global state supports one topology at a time; scope it per graph or session in a destination with concurrent instances. Async reads are a phase spanning several tasks, so establish how UI edits during that phase are represented before applying it to interactive state.

## Verification and measurements

Use the destination build and test commands with its installed OHOS SDK. Compile both Cangjie and ArkTS: cross-language export declarations and the library name must agree. Desktop `cjpm` alone does not supply the OHOS interop packages.

Exercise the conditions affected by the change:

- Property helpers: at least two distinct roots and two callers sharing a helper, reassigned intermediate fields, valid leaf changes, and the destination's null, missing-field, and getter behavior.
- Lifetime changes: large loops, nested scopes, and any escaping values or callbacks. Ensure only copied values or retained wrappers leave a scope.
- Caching: cold and warm states, repeated and mostly unique strings, separate runtimes, and teardown. Track retained memory as well as time.
- Futures and batching: zero and one item, `n < d`, non-divisible final batches, ordinary task exceptions, task scheduling failure, output ordering, and completion of every required write.
- Application combinations: compare complete outputs with the baseline. Check UI events and latency when grouping tasks. Preserve floating-point tolerances and Unicode semantics used by the destination.

Measure the same release configuration, workload, device, and runtime lifecycle. Warm variants equally, alternate their run order, and record several repetitions. Include setup, cold-start cost, or steady-state cost according to the application's use; state which is measured. Report medians and spread, throughput, UI task duration where relevant, and memory changes. Do not infer application speedup by multiplying the individual benchmark ratios.

These recorded medians explain why the patterns are candidates; they are not predictions for another codebase:

| Reference configuration | Baseline | Optimized |
| --- | --- | --- |
| B01 futures, one worker, `w = 0`, `d = 16` | 112.9 microseconds per call | 8.7 microseconds per call |
| B01 batching, four workers, `w = 0`, `b = 16` | 21.5 microseconds per call | 2.5 microseconds per call |
| B03 property path, depth 8 | 5.21 microseconds per read | 0.88 microseconds per read |
| B07 object temporaries, 10000 elements | 3.39 microseconds per element | 2.43 microseconds per element |
| B08 strings, 100 unique values per 10000 records | 7.07 microseconds per record | 4.35 microseconds per record |
| B09 search, 200 character descriptions, one worker | 428.1 microseconds per item | 57.5 microseconds per item |
| B09 same workload, four workers | 85.0 microseconds per item | 28.3 microseconds per item |
| B12 synchronous graph, 1000 nodes | 6.71 milliseconds per frame | 4.80 milliseconds per frame |

The B01 `cfg.w` argument is in nanoseconds; the result slides display microseconds. The baseline measurements for futures and batching came from different sweeps. B12's recorded optimized row is the synchronous tactical variant, not the full async implementation.

## Embedded source organization and integration

Each marked file block below can be copied to its named location in an OHOS entry module, or extracted together with the script in the next section. Complete original files are included for B01, B03, B07, B08, B09, and B12 on both sides of the boundary. Supporting blocks include:

- `harness.cj` for monotonic timing and synthetic Cangjie work.
- `benchmark_support.cj` for `B06_NAMES` and `b04Repeat`, extracted from other benchmarks so those unrelated programs are not needed.
- A focused `index.cj` registering only the included benchmarks.
- Focused `Index.d.ts` declarations and the library type package metadata.
- `Log.ets` and `InteropOptimizationExamples.ets` to run the examples from an existing ArkTS page or ability.
- The original `cjpm.toml` and entry package manifest as configuration references.
- `reliable_number_future.cj`, an additional failure-reporting helper example for adaptation; it does not replace the original benchmark implementations.

The original sources are from `cangjie_extern` revision `37d658d26440254d3c653dc82d2fb64f9511db8d`. Their original directory is `benchmarks/interop_opt_bench/externBchm/entry`. B01 future helpers are also used by B09 and B12. B07 needs `B06_NAMES`; B08 needs `b04Repeat`. Both dependencies are embedded in the support block. ArkTS imports only the declared library, SDK kits, and the included `Log.ets` file. No benchmark source dependency requires access to the original repository.

The extraction creates source and configuration for integration into an existing DevEco OHOS application. It does not create app resources, a UI page, signing configuration, or a complete new HAP project. Merge the included dependency entry into the destination's `oh-package.json5`; do not overwrite its manifest or registration file. Adapt the copied `cjpm.toml` to the destination SDK and build profile rather than replacing project settings. If a Cangjie package is renamed, update the `.so` import, type package name, declarations, dependency mapping, and module registration together.

In an existing asynchronous page or ability method, import `runInteropOptimizationExamples` from its relative path and call:

```typescript
await runInteropOptimizationExamples((line: string): void => {
  console.info(line);
});
```

The driver runs quick variants sequentially and includes the search batching grid. For real measurements, call the individual `runB01`, `runB03`, `runB07`, `runB08`, `runB09`, and `runB12` functions with their documented options instead. Keep the ArkTS event loop free while awaiting their asynchronous results.

## Extracting the embedded files

Save this document as a file, save the following Python code as `extract_interop_examples.py`, and run `python3 extract_interop_examples.py handoff.md /tmp/interop-examples-entry`. The script refuses to overwrite an existing destination. Its file markers identify complete source files, not the short explanatory excerpts above.

```python
from pathlib import Path
import re
import sys

document = Path(sys.argv[1]).read_text()
destination = Path(sys.argv[2]).resolve()
if destination.exists():
    raise SystemExit("Choose a new destination directory")
pattern = re.compile(
    r"^<!-- embedded-file: ([^\n]+) -->\n\n```[^\n]*\n(.*?)^```\n",
    re.MULTILINE | re.DOTALL,
)
files = pattern.findall(document)
if not files:
    raise SystemExit("No embedded files found")
seen = set()
for name, content in files:
    target = (destination / name).resolve()
    if not target.is_relative_to(destination) or target == destination:
        raise SystemExit("Invalid embedded path: " + name)
    if target in seen:
        raise SystemExit("Duplicate embedded path: " + name)
    seen.add(target)
destination.mkdir(parents=True)
for name, content in files:
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("x") as output:
        output.write(content)
print(f"Extracted {len(files)} files to {destination}")
```

## Evidence and reference versions

Interop behavior and examples are grounded in the embedded benchmark implementations and the source repository's `docs/issue_with_current_extern_interface.md`. Measurements were recorded in `benchmarks/interop_opt_bench/interop.html`, in its `DATA` object. Those two files are provenance references; their necessary operational details are included above.

The mutex and condition-variable idioms were cross-checked against the official-language material in CangjieCorpus: `manual/source_zh_cn/concurrency/sync.md`, `libs/std/sync/sync_package_api/sync_package_interfaces.md`, and `manual/source_zh_cn/error_handle/handle.md`. The corpus declares Cangjie v1.0.0; the source benchmark manifest declares 1.1.3. The corpus does not contain the OHOS interop package documentation. Confirm the destination SDK's actual interop signatures through its available package definitions and builds.

The source bundle preserves the benchmark implementations, including the controlled-fixture assumptions explained above. The additional registration, support file, runner, focused declarations, and reliable-future example are identified as adaptations. Source extraction and source consistency can be checked on a desktop; compilation and execution of the OHOS examples require the destination's DevEco SDK and device or emulator.

## Complete embedded source files

### Cangjie build configuration

Original benchmark source or configuration.

File: `cjpm.toml`.

<!-- embedded-file: cjpm.toml -->

```toml
[package]
  cjc-version = "1.1.3"
  compile-option = "--dy-std --cfg=\"${COMPILE_CONDITION_ENTRY}\""
  description = "CangjieUI Application"
  name = "ohos_app_cangjie_entry"
  output-type = "dynamic"
  src-dir = "./src/main/cangjie"
  target-dir = ""
  version = "1.0.0"

[profile]
  [profile.build]
    incremental = true
    lto = ""
    [profile.build.combined]
      ohos_app_cangjie_entry = "dynamic"
  [profile.customized-option]
    debug = "-g -Woff all -Won apilevel-check"
    release = "--fast-math -O2 -s -Woff all -Won apilevel-check"
  [profile.test]

[target.aarch64-linux-ohos]
  compile-option = "-B \"${DEVECO_CANGJIE_HOME}/build-tools/third_party/llvm/bin\" -B \"${DEVECO_OH_NATIVE_HOME}/sysroot/usr/lib/aarch64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/sysroot/usr/lib/aarch64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/llvm/lib/aarch64-linux-ohos\" --sysroot \"${DEVECO_OH_NATIVE_HOME}/sysroot\""
[target.aarch64-linux-ohos.bin-dependencies]
  path-option = ["${AARCH64_LIBS}", "${AARCH64_MACRO_LIBS}", "${AARCH64_KIT_LIBS}"]
  package-option = {}

[target.x86_64-linux-ohos]
  compile-option = "-B \"${DEVECO_CANGJIE_HOME}/build-tools/third_party/llvm/bin\" -B \"${DEVECO_OH_NATIVE_HOME}/sysroot/usr/lib/x86_64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/sysroot/usr/lib/x86_64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos\" -L \"${DEVECO_OH_NATIVE_HOME}/llvm/lib/x86_64-linux-ohos\" --sysroot \"${DEVECO_OH_NATIVE_HOME}/sysroot\""
[target.x86_64-linux-ohos.bin-dependencies]
  path-option = ["${X86_64_OHOS_LIBS}", "${X86_64_OHOS_MACRO_LIBS}", "${X86_64_OHOS_KIT_LIBS}"]

[target.aarch64-apple-darwin]
  compile-option = "--link-options=\"-rpath @executable_path/../../../sdk/cangjie/build-tools/runtime/lib/darwin_aarch64_cjnative\" --link-options=\"-rpath @executable_path/../../../sdk/cangjie/api/lib/darwin_aarch64_cjnative/kit\" --link-options=\"-rpath @executable_path/../../../sdk/cangjie/api/lib/darwin_aarch64_cjnative/ohos\" --link-options=\"-rpath @executable_path/../../../sdk/cangjie/api/macro/ohos\" --link-options=\"-rpath @executable_path/module/cj_sdk_libraries\""
[target.aarch64-apple-darwin.bin-dependencies]
  path-option = ["${AARCH64_LIBS}", "${AARCH64_MACRO_LIBS}", "${AARCH64_KIT_LIBS}"]
  package-option = {}
```

### ArkTS entry dependency mapping

Original benchmark source or configuration.

File: `oh-package.json5`.

<!-- embedded-file: oh-package.json5 -->

```json
{
  "name": "entry",
  "version": "1.0.0",
  "description": "Please describe the basic information.",
  "main": "",
  "author": "",
  "license": "",
  "dependencies": {
    "libohos_app_cangjie_entry.so": "file:src/main/cangjie/types/libohos_app_cangjie_entry"
  }
}
```

### ArkTS library type package metadata

Original benchmark source or configuration.

File: `src/main/cangjie/types/libohos_app_cangjie_entry/oh-package.json5`.

<!-- embedded-file: src/main/cangjie/types/libohos_app_cangjie_entry/oh-package.json5 -->

```json
{
  "name": "libohos_app_cangjie_entry.so",
  "types": "./Index.d.ts",
  "version": "1.0.0",
  "description": ""
}
```

### ArkTS declarations for the included benchmarks

Extracted declarations for B01, B03, B07, B08, B09, and B12. Two comments are corrected to match the implementation.

File: `src/main/cangjie/types/libohos_app_cangjie_entry/Index.d.ts`.

<!-- embedded-file: src/main/cangjie/types/libohos_app_cangjie_entry/Index.d.ts -->

```typescript
// ---- B01: JS-thread futures ----
export interface B01Config {
  n: number;  // ops per worker thread
  w: number;  // ns of Cangjie work per op
  d: number;  // lookahead: result consumed d ops after issue (opt only)
  t: number;  // Cangjie worker threads
  b?: number; // ops per posted task (batch only; default 1)
}
export interface B01Result {
  ns: number;        // wall time measured in Cangjie, all workers
  checksum: number;  // sum of fn(x) over all ops
  blockedNs: number; // summed over workers: time blocked in b01Wait()
  workedNs: number;  // summed over workers: time spent in the Cangjie work loop
}
export declare function b01_naive(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>
// diagnostic: avg wall ns of spinNs(w), n calls, no interop
export declare function b01_spin_check(w: number, n: number): number
export declare function b01_opt(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>;
export declare function b01_batch(fn: (x: number) => number, cfg: B01Config): Promise<B01Result>;

// ---- B03: coalescing accesses to one ArkTS object graph (synchronous, on the ArkTS thread) ----
export interface B03Config {
  d: number;  // path depth (levels of property access)
  k: number;  // levels per getter call (b03_calls only)
  n: number;  // path reads
}
export interface B03Result {
  ns: number;        // time of the whole loop, measured in Cangjie
  checksum: number;  // sum of the leaf values read
}
export declare function b03_field(root: Object, fns: Object, cfg: B03Config): B03Result
export declare function b03_field_ck(root: Object, fns: Object, cfg: B03Config): B03Result
export declare function b03_calls(root: Object, fns: Object, cfg: B03Config): B03Result

// ---- B07: temporaries bound as persistent references (user) vs scoped values (generated) ----
export declare function b07_objects(variant: string, xs: Object[]): number
export declare function b07_strings(variant: string, f: (s: string) => string, n: number): number

// ---- B08: string caching (names; names + values) ----
export interface B08Result {
  ns: number;  // time of the timed loop
}
export declare function b08_export(variant: string, list: Object[], n: number, u: number): B08Result

// ---- B09: search-as-you-type with all optimisations behind switches ----
export interface B09Config {
  futures: boolean;   // reads issued d items ahead, writes waited for at the end
  coalesce: boolean;  // one ArkTS reader call per item instead of 8 property/element reads
  scoped: boolean;    // temporaries and written string values as scoped JSValues
  cache: boolean;     // names created once; string values reused through a String -> JSString cache
  d: number;          // lookahead when futures is on
  t: number;          // worker threads
  b?: number;         // items per posted task (default 1)
}
export interface B09Result {
  ns: number;      // wall time of the whole search, all workers
  errors: number;  // exceptions inside posted tasks (should be 0)
}
export declare function b09_run(cfg: B09Config, list: Object[], results: Object[],
  reader: (list: Object[], i: number) => Object[], query: string): Promise<B09Result>

export interface B12Result {
  ns: number;         // wall time of the step
  uiNs: number;       // time the ArkTS thread spent in the step
  computeNs: number;  // time of the force computation
}
export declare function b12_setup(edges: number[], n: number): number;
export declare function b12_step_sync(cfg: { tactical: boolean }, nodes: Object[], lib: Object): B12Result;
export declare function b12_step_async(cfg: { t: number, b: number }, nodes: Object[], lib: Object): Promise<B12Result>;
export interface B12CheckCosts {
  isNumber: number; isBoolean: number; size: number; toNumber: number; toBoolean: number;
  getElementToNumber: number; sink: number;
}
export declare function b12_check_costs(arr: Object[], n: number): B12CheckCosts;
```

### Cangjie module registration

Adapted registration for only the included benchmarks. Merge these calls into an existing registration when integrating.

File: `src/main/cangjie/index.cj`.

<!-- embedded-file: src/main/cangjie/index.cj -->

```cangjie
package ohos_app_cangjie_entry

import ohos.ark_interop.*

let EXPORT_MODULE = JSModule.registerModule {
    runtime, exports =>
    b01Register(runtime, exports)
    b03Register(runtime, exports)
    b07Register(runtime, exports)
    b08Register(runtime, exports)
    b09Register(runtime, exports)
    b12Register(runtime, exports)
}
```

### Cangjie benchmark timing support

Original benchmark source or configuration.

File: `src/main/cangjie/harness.cj`.

<!-- embedded-file: src/main/cangjie/harness.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.time.MonoTime

// Shared benchmark utilities (no interop in here).

let HARNESS_T0 = MonoTime.now()

// Monotonic nanoseconds since module load.
func nowNs(): Int64 {
    (MonoTime.now() - HARNESS_T0).toNanoseconds()
}

// Busy-wait for `ns` nanoseconds of wall time: stands in for "useful Cangjie work".
// Returns the iteration count so the loop can't be optimised away.
func spinNs(ns: Int64): Int64 {
    if (ns <= 0) {
        return 0
    }
    let end = nowNs() + ns
    var it = 0
    while (nowNs() < end) {
        it++
    }
    it
}
```

### Cangjie dependencies extracted from other benchmarks

Original B06_NAMES constant and b04Repeat function in a new support file. B07 and B08 require these definitions.

File: `src/main/cangjie/benchmark_support.cj`.

<!-- embedded-file: src/main/cangjie/benchmark_support.cj -->

```cangjie
package ohos_app_cangjie_entry

let B06_NAMES: Array<String> = ["alpha001", "bravo002", "charlie3", "delta004", "echo0005", "foxtrot6", "golf0007",
    "hotel008", "india009", "juliet10", "kilo0011", "lima0012", "mike0013", "november", "oscar015", "papa0016"]

func b04Repeat(s: String, times: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..times) {
        sb.append(s)
    }
    sb.toString()
}
```

### Cangjie future helper with ordinary exception reporting

Additional adaptation example. Benchmark sources remain unchanged. Wait only from a worker. Use persistent captures for later tasks; execute engine operations only inside task on the owning thread. This helper reports ordinary Exceptions, not runtime teardown or fatal Errors.

File: `src/main/cangjie/reliable_number_future.cj`.

<!-- embedded-file: src/main/cangjie/reliable_number_future.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.sync.*
import ohos.ark_interop.*

class ReliableNumberFuture {
    let mutex = Mutex()
    var cond: ?Condition = None
    var done = false
    var value = 0.0
    var failure: ?String = None
}

func reliableNewNumberFuture(): ReliableNumberFuture {
    let f = ReliableNumberFuture()
    f.cond = synchronized(f.mutex) { f.mutex.condition() }
    f
}

func reliableFinishNumber(f: ReliableNumberFuture, value: Float64, failure: ?String): Unit {
    synchronized(f.mutex) {
        if (!f.done) {
            f.value = value
            f.failure = failure
            f.done = true
            f.cond.getOrThrow().notifyAll()
        }
    }
}

// task is executed on the owning ArkTS thread and returns a copied number.
// Captured engine objects must have persistent ownership until execution.
func reliablePostNumber(rt: JSContext, task: () -> Float64): ReliableNumberFuture {
    let f = reliableNewNumberFuture()
    try {
        rt.postJSTask({ =>
            try {
                let v = rt.newScope({ => task() })
                reliableFinishNumber(f, v, None)
            } catch (e: Exception) {
                reliableFinishNumber(f, 0.0, Some(e.toString()))
            }
        })
    } catch (e: Exception) {
        reliableFinishNumber(f, 0.0, Some(e.toString()))
    }
    f
}

// This blocks a worker; never call it on the ArkTS thread.
func reliableWaitNumber(f: ReliableNumberFuture): Float64 {
    synchronized(f.mutex) {
        while (!f.done) {
            f.cond.getOrThrow().wait()
        }
        match (f.failure) {
            case Some(message) => throw Exception(message)
            case None => f.value
        }
    }
}
```

### Cangjie futures and batching

Original benchmark source or configuration.

File: `src/main/cangjie/b01_js_futures.cj`.

<!-- embedded-file: src/main/cangjie/b01_js_futures.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.sync.*
import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B01 - JS-thread futures.
 *
 * Multi-threaded Cangjie code must run every interop operation on the ArkTS thread.
 * Each worker thread performs N operations "call the JS function fn(x)" and does
 * `w` ns of independent Cangjie work per operation.
 *
 *   naive:     post the op to the ArkTS thread, block until the result arrives, then work.
 *              (what a user writes today: one full cross-thread round trip per op)
 *   opt:       post the op, keep working; only block when the result is consumed,
 *              `d` ops later.  d = 0 degenerates to naive.
 *   batch:     post `b` ops in one task, block until the task is done, then work b times.
 *              No pipelining: the worker waits immediately, as in naive. b = 1 degenerates to naive.
 *
 * (A third variant, coalescing the posts through a shared queue, was measured on
 *  2026-09-28 and dropped for simplicity: ~2x over opt only with several threads and d >= 4.)
 *
 * ArkTS signature (identical for both):
 *   b01_{naive,opt,batch}(fn: (x: number) => number, cfg: {n, w, d, t, b?}): Promise<{ns, checksum, ...}>
 * The call returns a Promise immediately: the ArkTS thread must stay free to service
 * the posted tasks, otherwise it would deadlock.
 */

// ---------------------------------------------------------------------------
// Result slot: filled on the ArkTS thread, read on a Cangjie worker thread.
// ---------------------------------------------------------------------------

class B01Future {
    var mutex: Mutex = Mutex()
    var cond: ?Condition = None
    var done: Bool = false
    var value: Float64 = 0.0
}

func b01NewFuture(): B01Future {
    let f = B01Future()
    f.cond = synchronized(f.mutex) { f.mutex.condition() }
    f
}

// Called on the ArkTS thread.
func b01Complete(f: B01Future, v: Float64): Unit {
    synchronized(f.mutex) {
        f.value = v
        f.done = true
        f.cond.getOrThrow().notifyAll()
    }
}

// Called on a worker thread; blocks until b01Complete has run.
func b01Wait(f: B01Future): Float64 {
    synchronized(f.mutex) {
        while (!f.done) {
            f.cond.getOrThrow().wait()
        }
        f.value
    }
}

// ---------------------------------------------------------------------------
// Posting: one postJSTask per operation.
// ---------------------------------------------------------------------------

func b01PostDirect(runtime: JSContext, fn: JSFunction, x: Float64): B01Future {
    let f = b01NewFuture()
    runtime.postJSTask({ =>
        let r = runtime.newScope({ => fn.call(runtime.number(x).toJSValue()).toNumber() })
        b01Complete(f, r)
    })
    f
}

// One postJSTask for the ops x0, x0 + 1, ..., x0 + m - 1; the future holds the sum of their results.
func b01PostBatch(runtime: JSContext, fn: JSFunction, x0: Float64, m: Int64): B01Future {
    let f = b01NewFuture()
    runtime.postJSTask({ =>
        var sum = 0.0
        for (j in 0..m) {
            sum += runtime.newScope({ => fn.call(runtime.number(x0 + Float64(j)).toJSValue()).toNumber() })
        }
        b01Complete(f, sum)
    })
    f
}

// ---------------------------------------------------------------------------
// Workers. naive and opt differ only in when they wait; batch in how many ops go into one task.
// ---------------------------------------------------------------------------

class B01Stats {
    var checksum: Float64 = 0.0
    var blockedNs: Int64 = 0   // time inside b01Wait
    var workedNs: Int64 = 0    // time inside the Cangjie work loop
}

func b01TimedWait(f: B01Future, st: B01Stats): Unit {
    let t = nowNs()
    st.checksum += b01Wait(f)
    st.blockedNs += nowNs() - t
}

func b01TimedWork(workNs: Int64, st: B01Stats): Unit {
    let t = nowNs()
    spinNs(workNs)
    st.workedNs += nowNs() - t
}

// naive: post, wait, work.
func b01WorkerNaive(runtime: JSContext, fn: JSFunction, base: Int64, n: Int64, workNs: Int64): B01Stats {
    let st = B01Stats()
    for (i in 0..n) {
        let f = b01PostDirect(runtime, fn, Float64(base + i))
        b01TimedWait(f, st)
        b01TimedWork(workNs, st)
    }
    st
}

// opt: post op i, wait for op i-d, work. A ring of d+1 futures holds the ops in flight.
func b01WorkerOpt(runtime: JSContext, fn: JSFunction, base: Int64, n: Int64, workNs: Int64, d: Int64): B01Stats {
    let st = B01Stats()
    let ring = Array<?B01Future>(d + 1, repeat: None)
    for (i in 0..n) {
        ring[i % (d + 1)] = b01PostDirect(runtime, fn, Float64(base + i))
        if (i >= d) {
            b01TimedWait(ring[(i - d) % (d + 1)].getOrThrow(), st)
        }
        b01TimedWork(workNs, st)
    }
    // wait for the last d ops, still in flight
    let from = if (n > d) { n - d } else { 0 }
    for (i in from..n) {
        b01TimedWait(ring[i % (d + 1)].getOrThrow(), st)
    }
    st
}

// batch: post b ops in one task, wait, then work once per op.
func b01WorkerBatch(runtime: JSContext, fn: JSFunction, base: Int64, n: Int64, workNs: Int64, b: Int64): B01Stats {
    let st = B01Stats()
    var i = 0
    while (i < n) {
        let m = if (i + b < n) { b } else { n - i }
        let f = b01PostBatch(runtime, fn, Float64(base + i), m)
        b01TimedWait(f, st)
        for (_ in 0..m) {
            b01TimedWork(workNs, st)
        }
        i += m
    }
    st
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

enum B01Mode {
    | Naive
    | Opt
    | Batch
}

func b01Run(runtime: JSContext, callInfo: JSCallInfo, mode: B01Mode): JSValue {
    let fn = callInfo[0].asFunction()
    let cfg = callInfo[1].asObject()
    let n = Int64(cfg["n"].toNumber())
    let workNs = Int64(cfg["w"].toNumber())
    let d = Int64(cfg["d"].toNumber())
    let threads = Int64(cfg["t"].toNumber())
    let b = if (cfg["b"].isNumber()) { Int64(cfg["b"].toNumber()) } else { 1 }
    let promise = runtime.promiseCapability()

    // Coordinator thread: start the workers, wait for them, resolve the promise on the ArkTS thread.
    spawn {
        try {
            let t0 = nowNs()
            let workers = ArrayList<Future<B01Stats>>()
            for (k in 0..threads) {
                let base = k * n
                let worker = spawn {
                    match (mode) {
                        case B01Mode.Naive => b01WorkerNaive(runtime, fn, base, n, workNs)
                        case B01Mode.Opt => b01WorkerOpt(runtime, fn, base, n, workNs, d)
                        case B01Mode.Batch => b01WorkerBatch(runtime, fn, base, n, workNs, b)
                    }
                }
                workers.add(worker)
            }
            var checksum = 0.0
            var blockedNs = 0
            var workedNs = 0
            for (w in workers) {
                let st = w.get()
                checksum += st.checksum
                blockedNs += st.blockedNs
                workedNs += st.workedNs
            }
            let elapsedNs = nowNs() - t0
            b01Resolve(runtime, promise, elapsedNs, checksum, blockedNs, workedNs)
        } catch (e: Exception) {
            let msg = e.toString()
            runtime.postJSTask({ => promise.reject(runtime.string(msg).toJSValue()) })
        }
    }
    promise.toJSValue()
}

func b01Resolve(runtime: JSContext, promise: JSPromiseCapability, elapsedNs: Int64, checksum: Float64,
    blockedNs: Int64, workedNs: Int64): Unit {
    runtime.postJSTask({ =>
        let res = runtime.object()
        res["ns"] = runtime.number(Float64(elapsedNs)).toJSValue()
        res["checksum"] = runtime.number(checksum).toJSValue()
        res["blockedNs"] = runtime.number(Float64(blockedNs)).toJSValue()
        res["workedNs"] = runtime.number(Float64(workedNs)).toJSValue()
        promise.resolve(res.toJSValue())
    })
}

func b01Naive(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b01Run(runtime, callInfo, B01Mode.Naive)
}

func b01Opt(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b01Run(runtime, callInfo, B01Mode.Opt)
}

func b01Batch(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b01Run(runtime, callInfo, B01Mode.Batch)
}

// Diagnostic: average wall time of spinNs(w) called n times, no interop involved.
func b01SpinCheck(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let w = Int64(callInfo[0].toNumber())
    let n = Int64(callInfo[1].toNumber())
    let t0 = nowNs()
    for (_ in 0..n) {
        spinNs(w)
    }
    runtime.number(Float64(nowNs() - t0) / Float64(n)).toJSValue()
}

func b01Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b01_spin_check"] = runtime.function(b01SpinCheck).toJSValue()
    exports["b01_naive"] = runtime.function(b01Naive).toJSValue()
    exports["b01_opt"] = runtime.function(b01Opt).toJSValue()
    exports["b01_batch"] = runtime.function(b01Batch).toJSValue()
}
```

### ArkTS futures and batching

Original benchmark source or configuration.

File: `src/main/ets/bench/b01_js_futures.ets`.

<!-- embedded-file: src/main/ets/bench/b01_js_futures.ets -->

```typescript
import { b01_batch, b01_naive, b01_opt, b01_spin_check, B01Config, B01Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// The JS operation Cangjie workers call on the ArkTS thread. Same for both variants.
function jsOp(x: number): number {
  return x * 2 + 1;
}

type Impl = (fn: (x: number) => number, cfg: B01Config) => Promise<B01Result>;

// sum_{x=0}^{M-1} (2x+1) = M^2, with M = n * t
function expectedChecksum(cfg: B01Config): number {
  const m = cfg.n * cfg.t;
  return m * m;
}

async function runOne(sink: LogSink, variant: string, impl: Impl, cfg: B01Config, rep: number): Promise<void> {
  const r = await impl(jsOp, cfg);
  const ops = cfg.n * cfg.t;
  const ok = r.checksum === expectedChecksum(cfg) ? 1 : 0;
  // BENCH,b01,variant,n,t,w,d,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok
  benchLine(sink, `BENCH,b01,${variant},${cfg.n},${cfg.t},${cfg.w},${cfg.d},${rep},` +
    `${(r.ns / ops).toFixed(1)},${(r.ns / 1e6).toFixed(2)},` +
    `${(r.blockedNs / ops).toFixed(1)},${(r.workedNs / ops).toFixed(1)},${ok}`);
}

interface Variant {
  name: string;
  impl: Impl;
  d: number;
}

// Batching without pipelining: naive vs b01_batch with b ops per posted task. Same t and w as the futures sweep.
async function runBatch(sink: LogSink, quick: boolean, reps: number): Promise<void> {
  const n = quick ? 512 : 2048;  // a multiple of every b
  const threads: number[] = quick ? [1] : [1, 4];
  const works: number[] = quick ? [0] : [0, 10000, 50000];
  const bs: number[] = [1, 2, 4, 8, 16, 32];
  // BENCH,b01b,variant,n,t,w,b,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok
  benchLine(sink, 'BENCH,b01b,variant,n,t,w,b,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok');
  await b01_naive(jsOp, { n: 200, w: 0, d: 0, t: 1 });
  await b01_batch(jsOp, { n: 200, w: 0, d: 0, t: 1, b: 8 });
  const variants: number[] = [0, ...bs];  // 0 = naive
  for (const t of threads) {
    for (const w of works) {
      for (let rep = 0; rep < reps; rep++) {
        for (let k = 0; k < variants.length; k++) {
          const b = variants[(k + rep) % variants.length];
          const cfg: B01Config = { n: n, w: w, d: 0, t: t, b: b === 0 ? 1 : b };
          const r = b === 0 ? await b01_naive(jsOp, cfg) : await b01_batch(jsOp, cfg);
          const ops = n * t;
          const ok = r.checksum === expectedChecksum(cfg) ? 1 : 0;
          benchLine(sink, `BENCH,b01b,${b === 0 ? 'naive' : 'batch'},${n},${t},${w},${cfg.b},${rep},` +
            `${(r.ns / ops).toFixed(1)},${(r.ns / 1e6).toFixed(2)},` +
            `${(r.blockedNs / ops).toFixed(1)},${(r.workedNs / ops).toFixed(1)},${ok}`);
          await yieldToSystem();
        }
      }
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps, 'batch' for the batching sweep
export async function runB01(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 500 : 2000;
  let reps = quick ? 2 : 7;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  if (opts.indexOf('batch') >= 0) {
    await runBatch(sink, quick, reps);
    return;
  }
  const threads: number[] = quick ? [1] : [1, 4];
  const works: number[] = quick ? [0, 10000] : [0, 2000, 10000, 50000];
  const variants: Variant[] = [
    { name: 'naive', impl: b01_naive, d: 0 },
    { name: 'opt', impl: b01_opt, d: 0 },
    { name: 'opt', impl: b01_opt, d: 1 },
    { name: 'opt', impl: b01_opt, d: 2 },
    { name: 'opt', impl: b01_opt, d: 4 },
    { name: 'opt', impl: b01_opt, d: 8 },
    { name: 'opt', impl: b01_opt, d: 16 },
  ];

  for (const w of works) {
    benchLine(sink, `BENCH,b01_spin,w=${w},avg_ns=${b01_spin_check(w, 2000).toFixed(1)}`);
  }
  benchLine(sink, 'BENCH,b01,variant,n,t,w,d,rep,ns_per_op,total_ms,blocked_per_op,worked_per_op,ok');
  // warmup both paths
  await b01_naive(jsOp, { n: 200, w: 0, d: 0, t: 1 });
  await b01_opt(jsOp, { n: 200, w: 0, d: 4, t: 1 });

  for (const t of threads) {
    for (const w of works) {
      for (let rep = 0; rep < reps; rep++) {
        // rotate the variant order each rep so every variant runs in every position (cancels DVFS drift)
        for (let k = 0; k < variants.length; k++) {
          const v = variants[(k + rep) % variants.length];
          await runOne(sink, v.name, v.impl, { n: n, w: w, d: v.d, t: t }, rep);
        }
      }
    }
  }
}
```

### Cangjie property access and coalescing

Original benchmark source or configuration.

File: `src/main/cangjie/b03_object_access.cj`.

<!-- embedded-file: src/main/cangjie/b03_object_access.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B03 - Coalescing accesses to one ArkTS object graph.
 *
 * ArkTS fixture: a chain of objects  L0.k0 -> L1.k1 -> ... -> L7.k7 = 42.
 * A "path read" of depth d starts at node L(8-d) and follows k(8-d) ... k7 down to the number.
 * Everything runs synchronously on the ArkTS thread: ArkTS calls in once, the loop is in Cangjie.
 *
 *   field:     d x getProperty("k_i")                      (what a user writes today)
 *   field_ck:  d x getProperty(key) with the JSString keys created once up front
 *              (separates the cost of converting the key String on every access)
 *   calls(k):  d/k calls of ArkTS getter functions, each doing k levels of access on the
 *              ArkTS side.  k = 1: every getProperty replaced by a function call.
 *                          k = d: the whole path bunched behind one function.
 *
 * Getters are named s<start>_<len> on the `fns` object, e.g. s4_2 = (o: L4) => o.k4.k5.
 * All JSFunction handles are fetched once, before the timed loop.
 *
 * ArkTS signature (identical for all):
 *   b03_{field,field_ck,calls}(root: Object, fns: Object, cfg: {d, k, n}): {ns, checksum}
 */

let B03_KEYS: Array<String> = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"]

// JS handles created inside the loop are released every B03_CHUNK path reads.
let B03_CHUNK = 64

func b03Result(runtime: JSContext, elapsedNs: Int64, checksum: Float64): JSValue {
    let res = runtime.object()
    res["ns"] = runtime.number(Float64(elapsedNs)).toJSValue()
    res["checksum"] = runtime.number(checksum).toJSValue()
    res.toJSValue()
}

// 1. field: one getProperty per level, key converted from a Cangjie String each time.
func b03Field(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let root = callInfo[0]
    let cfg = callInfo[2].asObject()
    let d = Int64(cfg["d"].toNumber())
    let n = Int64(cfg["n"].toNumber())

    var checksum = 0.0
    let t0 = nowNs()
    var i = 0
    while (i < n) {
        let chunk = if (n - i < B03_CHUNK) { n - i } else { B03_CHUNK }
        checksum += runtime.newScope({ =>
            var s = 0.0
            for (_ in 0..chunk) {
                var v = root
                for (level in (8 - d)..8) {
                    v = v.getProperty(B03_KEYS[level])
                }
                s += v.toNumber()
            }
            s
        })
        i += chunk
    }
    b03Result(runtime, nowNs() - t0, checksum)
}

// 1b. field_ck: same as field, but the keys are JSStrings created once, outside the loop.
func b03FieldCachedKeys(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let root = callInfo[0]
    let cfg = callInfo[2].asObject()
    let d = Int64(cfg["d"].toNumber())
    let n = Int64(cfg["n"].toNumber())
    let keys = Array<JSString>(8, { level => runtime.string(B03_KEYS[level]) })

    var checksum = 0.0
    let t0 = nowNs()
    var i = 0
    while (i < n) {
        let chunk = if (n - i < B03_CHUNK) { n - i } else { B03_CHUNK }
        checksum += runtime.newScope({ =>
            var s = 0.0
            for (_ in 0..chunk) {
                var v = root
                for (level in (8 - d)..8) {
                    v = v.getProperty(keys[level])
                }
                s += v.toNumber()
            }
            s
        })
        i += chunk
    }
    b03Result(runtime, nowNs() - t0, checksum)
}

// 2 and 3. calls(k): d/k getter calls per path read, each getter doing k levels on the ArkTS side.
func b03Calls(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let root = callInfo[0]
    let fns = callInfo[1].asObject()
    let cfg = callInfo[2].asObject()
    let d = Int64(cfg["d"].toNumber())
    let k = Int64(cfg["k"].toNumber())
    let n = Int64(cfg["n"].toNumber())

    // the getters covering levels (8-d)..8 in segments of k levels: s<start>_<k>
    let getters = ArrayList<JSFunction>()
    var start = 8 - d
    while (start < 8) {
        getters.add(fns.getProperty("s${start}_${k}").asFunction())
        start += k
    }

    var checksum = 0.0
    let t0 = nowNs()
    var i = 0
    while (i < n) {
        let chunk = if (n - i < B03_CHUNK) { n - i } else { B03_CHUNK }
        checksum += runtime.newScope({ =>
            var s = 0.0
            for (_ in 0..chunk) {
                var v = root
                for (g in getters) {
                    v = g.call(v)
                }
                s += v.toNumber()
            }
            s
        })
        i += chunk
    }
    b03Result(runtime, nowNs() - t0, checksum)
}

func b03Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b03_field"] = runtime.function(b03Field).toJSValue()
    exports["b03_field_ck"] = runtime.function(b03FieldCachedKeys).toJSValue()
    exports["b03_calls"] = runtime.function(b03Calls).toJSValue()
}
```

### ArkTS property access and coalescing

Original benchmark source or configuration.

File: `src/main/ets/bench/b03_object_access.ets`.

<!-- embedded-file: src/main/ets/bench/b03_object_access.ets -->

```typescript
import { systemDateTime } from '@kit.BasicServicesKit';
import { b03_field, b03_field_ck, b03_calls, B03Config, B03Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture: L0.k0 -> L1.k1 -> ... -> L7.k7 = 42 ----
class L7 { k7: number = 42; }
class L6 { k6: L7 = new L7(); }
class L5 { k5: L6 = new L6(); }
class L4 { k4: L5 = new L5(); }
class L3 { k3: L4 = new L4(); }
class L2 { k2: L3 = new L3(); }
class L1 { k1: L2 = new L2(); }
class L0 { k0: L1 = new L1(); }

const ROOT: L0 = new L0();
const LEAF = 42;

// A path of depth d starts at node L(8-d).
function startNode(d: number): Object {
  if (d === 8) {
    return ROOT;
  } else if (d === 4) {
    return ROOT.k0.k1.k2.k3;
  } else if (d === 2) {
    return ROOT.k0.k1.k2.k3.k4.k5;
  }
  return ROOT.k0.k1.k2.k3.k4.k5.k6;
}

// Getters s<start>_<len>: len levels of access starting at L<start>, done on the ArkTS side.
class B03Fns {
  s0_1 = (o: L0): L1 => o.k0;
  s1_1 = (o: L1): L2 => o.k1;
  s2_1 = (o: L2): L3 => o.k2;
  s3_1 = (o: L3): L4 => o.k3;
  s4_1 = (o: L4): L5 => o.k4;
  s5_1 = (o: L5): L6 => o.k5;
  s6_1 = (o: L6): L7 => o.k6;
  s7_1 = (o: L7): number => o.k7;
  s0_2 = (o: L0): L2 => o.k0.k1;
  s2_2 = (o: L2): L4 => o.k2.k3;
  s4_2 = (o: L4): L6 => o.k4.k5;
  s6_2 = (o: L6): number => o.k6.k7;
  s0_4 = (o: L0): L4 => o.k0.k1.k2.k3;
  s4_4 = (o: L4): number => o.k4.k5.k6.k7;
  s0_8 = (o: L0): number => o.k0.k1.k2.k3.k4.k5.k6.k7;
}

const FNS = new B03Fns();

// ---- Pure ArkTS baseline: the same path reads, no interop. A lower bound: the JIT may hoist loads. ----
function nativeLoop(d: number, n: number): number {
  let s = 0;
  if (d === 8) {
    const o = ROOT;
    for (let i = 0; i < n; i++) { s += o.k0.k1.k2.k3.k4.k5.k6.k7; }
  } else if (d === 4) {
    const o = ROOT.k0.k1.k2.k3;
    for (let i = 0; i < n; i++) { s += o.k4.k5.k6.k7; }
  } else if (d === 2) {
    const o = ROOT.k0.k1.k2.k3.k4.k5;
    for (let i = 0; i < n; i++) { s += o.k6.k7; }
  } else {
    const o = ROOT.k0.k1.k2.k3.k4.k5.k6;
    for (let i = 0; i < n; i++) { s += o.k7; }
  }
  return s;
}

type Impl = (root: Object, fns: Object, cfg: B03Config) => B03Result;

interface Variant {
  name: string;
  impl: Impl;
  k: number;  // levels per call (calls variant only; 0 otherwise)
}

function runOne(sink: LogSink, v: Variant, d: number, n: number, rep: number): void {
  const r = v.impl(startNode(d), FNS, { d: d, k: v.k, n: n });
  const ok = r.checksum === n * LEAF ? 1 : 0;
  // BENCH,b03,variant,d,k,n,rep,ns_per_path,ns_per_level,ok
  benchLine(sink, `BENCH,b03,${v.name},${d},${v.k},${n},${rep},` +
    `${(r.ns / n).toFixed(1)},${(r.ns / n / d).toFixed(1)},${ok}`);
}

function runNative(sink: LogSink, d: number, n: number, rep: number): void {
  const t0 = systemDateTime.getTime(true);
  const s = nativeLoop(d, n);
  const ns = systemDateTime.getTime(true) - t0;
  const ok = s === n * LEAF ? 1 : 0;
  benchLine(sink, `BENCH,b03,arkts_native,${d},0,${n},${rep},${(ns / n).toFixed(1)},${(ns / n / d).toFixed(1)},${ok}`);
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB03(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const n = quick ? 2000 : 20000;
  let reps = quick ? 2 : 15;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const depths: number[] = [1, 2, 4, 8];

  benchLine(sink, 'BENCH,b03,variant,d,k,n,rep,ns_per_path,ns_per_level,ok');
  for (const d of depths) {
    const variants: Variant[] = [
      { name: 'field', impl: b03_field, k: 0 },
      { name: 'field_ck', impl: b03_field_ck, k: 0 },
    ];
    for (const k of [1, 2, 4, 8]) {
      if (k <= d) {
        variants.push({ name: 'calls', impl: b03_calls, k: k });
      }
    }
    // warmup every variant at this depth
    for (const v of variants) {
      v.impl(startNode(d), FNS, { d: d, k: v.k, n: 2000 });
    }
    nativeLoop(d, n);

    for (let rep = 0; rep < reps; rep++) {
      // rotate the variant order each rep
      for (let j = 0; j < variants.length; j++) {
        runOne(sink, variants[(j + rep) % variants.length], d, n, rep);
        await yieldToSystem();
      }
      runNative(sink, d, n, rep);
      await yieldToSystem();
    }
  }
}
```

### Cangjie scoped object and string temporaries

Original benchmark source or configuration.

File: `src/main/cangjie/b07_temporaries.cj`.

<!-- embedded-file: src/main/cangjie/b07_temporaries.cj -->

```cangjie
package ohos_app_cangjie_entry

import ohos.ark_interop.*

/*
 * B07 - Temporaries bound as persistent references vs scoped values.
 *
 * "user" code binds intermediate values with asObject() / asArray() / asString() / runtime.string(),
 * so every temporary becomes a persistent reference (engine GC root + finalizable Cangjie object).
 * "generated" code binds the same temporaries as scoped JSValues. That is a hazard in hand-written
 * code (a scoped value must not outlive the current scope), acceptable in compiler-generated code,
 * where the compiler can check it.
 *
 *   objects: sum x[i].inner.v over an array of N objects        (user: 2 per element + 1 for the array)
 *   strings: N calls of f(s) = s + "!", string in, string out   (user: 2 per call)
 *
 * ArkTS signature:
 *   b07_objects(variant: string, xs: Object[]): number    // sum over the array
 *   b07_strings(variant: string, f: Function, n: number): number   // total length of the results
 */

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

func b07ObjectsUser(rt: JSContext, xs: JSValue): Float64 {
    rt.newScope({ =>
        let arr = xs.asArray()
        var sum = 0.0
        for (i in 0..arr.size) {
            let b = arr[i].asObject()
            let c = b["inner"].asObject()
            sum += c["v"].toNumber()
        }
        sum
    })
}

func b07ObjectsGenerated(rt: JSContext, xs: JSValue): Float64 {
    rt.newScope({ =>
        let n = Int64(xs.getProperty("length").toNumber())
        var sum = 0.0
        for (i in 0..n) {
            let b = xs.getElement(i)          // scoped: valid only in this scope
            let c = b.getProperty("inner")    // scoped
            sum += c.getProperty("v").toNumber()
        }
        sum
    })
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

func b07StringsUser(rt: JSContext, f: JSFunction, n: Int64): Float64 {
    rt.newScope({ =>
        var total = 0.0
        for (j in 0..n) {
            let arg = rt.string(B06_NAMES[j & 15])
            let res = f.call(arg.toJSValue()).asString()
            total += Float64(res.toString().size)
        }
        total
    })
}

func b07StringsGenerated(rt: JSContext, f: JSFunction, n: Int64): Float64 {
    rt.newScope({ =>
        var total = 0.0
        for (j in 0..n) {
            let arg = B06_NAMES[j & 15].toJSValue(rt)   // scoped
            let res = f.call(arg)                        // scoped
            total += Float64(res.toString().size)
        }
        total
    })
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

func b07Objects(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let variant = callInfo[0].toString()
    let xs = callInfo[1]
    let sum = if (variant == "user") { b07ObjectsUser(runtime, xs) } else { b07ObjectsGenerated(runtime, xs) }
    runtime.number(sum).toJSValue()
}

func b07Strings(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let variant = callInfo[0].toString()
    let f = callInfo[1].asFunction()   // calling requires a JSFunction in both variants
    let n = Int64(callInfo[2].toNumber())
    let total = if (variant == "user") { b07StringsUser(runtime, f, n) } else { b07StringsGenerated(runtime, f, n) }
    runtime.number(total).toJSValue()
}

func b07Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b07_objects"] = runtime.function(b07Objects).toJSValue()
    exports["b07_strings"] = runtime.function(b07Strings).toJSValue()
}
```

### ArkTS scoped object and string temporaries

Original benchmark source or configuration.

File: `src/main/ets/bench/b07_temporaries.ets`.

<!-- embedded-file: src/main/ets/bench/b07_temporaries.ets -->

```typescript
import { systemDateTime } from '@kit.BasicServicesKit';
import { b07_objects, b07_strings } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- Fixture: arrays of N objects {inner: {v: 1}} ----
class B07Inner {
  v: number = 1;
}

class B07Item {
  inner: B07Inner = new B07Inner();
}

const SIZES: number[] = [10, 100, 1000, 10000];
const TOTAL = 40000;  // elements (or calls) per measurement

function makeItems(n: number): B07Item[] {
  const a: B07Item[] = [];
  for (let i = 0; i < n; i++) {
    a.push(new B07Item());
  }
  return a;
}

const ARRAYS: B07Item[][] = SIZES.map((n: number) => makeItems(n));
const exclaim = (s: string): string => s + '!';

// One measurement: `passes` ArkTS -> Cangjie calls, each processing n elements; timed in ArkTS.
function measure(prog: string, variant: string, idx: number, passes: number): number[] {
  const n = SIZES[idx];
  let checksum = 0;
  const t0 = systemDateTime.getTime(true);
  if (prog === 'objects') {
    const xs = ARRAYS[idx];
    for (let p = 0; p < passes; p++) {
      checksum += b07_objects(variant, xs);
    }
  } else {
    for (let p = 0; p < passes; p++) {
      checksum += b07_strings(variant, exclaim, n);
    }
  }
  const ns = systemDateTime.getTime(true) - t0;
  return [ns, checksum];
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB07(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  const total = quick ? 4000 : TOTAL;
  let reps = quick ? 2 : 11;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const progs: string[] = ['objects', 'strings'];

  // warmup
  for (const prog of progs) {
    for (let idx = 0; idx < SIZES.length; idx++) {
      for (const v of ['user', 'generated']) {
        measure(prog, v, idx, 1);
      }
    }
    await yieldToSystem();
  }

  // BENCH,b07,prog,n,variant,passes,rep,ns_per_elem,checksum
  benchLine(sink, 'BENCH,b07,prog,n,variant,passes,rep,ns_per_elem,checksum');
  for (let rep = 0; rep < reps; rep++) {
    for (const prog of progs) {
      for (let idx = 0; idx < SIZES.length; idx++) {
        const n = SIZES[idx];
        const passes = Math.max(1, Math.floor(total / n));
        const order = rep % 2 === 0 ? ['user', 'generated'] : ['generated', 'user'];
        for (const v of order) {
          const r = measure(prog, v, idx, passes);
          benchLine(sink, `BENCH,b07,${prog},${n},${v},${passes},${rep},${(r[0] / (n * passes)).toFixed(1)},${r[1]}`);
          await yieldToSystem();
        }
      }
    }
  }
}
```

### Cangjie property key and string value caching

Original benchmark source or configuration.

File: `src/main/cangjie/b08_string_cache.cj`.

<!-- embedded-file: src/main/cangjie/b08_string_cache.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.collection.HashMap
import ohos.ark_interop.*

/*
 * B08 - String caching.
 *
 * Strings are immutable, so a Cangjie string can be bound once to a JSString and reused.
 * Program: export N Cangjie records {id, name, status, category} to an ArkTS array; per record,
 * create an object, set 4 properties, push it. Per record: 5 names (4 keys + "push") and 3 string values.
 * The 3 string fields draw from a pool of U distinct strings; U is the swept parameter.
 * The value cache is emptied before each measurement (not timed), so the hit rate is 1 - U/N.
 *
 *   naive:        names converted on every use; values created with runtime.string() on every use
 *   names:        names are JSString constants, created once (a compiler can do this for literals)
 *   names+values: as names; values looked up in a Cangjie-side cache HashMap<String, JSString>
 *
 * Same in all variants: runtime.object() (no alternative in the API) and the lookup of "push".
 *
 * ArkTS signature:
 *   b08_export(variant: string, list: Object[], n: number, u: number): {ns}
 */


// A record as held on the Cangjie side.
struct B08Record {
    B08Record(let id: Int64, let name: String, let status: String, let category: String) {}
}

// U distinct values of 10 characters: "value00042"
func b08Pool(u: Int64): Array<String> {
    Array<String>(u, { i =>
        let digits = "${i}"
        "value" + b04Repeat("0", 5 - digits.size) + digits
    })
}

func b08Records(n: Int64, u: Int64): Array<B08Record> {
    let pool = b08Pool(u)
    Array<B08Record>(n, { i => B08Record(i, pool[i % u], pool[(i * 7 + 1) % u], pool[(i * 13 + 2) % u]) })
}

// Names as JSString constants, created once per context.
class B08Names {
    let id: JSString
    let name: JSString
    let status: JSString
    let category: JSString
    let push: JSString

    init(rt: JSContext) {
        id = rt.string("id")
        name = rt.string("name")
        status = rt.string("status")
        category = rt.string("category")
        push = rt.string("push")
    }
}

// Value cache: Cangjie string -> JSString, created on first use.
class B08ValueCache {
    let map = HashMap<String, JSString>()
}

func b08Cached(rt: JSContext, cache: B08ValueCache, s: String): JSString {
    match (cache.map.get(s)) {
        case Some(js) => js
        case None =>
            let js = rt.string(s)
            cache.map.add(s, js)
            js
    }
}

class B08State {
    var names: ?B08Names = None
    var cache: B08ValueCache = B08ValueCache()
    var records: Array<B08Record> = Array<B08Record>()
    var recordsU: Int64 = -1
}

let B08_STATE = B08State()

// ---------------------------------------------------------------------------
// The three variants. One pass exports all records.
// ---------------------------------------------------------------------------

func b08Naive(rt: JSContext, list: JSObject, recs: Array<B08Record>): Unit {
    rt.newScope({ =>
        for (r in recs) {
            let o = rt.object()
            o.setProperty("id", rt.number(Float64(r.id)).toJSValue())
            o.setProperty("name", rt.string(r.name).toJSValue())
            o.setProperty("status", rt.string(r.status).toJSValue())
            o.setProperty("category", rt.string(r.category).toJSValue())
            list.callMethod("push", [o.toJSValue()])
        }
    })
}

func b08Names(rt: JSContext, list: JSObject, recs: Array<B08Record>, k: B08Names): Unit {
    rt.newScope({ =>
        for (r in recs) {
            let o = rt.object()
            o.setProperty(k.id, rt.number(Float64(r.id)).toJSValue())
            o.setProperty(k.name, rt.string(r.name).toJSValue())
            o.setProperty(k.status, rt.string(r.status).toJSValue())
            o.setProperty(k.category, rt.string(r.category).toJSValue())
            list.callMethod(k.push, [o.toJSValue()])
        }
    })
}

func b08NamesValues(rt: JSContext, list: JSObject, recs: Array<B08Record>, k: B08Names, cache: B08ValueCache): Unit {
    rt.newScope({ =>
        for (r in recs) {
            let o = rt.object()
            o.setProperty(k.id, rt.number(Float64(r.id)).toJSValue())
            o.setProperty(k.name, b08Cached(rt, cache, r.name).toJSValue())
            o.setProperty(k.status, b08Cached(rt, cache, r.status).toJSValue())
            o.setProperty(k.category, b08Cached(rt, cache, r.category).toJSValue())
            list.callMethod(k.push, [o.toJSValue()])
        }
    })
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

func b08Export(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let variant = callInfo[0].toString()
    let list = callInfo[1].asObject()
    let n = Int64(callInfo[2].toNumber())
    let u = Int64(callInfo[3].toNumber())

    // setup, not timed: names created once per context; records per (n, u); value cache emptied
    let st = B08_STATE
    if (st.names.isNone()) {
        st.names = B08Names(runtime)
    }
    if (st.records.size != n || st.recordsU != u) {
        st.records = b08Records(n, u)
        st.recordsU = u
    }
    st.cache = B08ValueCache()
    let k = st.names.getOrThrow()
    let recs = st.records

    let t0 = nowNs()
    match (variant) {
        case "naive" => b08Naive(runtime, list, recs)
        case "names" => b08Names(runtime, list, recs, k)
        case _ => b08NamesValues(runtime, list, recs, k, st.cache)
    }
    let elapsed = nowNs() - t0

    let res = runtime.object()
    res["ns"] = runtime.number(Float64(elapsed)).toJSValue()
    res.toJSValue()
}

func b08Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b08_export"] = runtime.function(b08Export).toJSValue()
}
```

### ArkTS property key and string value caching

Original benchmark source or configuration.

File: `src/main/ets/bench/b08_string_cache.ets`.

<!-- embedded-file: src/main/ets/bench/b08_string_cache.ets -->

```typescript
import { b08_export, B08Result } from 'libohos_app_cangjie_entry.so';
import { benchLine, LogSink, yieldToSystem } from './Log';

// The ArkTS side of the view model: an array the records are pushed into.
class B08Row {
  id: number = 0;
  name: string = '';
  status: string = '';
  category: string = '';
}

// Checksum over what arrived, independent of how it was produced.
function checksum(list: B08Row[]): number {
  let s = 0;
  for (const r of list) {
    s += r.id + r.name.length * 3 + r.status.length * 5 + r.category.length * 7;
  }
  return s;
}

const N = 10000;
const U_VALUES: number[] = [1, 10, 100, 1000, 10000];

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB08(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  let reps = quick ? 2 : 11;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const variants: string[] = ['naive', 'names', 'names+values'];
  const list: B08Row[] = [];

  // warmup
  for (const v of variants) {
    b08_export(v, list, N, 100);
    list.length = 0;
    await yieldToSystem();
  }

  // BENCH,b08,u,variant,n,rep,ns_per_record,checksum
  benchLine(sink, 'BENCH,b08,u,variant,n,rep,ns_per_record,checksum');
  for (let rep = 0; rep < reps; rep++) {
    for (const u of U_VALUES) {
      for (let k = 0; k < variants.length; k++) {
        const v = variants[(k + rep) % variants.length];
        const r: B08Result = b08_export(v, list, N, u);
        const cs = checksum(list);
        const ok = list.length === N;
        list.length = 0;
        benchLine(sink, `BENCH,b08,${u},${v},${N},${rep},${(r.ns / N).toFixed(1)},${ok ? cs : -1}`);
        await yieldToSystem();
      }
    }
  }
}
```

### Cangjie combined search application

Original benchmark source or configuration.

File: `src/main/cangjie/b09_search.cj`.

<!-- embedded-file: src/main/cangjie/b09_search.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.sync.*
import std.collection.ArrayList
import std.collection.HashMap
import ohos.ark_interop.*

/*
 * B09 - Search-as-you-type, with all optimisations behind switches.
 *
 * ArkTS holds a list of N items {id, meta: {title, brand, description}, price: {amount}}. Cangjie worker threads
 * score every item against a query (approximate substring edit distance, Sellers' algorithm: the number of edits
 * needed for the query to occur in title + " " + description) and push a result {id, score, kind, brand, price} onto an
 * ArkTS results array. Workers never touch JS values: reads and writes are tasks posted to the ArkTS thread.
 *
 * Switches (each independent; the ArkTS side is identical in every configuration):
 *   futures   off: wait for every posted read and write immediately
 *             on:  reads issued d items ahead; writes waited for only at the end
 *   coalesce  off: read id, meta.title, meta.brand, meta.description, price.amount with 8 property/element reads
 *             on:  one call of an ArkTS reader returning [id, title, brand, amount, description], then 5 element reads
 *   scoped    off: temporaries (item, meta, price, reader result) bound with asObject()/asArray();
 *                  string values written with runtime.string()
 *             on:  the same temporaries and values as scoped JSValues
 *   cache     off: property/method names converted on every use; string values created on every use
 *             on:  names created once; string values (kind, brand) reused through a String -> JSString cache
 *   b         items per posted task (default 1): one task reads b items, one task writes their b results.
 *             With futures, reads are issued ceil(d / b) tasks ahead, i.e. about d items ahead as with b = 1.
 *
 * ArkTS signature:
 *   b09_run(cfg: {futures, coalesce, scoped, cache, d, t, b?}, list: Item[], results: Object[],
 *           reader: (list, i) => Object[], query: string): Promise<{ns, errors}>
 */

// ---------------------------------------------------------------------------
// The computation: approximate substring distance and match kind.
// ---------------------------------------------------------------------------

// Minimum edit distance between q and any substring of t (Sellers 1980). Cost: |q| x |t| cells.
func b09SubstringDistance(q: Array<Rune>, t: Array<Rune>): Int64 {
    let m = q.size
    var prev = Array<Int64>(m + 1, { i => i })
    var cur = Array<Int64>(m + 1, repeat: 0)
    var best = m
    for (j in 0..t.size) {
        cur[0] = 0
        for (i in 1..=m) {
            let sub = prev[i - 1] + (if (q[i - 1] == t[j]) { 0 } else { 1 })
            let del = prev[i] + 1
            let ins = cur[i - 1] + 1
            var v = sub
            if (del < v) { v = del }
            if (ins < v) { v = ins }
            cur[i] = v
        }
        if (cur[m] < best) { best = cur[m] }
        let tmp = prev
        prev = cur
        cur = tmp
    }
    best
}

class B09Item {
    var id: Float64 = 0.0
    var title: String = ""
    var brand: String = ""
    var amount: Float64 = 0.0
    var description: String = ""
}

class B09Score {
    var score: Float64 = 0.0
    var kind: String = "none"
}

func b09Score(query: Array<Rune>, queryStr: String, it: B09Item): B09Score {
    let r = B09Score()
    let dist = b09SubstringDistance(query, (it.title + " " + it.description).toRuneArray())
    r.score = 1.0 - Float64(dist) / Float64(query.size)
    r.kind = if (it.title.startsWith(queryStr)) {
        "prefix"
    } else if (dist == 0) {
        "match"
    } else if (dist <= 2) {
        "fuzzy"
    } else {
        "none"
    }
    r
}

// ---------------------------------------------------------------------------
// Names (keys): created once as JSString when caching, otherwise Cangjie Strings converted on every use.
// ---------------------------------------------------------------------------

class B09Keys {
    let id: JSKeyable
    let meta: JSKeyable
    let title: JSKeyable
    let description: JSKeyable
    let brand: JSKeyable
    let price: JSKeyable
    let amount: JSKeyable
    let score: JSKeyable
    let kind: JSKeyable
    let push: JSKeyable

    init(rt: JSContext, cached: Bool) {
        id = if (cached) { rt.string("id") } else { "id" }
        meta = if (cached) { rt.string("meta") } else { "meta" }
        title = if (cached) { rt.string("title") } else { "title" }
        description = if (cached) { rt.string("description") } else { "description" }
        brand = if (cached) { rt.string("brand") } else { "brand" }
        price = if (cached) { rt.string("price") } else { "price" }
        amount = if (cached) { rt.string("amount") } else { "amount" }
        score = if (cached) { rt.string("score") } else { "score" }
        kind = if (cached) { rt.string("kind") } else { "kind" }
        push = if (cached) { rt.string("push") } else { "push" }
    }
}

// ---------------------------------------------------------------------------
// State of one run. Everything here is created on the ArkTS thread before the workers start.
// ---------------------------------------------------------------------------

class B09Run {
    var futures = false
    var coalesce = false
    var scoped = false
    var cache = false
    var d = 8
    var t = 1
    var b = 1
    let rt: JSContext
    let list: JSArray          // persisted once: used from posted tasks
    let results: JSObject      // persisted once
    let reader: JSFunction     // persisted once
    let keys: B09Keys
    let values = HashMap<String, JSString>()   // value cache, used only on the ArkTS thread
    let query: Array<Rune>
    let queryStr: String
    let n: Int64
    let errors = AtomicInt64(0)

    init(rt: JSContext, cfg: JSObject, list: JSArray, results: JSObject, reader: JSFunction, query: String) {
        this.rt = rt
        futures = cfg["futures"].toBoolean()
        coalesce = cfg["coalesce"].toBoolean()
        scoped = cfg["scoped"].toBoolean()
        cache = cfg["cache"].toBoolean()
        d = Int64(cfg["d"].toNumber())
        t = Int64(cfg["t"].toNumber())
        if (cfg["b"].isNumber()) {
            b = Int64(cfg["b"].toNumber())
        }
        this.list = list
        this.results = results
        this.reader = reader
        keys = B09Keys(rt, cache)
        this.query = query.toRuneArray()
        queryStr = query
        n = list.size
    }
}

// A string value to be written: cached JSString, scoped value, or a new persistent JSString.
func b09StringValue(st: B09Run, s: String): JSValue {
    if (st.cache) {
        match (st.values.get(s)) {
            case Some(js) => js.toJSValue()
            case None =>
                let js = st.rt.string(s)
                st.values.add(s, js)
                js.toJSValue()
        }
    } else if (st.scoped) {
        s.toJSValue(st.rt)
    } else {
        st.rt.string(s).toJSValue()
    }
}

// ---------------------------------------------------------------------------
// Read and write, executed on the ArkTS thread.
// ---------------------------------------------------------------------------

func b09Read(st: B09Run, i: Int64): B09Item {
    let rt = st.rt
    let k = st.keys
    rt.newScope({ =>
        let it = B09Item()
        if (st.coalesce) {
            let r = st.reader.call([st.list.toJSValue(), rt.number(Float64(i)).toJSValue()])
            if (st.scoped) {
                it.id = r.getElement(0).toNumber()
                it.title = r.getElement(1).toString()
                it.brand = r.getElement(2).toString()
                it.amount = r.getElement(3).toNumber()
                it.description = r.getElement(4).toString()
            } else {
                let a = r.asArray()
                it.id = a[0].toNumber()
                it.title = a[1].toString()
                it.brand = a[2].toString()
                it.amount = a[3].toNumber()
                it.description = a[4].toString()
            }
        } else {
            if (st.scoped) {
                let item = st.list[i]
                let meta = item.getProperty(k.meta)
                let price = item.getProperty(k.price)
                it.id = item.getProperty(k.id).toNumber()
                it.title = meta.getProperty(k.title).toString()
                it.brand = meta.getProperty(k.brand).toString()
                it.amount = price.getProperty(k.amount).toNumber()
                it.description = meta.getProperty(k.description).toString()
            } else {
                let item = st.list[i].asObject()
                let meta = item[k.meta].asObject()
                let price = item[k.price].asObject()
                it.id = item[k.id].toNumber()
                it.title = meta[k.title].toString()
                it.brand = meta[k.brand].toString()
                it.amount = price[k.amount].toNumber()
                it.description = meta[k.description].toString()
            }
        }
        it
    })
}

func b09Write(st: B09Run, it: B09Item, sc: B09Score): Unit {
    let rt = st.rt
    let k = st.keys
    rt.newScope({ =>
        let o = rt.object()
        o.setProperty(k.id, rt.number(it.id).toJSValue())
        o.setProperty(k.score, rt.number(sc.score).toJSValue())
        o.setProperty(k.kind, b09StringValue(st, sc.kind))
        o.setProperty(k.brand, b09StringValue(st, it.brand))
        o.setProperty(k.price, rt.number(it.amount).toJSValue())
        st.results.callMethod(k.push, [o.toJSValue()])
    })
}

// ---------------------------------------------------------------------------
// Futures for posted reads and writes.
// ---------------------------------------------------------------------------

class B09ReadFuture {
    var mutex: Mutex = Mutex()
    var cond: ?Condition = None
    var done: Bool = false
    var items: Array<B09Item> = Array<B09Item>()
}

// One posted task reads the items at the given indices.
func b09PostRead(st: B09Run, idxs: Array<Int64>): B09ReadFuture {
    let f = B09ReadFuture()
    f.cond = synchronized(f.mutex) { f.mutex.condition() }
    st.rt.postJSTask({ =>
        let items = Array<B09Item>(idxs.size, { j =>
            try {
                b09Read(st, idxs[j])
            } catch (e: Exception) {
                st.errors.fetchAdd(1)
                B09Item()
            }
        })
        synchronized(f.mutex) {
            f.items = items
            f.done = true
            f.cond.getOrThrow().notifyAll()
        }
    })
    f
}

func b09WaitRead(f: B09ReadFuture): Array<B09Item> {
    synchronized(f.mutex) {
        while (!f.done) {
            f.cond.getOrThrow().wait()
        }
        f.items
    }
}

// One posted task writes the results of the given items.
func b09PostWrite(st: B09Run, items: Array<B09Item>, scores: Array<B09Score>): B01Future {
    let f = b01NewFuture()
    st.rt.postJSTask({ =>
        for (j in 0..items.size) {
            try {
                b09Write(st, items[j], scores[j])
            } catch (e: Exception) {
                st.errors.fetchAdd(1)
            }
        }
        b01Complete(f, 0.0)
    })
    f
}

func b09ScoreAll(st: B09Run, items: Array<B09Item>): Array<B09Score> {
    Array<B09Score>(items.size, { j => b09Score(st.query, st.queryStr, items[j]) })
}

// ---------------------------------------------------------------------------
// Worker k handles items k, k + t, k + 2t, ..., in groups of b items (one posted read and one posted write per group).
// ---------------------------------------------------------------------------

func b09Worker(st: B09Run, k: Int64): Unit {
    let mine = ArrayList<Int64>()
    var i = k
    while (i < st.n) {
        mine.add(i)
        i += st.t
    }
    let groups = ArrayList<Array<Int64>>()
    var g = 0
    while (g < mine.size) {
        let end = if (g + st.b < mine.size) { g + st.b } else { mine.size }
        let from = g
        groups.add(Array<Int64>(end - from, { j => mine[from + j] }))
        g = end
    }
    if (!st.futures) {
        for (grp in groups) {
            let items = b09WaitRead(b09PostRead(st, grp))
            b01Wait(b09PostWrite(st, items, b09ScoreAll(st, items)))
        }
        return
    }
    // futures: reads issued d groups ahead (d = ceil(d / b)), writes waited for at the end
    let d = (st.d + st.b - 1) / st.b
    let ring = Array<?B09ReadFuture>(d + 1, repeat: None)
    let writes = ArrayList<B01Future>()
    for (j in 0..groups.size) {
        ring[j % (d + 1)] = b09PostRead(st, groups[j])
        if (j >= d) {
            let items = b09WaitRead(ring[(j - d) % (d + 1)].getOrThrow())
            writes.add(b09PostWrite(st, items, b09ScoreAll(st, items)))
        }
    }
    let from = if (groups.size > d) { groups.size - d } else { 0 }
    for (j in from..groups.size) {
        let items = b09WaitRead(ring[j % (d + 1)].getOrThrow())
        writes.add(b09PostWrite(st, items, b09ScoreAll(st, items)))
    }
    for (w in writes) {
        b01Wait(w)
    }
}

// ---------------------------------------------------------------------------
// Entry point: returns a Promise; the ArkTS thread stays free to run the posted tasks.
// ---------------------------------------------------------------------------

func b09Run(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let st = B09Run(runtime, callInfo[0].asObject(), callInfo[1].asArray(), callInfo[2].asObject(),
        callInfo[3].asFunction(), callInfo[4].toString())
    let promise = runtime.promiseCapability()
    spawn {
        let t0 = nowNs()
        let workers = ArrayList<Future<Unit>>()
        for (k in 0..st.t) {
            workers.add(spawn { b09Worker(st, k) })
        }
        for (w in workers) {
            w.get()
        }
        let elapsed = nowNs() - t0
        let errors = st.errors.load()
        runtime.postJSTask({ =>
            let res = runtime.object()
            res["ns"] = runtime.number(Float64(elapsed)).toJSValue()
            res["errors"] = runtime.number(Float64(errors)).toJSValue()
            promise.resolve(res.toJSValue())
        })
    }
    promise.toJSValue()
}

func b09Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b09_run"] = runtime.function(b09Run).toJSValue()
}
```

### ArkTS combined search application

Original benchmark source or configuration.

File: `src/main/ets/bench/b09_search.ets`.

<!-- embedded-file: src/main/ets/bench/b09_search.ets -->

```typescript
import { b09_run, B09Config, B09Result } from 'libohos_app_cangjie_entry.so';
import { systemDateTime } from '@kit.BasicServicesKit';
import { benchLine, LogSink, yieldToSystem } from './Log';

// ---- The UI's data: a catalogue of items ----
class B09Meta {
  title: string;
  brand: string;
  description: string;

  constructor(title: string, brand: string, description: string) {
    this.title = title;
    this.brand = brand;
    this.description = description;
  }
}

class B09Price {
  amount: number;

  constructor(amount: number) {
    this.amount = amount;
  }
}

export class B09ItemTS {
  id: number;
  meta: B09Meta;
  price: B09Price;

  constructor(id: number, meta: B09Meta, price: B09Price) {
    this.id = id;
    this.meta = meta;
    this.price = price;
  }
}

export class B09ResultRow {
  id: number = 0;
  score: number = 0;
  kind: string = '';
  brand: string = '';
  price: number = 0;
}

const WORDS: string[] = ['wireless', 'wirless', 'wired', 'noise', 'cancelling', 'headphones', 'speaker', 'portable',
  'bluetooth', 'charger', 'black', 'white', 'pro', 'mini', 'smart', 'watch', 'band', 'case', 'cable', 'usb', 'fast',
  'sport', 'earbuds', 'stereo', 'wireles', 'wire', 'less', 'studio'];
const BRANDS: string[] = ['sonora', 'axiom', 'veltra', 'nimbus', 'orbit', 'kestrel', 'lumen', 'tarsus'];

// Deterministic catalogue: titles of about `titleLen` characters and descriptions of about `descLen`
// characters, built from WORDS.
export function makeCatalogue(n: number, titleLen: number, descLen: number = 0): B09ItemTS[] {
  let seed = 12345;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  const items: B09ItemTS[] = [];
  for (let i = 0; i < n; i++) {
    let title = WORDS[rnd(WORDS.length)];
    while (title.length < titleLen) {
      title = title + ' ' + WORDS[rnd(WORDS.length)];
    }
    let description = '';
    while (description.length < descLen) {
      description = description.length === 0 ? WORDS[rnd(WORDS.length)] : description + ' ' + WORDS[rnd(WORDS.length)];
    }
    items.push(new B09ItemTS(i, new B09Meta(title, BRANDS[rnd(BRANDS.length)], description), new B09Price(10 + rnd(990))));
  }
  return items;
}

// Used by the coalesced variant: one call returns all the fields Cangjie needs.
export const reader = (list: Object[], i: number): Object[] => {
  const it = list[i] as B09ItemTS;
  return [it.id, it.meta.title, it.meta.brand, it.price.amount, it.meta.description];
};

function kindCode(k: string): number {
  return k === 'prefix' ? 1 : k === 'match' ? 2 : k === 'fuzzy' ? 3 : 4;
}

// Checksum over the results as the UI receives them, independent of their order.
function checksum(rows: B09ResultRow[]): number {
  let s = 0;
  for (const r of rows) {
    s += Math.round(r.score * 1000) + kindCode(r.kind) * 7 + r.brand.length * 11 + r.id + r.price;
  }
  return s;
}

const QUERY = 'wireless';

// ---- The same search written entirely in ArkTS (single-threaded, on the ArkTS thread) ----
// Minimum edit distance between q and any substring of t (Sellers 1980), as in b09_search.cj.
function substringDistance(q: string, t: string): number {
  const m = q.length;
  let prev: number[] = [];
  let cur: number[] = [];
  for (let i = 0; i <= m; i++) {
    prev.push(i);
    cur.push(0);
  }
  let best = m;
  for (let j = 0; j < t.length; j++) {
    cur[0] = 0;
    const tc = t.charCodeAt(j);
    for (let i = 1; i <= m; i++) {
      const sub = prev[i - 1] + (q.charCodeAt(i - 1) === tc ? 0 : 1);
      const del = prev[i] + 1;
      const ins = cur[i - 1] + 1;
      let v = sub;
      if (del < v) { v = del; }
      if (ins < v) { v = ins; }
      cur[i] = v;
    }
    if (cur[m] < best) { best = cur[m]; }
    const tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return best;
}

export function searchArkTS(list: B09ItemTS[], results: B09ResultRow[], query: string): void {
  for (const it of list) {
    const title = it.meta.title;
    const dist = substringDistance(query, title + ' ' + it.meta.description);
    const row = new B09ResultRow();
    row.id = it.id;
    row.score = 1 - dist / query.length;
    row.kind = title.startsWith(query) ? 'prefix' : dist === 0 ? 'match' : dist <= 2 ? 'fuzzy' : 'none';
    row.brand = it.meta.brand;
    row.price = it.price.amount;
    results.push(row);
  }
}

interface Flags {
  futures: boolean;
  coalesce: boolean;
  scoped: boolean;
  cache: boolean;
}

function allFlags(): Flags[] {
  const out: Flags[] = [];
  for (let m = 0; m < 16; m++) {
    out.push({ futures: (m & 8) !== 0, coalesce: (m & 4) !== 0, scoped: (m & 2) !== 0, cache: (m & 1) !== 0 });
  }
  return out;
}

// Text-length sweep: description of L characters; pure ArkTS vs Cangjie naive vs Cangjie with all optimisations
// (futures, batching b = 8, coalesce, scoped, cache). The number of items shrinks as L grows so that each
// measurement stays short.
const SWEEP: number[][] = [[0, 1000], [50, 1000], [100, 1000], [200, 1000], [500, 500], [1000, 250]];  // [L, items]

interface SweepVariant {
  name: string;
  t: number;      // workers (0 for pure ArkTS)
  allOn: boolean;
}

async function textSweep(sink: LogSink, reps: number): Promise<void> {
  const variants: SweepVariant[] = [
    { name: 'arkts', t: 0, allOn: false },
    { name: 'naive', t: 1, allOn: false }, { name: 'naive', t: 4, allOn: false },
    { name: 'optimised', t: 1, allOn: true }, { name: 'optimised', t: 4, allOn: true },
  ];
  // BENCH,b09t,L,n,variant,t,rep,us_per_item,checksum,errors  (variants in a new random order every rep)
  benchLine(sink, 'BENCH,b09t,L,n,variant,t,rep,us_per_item,checksum,errors');
  let seed = 11;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  for (const cfgL of SWEEP) {
    const L = cfgL[0];
    const n = cfgL[1];
    const list = makeCatalogue(n, 40, L);
    const results: B09ResultRow[] = [];
    // warmup each variant once at this length
    for (const v of variants) {
      await sweepOne(v, list, results);
      results.length = 0;
      await yieldToSystem();
    }
    for (let rep = 0; rep < reps; rep++) {
      const order: number[] = [];
      for (let k = 0; k < variants.length; k++) {
        order.push(k);
      }
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (const k of order) {
        const v = variants[k];
        const r = await sweepOne(v, list, results);
        const cs = results.length === n ? checksum(results) : -1;
        results.length = 0;
        benchLine(sink, `BENCH,b09t,${L},${n},${v.name},${v.t},${rep},${(r[0] / n / 1000).toFixed(2)},${cs},${r[1]}`);
        await yieldToSystem();
      }
    }
  }
}

// Returns [ns, errors].
async function sweepOne(v: SweepVariant, list: B09ItemTS[], results: B09ResultRow[]): Promise<number[]> {
  if (v.t === 0) {
    const t0 = systemDateTime.getTime(true);
    searchArkTS(list, results, QUERY);
    return [systemDateTime.getTime(true) - t0, 0];
  }
  const cfg: B09Config = { futures: v.allOn, coalesce: v.allOn, scoped: v.allOn, cache: v.allOn, d: 8, t: v.t,
    b: v.allOn ? 8 : 1 };
  const r: B09Result = await b09_run(cfg, list, results, reader, QUERY);
  return [r.ns, r.errors];
}

// Batching: futures off/on x (coalesce, scoped, cache) all off/all on x b = 1/8 items per posted task,
// for 1 and 4 threads, each rep in a new random order.
async function batchGrid(sink: LogSink, list: B09ItemTS[], n: number, titleLen: number, descLen: number,
  reps: number): Promise<void> {
  const cfgs: B09Config[] = [];
  for (const t of [1, 4]) {
    for (const fut of [false, true]) {
      for (const all of [false, true]) {
        for (const b of [1, 8]) {
          cfgs.push({ futures: fut, coalesce: all, scoped: all, cache: all, d: 8, t: t, b: b });
        }
      }
    }
  }
  const results: B09ResultRow[] = [];
  for (const c of cfgs) {  // warmup
    await b09_run(c, list, results, reader, QUERY);
    results.length = 0;
    await yieldToSystem();
  }
  let seed = 7;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  // prev: index into the configuration list of the one measured just before; -1 = pure ArkTS
  benchLine(sink, 'BENCH,b09b,t,futures,others,b,n,title_len,desc_len,rep,us_per_item,checksum,errors,prev');
  for (let rep = 0; rep < reps; rep++) {
    const t0 = systemDateTime.getTime(true);
    searchArkTS(list, results, QUERY);
    const ns = systemDateTime.getTime(true) - t0;
    const csA = results.length === n ? checksum(results) : -1;
    results.length = 0;
    benchLine(sink, `BENCH,b09b,0,0,0,0,${n},${titleLen},${descLen},${rep},${(ns / n / 1000).toFixed(2)},${csA},0,-1`);
    await yieldToSystem();
    const order: number[] = [];
    for (let k = 0; k < cfgs.length; k++) {
      order.push(k);
    }
    for (let k = order.length - 1; k > 0; k--) {
      const j = rnd(k + 1);
      const tmp = order[k];
      order[k] = order[j];
      order[j] = tmp;
    }
    let prev = -1;
    for (const k of order) {
      const c = cfgs[k];
      const r: B09Result = await b09_run(c, list, results, reader, QUERY);
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09b,${c.t},${c.futures ? 1 : 0},${c.coalesce ? 1 : 0},${c.b},${n},${titleLen},${descLen},` +
        `${rep},${(r.ns / n / 1000).toFixed(2)},${cs},${r.errors},${prev}`);
      prev = k;
      await yieldToSystem();
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps
export async function runB09(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  // 'descN': items get a description of N characters; fewer items for longer texts
  let descLen = 0;
  for (const o of opts) {
    if (o.startsWith('desc')) {
      descLen = Number.parseInt(o.substring(4));
    }
  }
  const n = quick ? 200 : descLen >= 5000 ? 60 : descLen >= 1000 ? 250 : 1000;
  const titleLen = 40;
  const d = 8;
  let reps = quick ? 1 : 5;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  const list = makeCatalogue(n, titleLen, descLen);
  const results: B09ResultRow[] = [];
  const flags = allFlags();

  if (opts.indexOf('batch') >= 0) {
    await batchGrid(sink, list, n, titleLen, descLen, reps);
    return;
  }
  if (opts.indexOf('textsweep') >= 0) {
    await textSweep(sink, reps);
    return;
  }
  if (opts.indexOf('arkts') >= 0) {
    for (let w = 0; w < 3; w++) {  // warmup
      searchArkTS(list, results, QUERY);
      results.length = 0;
    }
    // BENCH,b09_arkts,n,title_len,rep,us_per_item,checksum
    benchLine(sink, 'BENCH,b09_arkts,n,title_len,rep,us_per_item,checksum');
    for (let rep = 0; rep < reps; rep++) {
      const t0 = systemDateTime.getTime(true);
      searchArkTS(list, results, QUERY);
      const ns = systemDateTime.getTime(true) - t0;
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09_arkts,${n},${titleLen},${rep},${(ns / n / 1000).toFixed(2)},${cs}`);
      await yieldToSystem();
    }
    return;
  }
  const threads: number[] = [1, 4];

  // warmup: all off and all on
  for (const t of threads) {
    for (const f of [flags[0], flags[15]]) {
      const cfg: B09Config = { futures: f.futures, coalesce: f.coalesce, scoped: f.scoped, cache: f.cache, d: d, t: t };
      await b09_run(cfg, list, results, reader, QUERY);
      results.length = 0;
      await yieldToSystem();
    }
  }

  // BENCH,b09,t,futures,coalesce,scoped,cache,n,title_len,desc_len,rep,us_per_item,checksum,errors
  // (t = 0 rows are the pure-ArkTS reference)
  // prev: index (0..15, bits futures/coalesce/scoped/cache) of the configuration measured just before; -1 = pure ArkTS
  benchLine(sink, 'BENCH,b09,t,futures,coalesce,scoped,cache,n,title_len,desc_len,rep,us_per_item,checksum,errors,prev');
  let seed = 2024;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };
  for (let rep = 0; rep < reps; rep++) {
    {
      const t0 = systemDateTime.getTime(true);
      searchArkTS(list, results, QUERY);
      const ns = systemDateTime.getTime(true) - t0;
      const cs = results.length === n ? checksum(results) : -1;
      results.length = 0;
      benchLine(sink, `BENCH,b09,0,0,0,0,0,${n},${titleLen},${descLen},${rep},${(ns / n / 1000).toFixed(2)},${cs},0,-1`);
      await yieldToSystem();
    }
    let prev = -1;  // the pure-ArkTS run above
    for (const t of threads) {
      // a new random order every rep, so no configuration always follows the same one
      const order: number[] = [];
      for (let k = 0; k < flags.length; k++) {
        order.push(k);
      }
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (let k = 0; k < flags.length; k++) {
        const f = flags[order[k]];
        const cfg: B09Config = { futures: f.futures, coalesce: f.coalesce, scoped: f.scoped, cache: f.cache, d: d, t: t };
        const r: B09Result = await b09_run(cfg, list, results, reader, QUERY);
        const ok = results.length === n;
        const cs = ok ? checksum(results) : -1;
        results.length = 0;
        benchLine(sink, `BENCH,b09,${t},${f.futures ? 1 : 0},${f.coalesce ? 1 : 0},${f.scoped ? 1 : 0},${f.cache ? 1 : 0},` +
          `${n},${titleLen},${descLen},${rep},${(r.ns / n / 1000).toFixed(2)},${cs},${r.errors},${prev}`);
        prev = order[k];
        await yieldToSystem();
      }
    }
  }
}
```

### Cangjie combined graph application

Original benchmark source or configuration.

File: `src/main/cangjie/b12_graph.cj`.

<!-- embedded-file: src/main/cangjie/b12_graph.cj -->

```cangjie
package ohos_app_cangjie_entry

import std.sync.*
import std.math.sqrt
import std.math.floor
import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B12 - Live force-directed graph layout.
 *
 * ArkTS renders N nodes {x, y, pinned, color, label}; the UI is bound to these objects and the user may drag
 * (and pin) nodes between frames. Every frame Cangjie runs one simulation step:
 *   read   x, y, pinned of every node (the user may have moved some)
 *   compute all-pairs repulsion + springs along the edges, move every unpinned node
 *   write  x, y and a colour for the node's speed ("still" | "slow" | "fast")
 * The topology (edges) is static and read once, in b12_setup (not timed).
 *
 * Configurations:
 *   naive     b12_step_sync:  on the ArkTS thread; per node nodes[i].asObject(), then o["x"], o["y"], o["pinned"];
 *             writes o["x"] = ..., colour created with runtime.string() every time
 *   tactical  b12_step_sync:  on the ArkTS thread; one generated accessor call per node for the reads and one for
 *             the writes, each carrying all values as one packed integer (mock of a multi-value return:
 *             readNode(nodes, i) -> packed x, y, pinned; writeNode(nodes, i, packed x, y, colour index));
 *             scoped temporaries. Positions live on a 1/1024 grid in every configuration, so packing is exact.
 *   full      b12_step_async: tactical inside posted tasks; reads and writes posted in batches of b nodes,
 *             all batches in flight (futures); computation on t Cangjie threads. Returns a Promise.
 *
 * Results: {ns, uiNs, computeNs}. uiNs = time the ArkTS thread spent in this step (= ns for the synchronous
 * configurations; the sum of the posted tasks' durations for full).
 */

let B12_K_REP = 500.0
let B12_K_SPRING = 0.05
let B12_L0 = 30.0
let B12_STEP = 0.1
let B12_MAX_MOVE = 5.0
let B12_COLORS: Array<String> = ["still", "slow", "fast"]
let B12_CHUNK = 64
let B12_Q = 1024.0
let B12_OFF = 16777216      // 2^24
let B12_SHIFT = 33554432    // 2^25

func b12Snap(v: Float64): Float64 {
    floor(v * B12_Q + 0.5) / B12_Q
}

// Unpack readNode's result into slot k of the frame.
func b12Unpack(fr: B12Frame, k: Int64, packed: Float64): Unit {
    let p = Int64(packed)
    fr.pinned[k] = p % 2 == 1
    let r = p / 2
    let yq = r % B12_SHIFT
    let xq = r / B12_SHIFT
    fr.x[k] = Float64(xq - B12_OFF) / B12_Q
    fr.y[k] = Float64(yq - B12_OFF) / B12_Q
}

// Pack slot k's new position and colour for writeNode.
func b12Pack(fr: B12Frame, k: Int64): Float64 {
    let xq = Int64(fr.nx[k] * B12_Q) + B12_OFF
    let yq = Int64(fr.ny[k] * B12_Q) + B12_OFF
    Float64((xq * B12_SHIFT + yq) * 4 + fr.color[k])
}

class B12Graph {
    var n: Int64 = 0
    var adj: Array<ArrayList<Int64>> = Array<ArrayList<Int64>>()
    var colors: ?Array<JSString> = None   // tactical: created once
}

let B12_G = B12Graph()

// b12_setup(edges: number[] (flat pairs), n: number): read the static topology once.
func b12Setup(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let edges = callInfo[0]
    let n = Int64(callInfo[1].toNumber())
    let m = Int64(edges.getProperty("length").toNumber())
    let adj = Array<ArrayList<Int64>>(n, { _ => ArrayList<Int64>() })
    var k = 0
    while (k + 1 < m) {
        let a = Int64(edges.getElement(k).toNumber())
        let b = Int64(edges.getElement(k + 1).toNumber())
        adj[a].add(b)
        adj[b].add(a)
        k += 2
    }
    B12_G.n = n
    B12_G.adj = adj
    if (B12_G.colors.isNone()) {
        B12_G.colors = Array<JSString>(3, { c => runtime.string(B12_COLORS[c]) })
    }
    runtime.number(0.0).toJSValue()
}

// Positions and results of one step, shared by all phases.
class B12Frame {
    let x: Array<Float64>
    let y: Array<Float64>
    let pinned: Array<Bool>
    let nx: Array<Float64>
    let ny: Array<Float64>
    let color: Array<Int64>

    init(n: Int64) {
        x = Array<Float64>(n, repeat: 0.0)
        y = Array<Float64>(n, repeat: 0.0)
        pinned = Array<Bool>(n, repeat: false)
        nx = Array<Float64>(n, repeat: 0.0)
        ny = Array<Float64>(n, repeat: 0.0)
        color = Array<Int64>(n, repeat: 0)
    }
}

func b12Clamp(v: Float64): Float64 {
    if (v > B12_MAX_MOVE) { B12_MAX_MOVE } else if (v < -B12_MAX_MOVE) { -B12_MAX_MOVE } else { v }
}

// Forces and new position for nodes from..to-1. Each node sums its own forces in a fixed order,
// so the result does not depend on how nodes are split across threads.
func b12Compute(fr: B12Frame, from: Int64, to: Int64): Unit {
    let n = fr.x.size
    let x = fr.x
    let y = fr.y
    for (i in from..to) {
        if (fr.pinned[i]) {
            fr.nx[i] = x[i]
            fr.ny[i] = y[i]
            fr.color[i] = 0
            continue
        }
        let xi = x[i]
        let yi = y[i]
        var ax = 0.0
        var ay = 0.0
        for (j in 0..n) {
            if (j != i) {
                let dx = xi - x[j]
                let dy = yi - y[j]
                let f = B12_K_REP / (dx * dx + dy * dy + 0.01)
                ax += dx * f
                ay += dy * f
            }
        }
        for (j in B12_G.adj[i]) {
            let dx = x[j] - xi
            let dy = y[j] - yi
            let d = sqrt(dx * dx + dy * dy + 0.01)
            let f = B12_K_SPRING * (d - B12_L0) / d
            ax += dx * f
            ay += dy * f
        }
        let mx = b12Clamp(ax * B12_STEP)
        let my = b12Clamp(ay * B12_STEP)
        fr.nx[i] = b12Snap(xi + mx)
        fr.ny[i] = b12Snap(yi + my)
        let speed = (if (mx < 0.0) { -mx } else { mx }) + (if (my < 0.0) { -my } else { my })
        fr.color[i] = if (speed < 0.5) { 0 } else if (speed < 2.0) { 1 } else { 2 }
    }
}

func b12Result(runtime: JSContext, ns: Int64, uiNs: Int64, computeNs: Int64): JSValue {
    let res = runtime.object()
    res["ns"] = runtime.number(Float64(ns)).toJSValue()
    res["uiNs"] = runtime.number(Float64(uiNs)).toJSValue()
    res["computeNs"] = runtime.number(Float64(computeNs)).toJSValue()
    res.toJSValue()
}

// ---------------------------------------------------------------------------
// naive and tactical: synchronous, on the ArkTS thread.
// b12_step_sync(cfg: {tactical}, nodes: GNode[], lib): {ns, uiNs, computeNs}
// ---------------------------------------------------------------------------

func b12StepSync(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let tactical = callInfo[0].asObject()["tactical"].toBoolean()
    let nodesV = callInfo[1]
    let lib = callInfo[2].asObject()
    let readNode = lib["readNode"].asFunction()
    let writeNode = lib["writeNode"].asFunction()
    let n = B12_G.n
    let fr = B12Frame(n)

    let t0 = nowNs()
    var computeNs = 0
    if (tactical) {
        var i = 0
        while (i < n) {
            let end = if (i + B12_CHUNK < n) { i + B12_CHUNK } else { n }
            let from = i
            runtime.newScope({ =>
                for (k in from..end) {
                    b12Unpack(fr, k, readNode.call([nodesV, runtime.number(Float64(k)).toJSValue()]).toNumber())
                }
            })
            i = end
        }
        let tc = nowNs()
        b12Compute(fr, 0, n)
        computeNs = nowNs() - tc
        i = 0
        while (i < n) {
            let end = if (i + B12_CHUNK < n) { i + B12_CHUNK } else { n }
            let from = i
            runtime.newScope({ =>
                for (k in from..end) {
                    writeNode.call([nodesV, runtime.number(Float64(k)).toJSValue(), runtime.number(b12Pack(fr, k)).toJSValue()])
                }
            })
            i = end
        }
    } else {
        // what a user writes: node objects bound with asObject(), properties by name, colour strings created each time
        let nodes = nodesV.asArray()
        let objs = ArrayList<JSObject>()
        for (k in 0..n) {
            let o = nodes[k].asObject()
            objs.add(o)
            fr.x[k] = o["x"].toNumber()
            fr.y[k] = o["y"].toNumber()
            fr.pinned[k] = o["pinned"].toBoolean()
        }
        let tc = nowNs()
        b12Compute(fr, 0, n)
        computeNs = nowNs() - tc
        for (k in 0..n) {
            let o = objs[k]
            o["x"] = runtime.number(fr.nx[k]).toJSValue()
            o["y"] = runtime.number(fr.ny[k]).toJSValue()
            o["color"] = runtime.string(B12_COLORS[fr.color[k]]).toJSValue()
        }
    }
    let ns = nowNs() - t0
    b12Result(runtime, ns, ns, computeNs)
}

// ---------------------------------------------------------------------------
// full: tactical + futures + batching; computation on t Cangjie threads.
// b12_step_async(cfg: {t, b}, nodes: GNode[], lib): Promise<{ns, uiNs, computeNs}>
// ---------------------------------------------------------------------------

func b12StepAsync(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let cfg = callInfo[0].asObject()
    let t = Int64(cfg["t"].toNumber())
    let b = Int64(cfg["b"].toNumber())
    let nodes = callInfo[1].asArray()          // persisted once: used from posted tasks
    let lib = callInfo[2].asObject()
    let readNode = lib["readNode"].asFunction()
    let writeNode = lib["writeNode"].asFunction()
    let n = B12_G.n
    let fr = B12Frame(n)
    let uiNs = AtomicInt64(0)
    let promise = runtime.promiseCapability()

    spawn {
        let t0 = nowNs()
        // reads: every batch posted before waiting for any
        let reads = ArrayList<B01Future>()
        var i = 0
        while (i < n) {
            let from = i
            let end = if (i + b < n) { i + b } else { n }
            let f = b01NewFuture()
            runtime.postJSTask({ =>
                let ts = nowNs()
                runtime.newScope({ =>
                    let nv = nodes.toJSValue()
                    for (k in from..end) {
                        b12Unpack(fr, k, readNode.call([nv, runtime.number(Float64(k)).toJSValue()]).toNumber())
                    }
                })
                uiNs.fetchAdd(nowNs() - ts)
                b01Complete(f, 0.0)
            })
            reads.add(f)
            i = end
        }
        for (f in reads) {
            b01Wait(f)
        }
        // compute on t threads
        let tc = nowNs()
        let workers = ArrayList<Future<Unit>>()
        let slice = (n + t - 1) / t
        for (w in 0..t) {
            let from = w * slice
            let end = if (from + slice < n) { from + slice } else { n }
            workers.add(spawn { b12Compute(fr, from, end) })
        }
        for (w in workers) {
            w.get()
        }
        let computeNs = nowNs() - tc
        // writes: every batch posted, waited for at the end
        let writes = ArrayList<B01Future>()
        i = 0
        while (i < n) {
            let from = i
            let end = if (i + b < n) { i + b } else { n }
            let f = b01NewFuture()
            runtime.postJSTask({ =>
                let ts = nowNs()
                runtime.newScope({ =>
                    let nv = nodes.toJSValue()
                    for (k in from..end) {
                        writeNode.call([nv, runtime.number(Float64(k)).toJSValue(), runtime.number(b12Pack(fr, k)).toJSValue()])
                    }
                })
                uiNs.fetchAdd(nowNs() - ts)
                b01Complete(f, 0.0)
            })
            writes.add(f)
            i = end
        }
        for (f in writes) {
            b01Wait(f)
        }
        let ns = nowNs() - t0
        let ui = uiNs.load()
        runtime.postJSTask({ => promise.resolve(b12Result(runtime, ns, ui, computeNs)) })
    }
    promise.toJSValue()
}

// Cost of the checks the library performs before every value and element read (public API, same code path):
// b12_check_costs(arr: [number, number, boolean], n): {isNumber, isBoolean, size, toNumber, toBoolean, getElement}
// in ns per call.
func b12CheckCosts(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let arrV = callInfo[0]
    let arr = arrV.asArray()
    let n = Int64(callInfo[1].toNumber())
    let num = arrV.getElement(0)
    let flag = arrV.getElement(2)
    var sink = 0
    let res = runtime.object()
    let t0 = nowNs()
    for (_ in 0..n) { if (num.isNumber()) { sink += 1 } }
    let t1 = nowNs()
    for (_ in 0..n) { if (flag.isBoolean()) { sink += 1 } }
    let t2 = nowNs()
    for (_ in 0..n) { sink += arr.size }
    let t3 = nowNs()
    var acc = 0.0
    for (_ in 0..n) { acc += num.toNumber() }
    let t4 = nowNs()
    for (_ in 0..n) { if (flag.toBoolean()) { sink += 1 } }
    let t5 = nowNs()
    var i = 0
    while (i < n) {
        let chunk = if (n - i < B12_CHUNK) { n - i } else { B12_CHUNK }
        acc += runtime.newScope({ =>
            var a = 0.0
            for (_ in 0..chunk) { a += arrV.getElement(1).toNumber() }
            a
        })
        i += chunk
    }
    let t6 = nowNs()
    let per = { a: Int64, b: Int64 => runtime.number(Float64(b - a) / Float64(n)).toJSValue() }
    res["isNumber"] = per(t0, t1)
    res["isBoolean"] = per(t1, t2)
    res["size"] = per(t2, t3)
    res["toNumber"] = per(t3, t4)
    res["toBoolean"] = per(t4, t5)
    res["getElementToNumber"] = per(t5, t6)
    res["sink"] = runtime.number(Float64(sink) + acc).toJSValue()
    res.toJSValue()
}

func b12Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b12_check_costs"] = runtime.function(b12CheckCosts).toJSValue()
    exports["b12_setup"] = runtime.function(b12Setup).toJSValue()
    exports["b12_step_sync"] = runtime.function(b12StepSync).toJSValue()
    exports["b12_step_async"] = runtime.function(b12StepAsync).toJSValue()
}
```

### ArkTS combined graph application

Original benchmark source or configuration.

File: `src/main/ets/bench/b12_graph.ets`.

<!-- embedded-file: src/main/ets/bench/b12_graph.ets -->

```typescript
import { b12_check_costs, b12_setup, b12_step_async, b12_step_sync, B12Result } from 'libohos_app_cangjie_entry.so';
import { systemDateTime } from '@kit.BasicServicesKit';
import { benchLine, LogSink, yieldToSystem } from './Log';
import { process } from '@kit.ArkTS';

// ---- The UI's data: graph nodes the UI is bound to ----
export class GNode {
  x: number;
  y: number;
  pinned: boolean;
  color: string = 'still';
  label: string;

  constructor(x: number, y: number, pinned: boolean, label: string) {
    this.x = x;
    this.y = y;
    this.pinned = pinned;
    this.label = label;
  }
}

// Positions live on a 1/1024 grid (every configuration snaps after each step), so the optimised configurations can
// pass a node's values across the boundary as one exactly packed integer (a mock of a multi-value return).
const Q = 1024;
const OFF = 16777216;    // 2^24: fixed-point offset, coordinates in [-16384, 16384)
const SHIFT = 33554432;  // 2^25: bits per coordinate
const COLORS: string[] = ['still', 'slow', 'fast'];

export function snap(v: number): number {
  return Math.floor(v * Q + 0.5) / Q;
}

// Deterministic graph: N nodes in a 1000 x 1000 square, every 50th node pinned (node 0 is the one the user drags);
// edges: a ring plus one chord per node.
export function makeNodes(n: number): GNode[] {
  let seed = 4242;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return (seed % 100000) / 100;
  };
  const nodes: GNode[] = [];
  for (let i = 0; i < n; i++) {
    nodes.push(new GNode(snap(rnd()), snap(rnd()), i % 50 === 0, `node ${i}`));
  }
  return nodes;
}

export function makeEdges(n: number): number[] {
  const e: number[] = [];
  for (let i = 0; i < n; i++) {
    e.push(i, (i + 1) % n);
    const j = (i * 7 + 3) % n;
    if (j !== i) {
      e.push(i, j);
    }
  }
  return e;
}

// Generated accessors used by both optimised configurations: one call per node for the reads and one for the writes,
// each carrying all values as one packed integer (mock of a multi-value return / multi-value argument).
//   read:  ((x * 1024 + 2^24) * 2^25 + (y * 1024 + 2^24)) * 2 + pinned          (51 bits)
//   write: ((x * 1024 + 2^24) * 2^25 + (y * 1024 + 2^24)) * 4 + colour index    (52 bits)
class B12Lib {
  readNode = (nodes: GNode[], i: number): number => {
    const n = nodes[i];
    const xq = Math.floor(n.x * Q + 0.5) + OFF;
    const yq = Math.floor(n.y * Q + 0.5) + OFF;
    return (xq * SHIFT + yq) * 2 + (n.pinned ? 1 : 0);
  };
  writeNode = (nodes: GNode[], i: number, p: number): void => {
    const n = nodes[i];
    const c = p % 4;
    const r = (p - c) / 4;
    const yq = r % SHIFT;
    const xq = (r - yq) / SHIFT;
    n.x = (xq - OFF) / Q;
    n.y = (yq - OFF) / Q;
    n.color = COLORS[c];
  };
}
export const LIB = new B12Lib();

// ---- The same step in pure ArkTS (same arithmetic, same order) ----
const K_REP = 500;
const K_SPRING = 0.05;
const L0 = 30;
const STEP = 0.1;
const MAX_MOVE = 5;

function clamp(v: number): number {
  return v > MAX_MOVE ? MAX_MOVE : v < -MAX_MOVE ? -MAX_MOVE : v;
}

export function stepArkTS(nodes: GNode[], adj: number[][]): void {
  const n = nodes.length;
  const x: number[] = [];
  const y: number[] = [];
  for (const nd of nodes) {
    x.push(nd.x);
    y.push(nd.y);
  }
  for (let i = 0; i < n; i++) {
    const nd = nodes[i];
    if (nd.pinned) {
      nd.color = COLORS[0];
      continue;
    }
    const xi = x[i];
    const yi = y[i];
    let ax = 0;
    let ay = 0;
    for (let j = 0; j < n; j++) {
      if (j !== i) {
        const dx = xi - x[j];
        const dy = yi - y[j];
        const f = K_REP / (dx * dx + dy * dy + 0.01);
        ax += dx * f;
        ay += dy * f;
      }
    }
    for (const j of adj[i]) {
      const dx = x[j] - xi;
      const dy = y[j] - yi;
      const d = Math.sqrt(dx * dx + dy * dy + 0.01);
      const f = K_SPRING * (d - L0) / d;
      ax += dx * f;
      ay += dy * f;
    }
    const mx = clamp(ax * STEP);
    const my = clamp(ay * STEP);
    nd.x = snap(xi + mx);
    nd.y = snap(yi + my);
    const speed = Math.abs(mx) + Math.abs(my);
    nd.color = COLORS[speed < 0.5 ? 0 : speed < 2 ? 1 : 2];
  }
}

export function adjacency(n: number, edges: number[]): number[][] {
  const adj: number[][] = [];
  for (let i = 0; i < n; i++) {
    adj.push([]);
  }
  for (let k = 0; k + 1 < edges.length; k += 2) {
    adj[edges[k]].push(edges[k + 1]);
    adj[edges[k + 1]].push(edges[k]);
  }
  return adj;
}

// One frame of the given configuration. Returns [ms frame, ms UI thread, ms compute].
async function frame(variant: string, nodes: GNode[], adj: number[][]): Promise<number[]> {
  if (variant === 'arkts') {
    const t0 = systemDateTime.getTime(true);
    stepArkTS(nodes, adj);
    const ms = (systemDateTime.getTime(true) - t0) / 1e6;
    return [ms, ms, ms];
  }
  let r: B12Result;
  if (variant.startsWith('full')) {
    // 'full' = 4 compute threads; 'full_tK' = K compute threads
    const t = variant.startsWith('full_t') ? Number.parseInt(variant.substring(6)) : 4;
    r = await b12_step_async({ t: t, b: 64 }, nodes, LIB);
  } else {
    r = b12_step_sync({ tactical: variant === 'tactical' }, nodes, LIB);
  }
  return [r.ns / 1e6, r.uiNs / 1e6, r.computeNs / 1e6];
}

// Deferred costs: FRAMES frames back to back, separated only by a zero-delay timer, so that work queued on the
// ArkTS thread by earlier frames (e.g. disposal of persistent references) runs between frames. Per frame:
// step time, wall time (step + whatever else the ArkTS thread ran), and process CPU time including a drain
// period after the last frame (garbage collection and finalizers on any thread).
async function deferred(sink: LogSink, reps: number): Promise<void> {
  const FRAMES = 30;
  const DRAIN_MS = 300;
  const variants: string[] = ['naive', 'tactical'];
  benchLine(sink, 'BENCH,b12d,N,variant,rep,frames,ms_step,ms_wall,ms_cpu');
  for (let rep = 0; rep < reps; rep++) {
    for (const n of [1000, 2000]) {
      const edges = makeEdges(n);
      const adj = adjacency(n, edges);
      b12_setup(edges, n);
      for (let k = 0; k < variants.length; k++) {
        const v = variants[(k + rep) % variants.length];
        const nodes = makeNodes(n);
        await frame(v, nodes, adj);          // warm-up frame, not counted
        await yieldToSystem();
        await new Promise<void>((res) => setTimeout(res, DRAIN_MS));
        let step = 0;
        const cpu0 = process.getPastCpuTime();
        const w0 = systemDateTime.getTime(true);
        for (let f = 0; f < FRAMES; f++) {
          nodes[0].x += 0.5;
          step += (await frame(v, nodes, adj))[0];
          await new Promise<void>((res) => setTimeout(res, 0));
        }
        const wall = (systemDateTime.getTime(true) - w0) / 1e6;
        await new Promise<void>((res) => setTimeout(res, DRAIN_MS));
        const cpu = process.getPastCpuTime() - cpu0 - 0;
        benchLine(sink, `BENCH,b12d,${n},${v},${rep},${FRAMES},${(step / FRAMES).toFixed(3)},` +
          `${(wall / FRAMES).toFixed(3)},${(cpu / FRAMES).toFixed(3)}`);
        await yieldToSystem();
      }
    }
  }
}

// opts: 'quick' for a smoke test, 'repsN' to override the number of reps, 'deferred' for the deferred-cost run
export async function runB12(sink: LogSink, opts: string[]): Promise<void> {
  const quick = opts.indexOf('quick') >= 0;
  let reps = quick ? 1 : 8;
  for (const o of opts) {
    if (o.startsWith('reps')) {
      reps = Number.parseInt(o.substring(4));
    }
  }
  if (opts.indexOf('checks') >= 0) {
    // ns per call of the library's checks, on the accessor's result shape [x, y, pinned]
    benchLine(sink, 'BENCH,b12k,rep,isNumber,isBoolean,size,toNumber,toBoolean,getElementToNumber');
    const arr: Object[] = [1.5, 2.5, true];
    b12_check_costs(arr, 20000);  // warmup
    for (let rep = 0; rep < reps; rep++) {
      const c = b12_check_costs(arr, 200000);
      benchLine(sink, `BENCH,b12k,${rep},${c.isNumber.toFixed(1)},${c.isBoolean.toFixed(1)},${c.size.toFixed(1)},` +
        `${c.toNumber.toFixed(1)},${c.toBoolean.toFixed(1)},${c.getElementToNumber.toFixed(1)}`);
      await yieldToSystem();
    }
    return;
  }
  if (opts.indexOf('deferred') >= 0) {
    await deferred(sink, reps);
    return;
  }
  const threadsProbe = opts.indexOf('threads') >= 0;
  const sizes: number[] = quick ? [250] : threadsProbe ? [1000] : [250, 500, 1000, 2000];
  const frames = quick ? 3 : 6;
  const variants: string[] = threadsProbe ? ['tactical', 'full_t1', 'full_t2', 'full_t4'] : ['arkts', 'naive', 'tactical', 'full'];
  let seed = 9;
  const rnd = (m: number): number => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % m;
  };

  // BENCH,b12,N,variant,rep,frame,ms_frame,ms_ui,ms_compute   and after each run
  // BENCH,b12sum,N,variant,rep,checksum
  benchLine(sink, 'BENCH,b12,N,variant,rep,frame,ms_frame,ms_ui,ms_compute');
  for (let rep = 0; rep < reps; rep++) {
    for (const n of sizes) {
      const edges = makeEdges(n);
      const adj = adjacency(n, edges);
      b12_setup(edges, n);
      const order: number[] = [0, 1, 2, 3];
      for (let k = order.length - 1; k > 0; k--) {
        const j = rnd(k + 1);
        const tmp = order[k];
        order[k] = order[j];
        order[j] = tmp;
      }
      for (const k of order) {
        const v = variants[k];
        const nodes = makeNodes(n);
        for (let f = 0; f < frames; f++) {
          nodes[0].x += 0.5;  // the user drags node 0
          const t = await frame(v, nodes, adj);
          benchLine(sink, `BENCH,b12,${n},${v},${rep},${f},${t[0].toFixed(3)},${t[1].toFixed(3)},${t[2].toFixed(3)}`);
          await yieldToSystem();
        }
        let s = 0;
        for (const nd of nodes) {
          s += nd.x + nd.y + (nd.color === 'fast' ? 1 : nd.color === 'slow' ? 2 : 3);
        }
        benchLine(sink, `BENCH,b12sum,${n},${v},${rep},${s.toFixed(6)}`);
      }
    }
  }
}
```

### ArkTS benchmark logging support

Original benchmark source or configuration.

File: `src/main/ets/bench/Log.ets`.

<!-- embedded-file: src/main/ets/bench/Log.ets -->

```typescript
import { hilog } from '@kit.PerformanceAnalysisKit';

// Every result line goes to hilog with tag BENCH (collected over hdc) and to the on-screen log.
export type LogSink = (line: string) => void;

export function benchLine(sink: LogSink, line: string): void {
  hilog.info(0x0000, 'BENCH', '%{public}s', line);
  sink(line);
}

// Synchronous benchmarks run on the UI thread: yield with a real delay between measurements so the
// system's own main-thread tasks (e.g. the THREAD_BLOCK watchdog heartbeat) get to run.
export function yieldToSystem(): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, 5));
}
```

### ArkTS entry point for running the included examples

Additional runner for an existing asynchronous page or ability method. The quick modes reduce repetitions; some programs still process their full fixture sizes.

File: `src/main/ets/bench/InteropOptimizationExamples.ets`.

<!-- embedded-file: src/main/ets/bench/InteropOptimizationExamples.ets -->

```typescript
import { LogSink } from './Log';
import { runB01 } from './b01_js_futures';
import { runB03 } from './b03_object_access';
import { runB07 } from './b07_temporaries';
import { runB08 } from './b08_string_cache';
import { runB09 } from './b09_search';
import { runB12 } from './b12_graph';

export async function runInteropOptimizationExamples(sink: LogSink): Promise<void> {
  await runB01(sink, ['quick']);
  await runB01(sink, ['quick', 'batch']);
  await runB03(sink, ['quick']);
  await runB07(sink, ['quick']);
  await runB08(sink, ['quick']);
  await runB09(sink, ['quick', 'desc200']);
  await runB09(sink, ['quick', 'desc200', 'batch']);
  await runB12(sink, ['quick']);
}
```

