package ohos_app_cangjie_entry

import std.runtime.*
import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B05 - Anatomy of runtime.string(s).
 *
 * B04: runtime.string("aaaaaaaa") costs ~800 ns, runtime.object() ~350 ns, and a String used as
 * a key ~150 ns. From the ark_interop source, runtime.string(s) executes:
 *
 *   createString:  acquireArrayRawData(s.rawData()); ARKTS_CreateUtf8; releaseArrayRawData
 *   JSHeapObject:  ARKTS_IsHeapObject; ARKTS_CreateGlobal (C++ new + engine Global handle);
 *                  ARKTS_GetGlobalValue; a Cangjie object with a finalizer (~init)
 *   later:         Cangjie GC runs the finalizer -> ARKTS_DisposeGlobal (mutex push, and at most one
 *                  pending AsyncDisposer task on the ArkTS thread) -> delete of the global handle
 *
 * runtime.object() is the same, with ARKTS_CreateObject instead of createString.
 *
 * This benchmark times each primitive on its own (raw_* call the C functions directly,
 * cj_* are the Cangjie-side steps), and the whole API calls (api_*), so we can check whether the
 * parts add up to the whole. Every measurement is preceded by a forced, verified GC, then one of the
 * conditions cold / spin / warm / debt (see b05Run) is prepared, untimed, before the timed loop.
 *
 * ArkTS signature:
 *   b05_run(op: string, cond: string, n: number): {ns, checksum, gcDuring}
 *   b05_force_gc(): {ran, attempts, waitedMs}
 */

// ---------------------------------------------------------------------------
// State handed between setup, timed loop and teardown (all on the ArkTS thread).
// ---------------------------------------------------------------------------

class B05Slot<T> {
    var value: ?T = None

    func set(v: T): Unit {
        value = v
    }

    func get(): T {
        value.getOrThrow()
    }

    func clear(): Unit {
        value = None
    }
}

let B05_PENDING = B05Slot<Array<CPointer<Unit>>>()   // globals created by raw_global_*, disposed after timing
let B05_PREPARED = B05Slot<Array<CPointer<Unit>>>()  // globals prepared for raw_dispose_*
let B05_KEPT = B05Slot<ArrayList<Any>>()             // handles kept by *_keep, dropped after timing

// ---------------------------------------------------------------------------
// Direct access to the C layer (libark_interop.z.so).
// App libraries may not link against it directly (library namespaces), so the functions are looked up
// at runtime with dlsym on libohos.ark_interop.so (which depends on it) and called through CFunc
// pointers. Such calls pay a normal FFI transition, while the library's own calls are @FastNative:
// raw_ffi_floor measures that transition so it can be subtracted.
// ---------------------------------------------------------------------------

@C
struct B05Val {
    let value: UInt64

    init(value: UInt64) {
        this.value = value
    }
}

foreign func dlopen(name: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, name: CString): CPointer<Unit>

func b05Sym(handle: CPointer<Unit>, name: String): CPointer<Unit> {
    unsafe {
        let cname = LibC.mallocCString(name)
        let p = dlsym(handle, cname)
        LibC.free(cname)
        p
    }
}

func b05Open(path: String): CPointer<Unit> {
    unsafe {
        let cpath = LibC.mallocCString(path)
        let h = dlopen(cpath, 2) // RTLD_NOW
        LibC.free(cpath)
        h
    }
}

// Finds a handle from which dlsym("ARKTS_CreateUtf8") succeeds. Returns the strategy used.
func b05FindHandle(): (CPointer<Unit>, String) {
    let rtldDefault = CPointer<Unit>()
    if (!b05Sym(rtldDefault, "ARKTS_CreateUtf8").isNull()) {
        return (rtldDefault, "RTLD_DEFAULT")
    }
    for (path in ["/system/lib64/platformsdk/cjsdk/libohos.ark_interop.so", "/system/lib64/platformsdk/libark_interop.z.so"]) {
        let h = b05Open(path)
        if (!h.isNull() && !b05Sym(h, "ARKTS_CreateUtf8").isNull()) {
            return (h, path)
        }
    }
    throw Exception("b05: could not locate ARKTS_* symbols")
}

func b05Fn(handle: CPointer<Unit>, name: String): CPointer<Unit> {
    let p = b05Sym(handle, name)
    if (p.isNull()) {
        throw Exception("b05: dlsym failed for ${name}")
    }
    p
}

class B05C {
    let via: String
    let createUndefined: CFunc<() -> B05Val>
    let createUtf8: CFunc<(IntNative, CPointer<UInt8>, Int32) -> B05Val>
    let createObject: CFunc<(IntNative) -> B05Val>
    let isHeapObject: CFunc<(B05Val) -> Bool>
    let createGlobal: CFunc<(IntNative, B05Val) -> CPointer<Unit>>
    let getGlobalValue: CFunc<(CPointer<Unit>) -> B05Val>
    let disposeGlobal: CFunc<(IntNative, CPointer<Unit>) -> Unit>
    let disposeGlobalSync: CFunc<(IntNative, CPointer<Unit>) -> Unit>

    init() {
        let (handle, strategy) = b05FindHandle()
        via = strategy
        createUndefined = CFunc<() -> B05Val>(b05Fn(handle, "ARKTS_CreateUndefined"))
        createUtf8 = CFunc<(IntNative, CPointer<UInt8>, Int32) -> B05Val>(b05Fn(handle, "ARKTS_CreateUtf8"))
        createObject = CFunc<(IntNative) -> B05Val>(b05Fn(handle, "ARKTS_CreateObject"))
        isHeapObject = CFunc<(B05Val) -> Bool>(b05Fn(handle, "ARKTS_IsHeapObject"))
        createGlobal = CFunc<(IntNative, B05Val) -> CPointer<Unit>>(b05Fn(handle, "ARKTS_CreateGlobal"))
        getGlobalValue = CFunc<(CPointer<Unit>) -> B05Val>(b05Fn(handle, "ARKTS_GetGlobalValue"))
        disposeGlobal = CFunc<(IntNative, CPointer<Unit>) -> Unit>(b05Fn(handle, "ARKTS_DisposeGlobal"))
        disposeGlobalSync = CFunc<(IntNative, CPointer<Unit>) -> Unit>(b05Fn(handle, "ARKTS_DisposeGlobalSync"))
    }
}

let B05_CSLOT = B05Slot<B05C>()

func b05C(): B05C {
    match (B05_CSLOT.value) {
        case Some(c) => c
        case None =>
            let c = B05C()
            B05_CSLOT.set(c)
            c
    }
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

let B05_S8 = "aaaaaaaa"
let B05_S1000 = b04Repeat("a", 1000)

// Cangjie objects with and without a finalizer, the size of a small wrapper.
class B05Plain {
    var a: Int64 = 0
    var b: Int64 = 0
}

class B05Fin {
    var a: Int64 = 0
    var b: Int64 = 0

    ~init() {}
}

// Runs body(j) for j in 0..n, releasing JS handles every 64 iterations (same helper shape as B04).
func b05Loop(runtime: JSContext, n: Int64, body: (Int64) -> Float64): Float64 {
    b04Loop(runtime, n, body)
}

// ---------------------------------------------------------------------------
// One timed row. Setup and teardown outside the timed region.
// ---------------------------------------------------------------------------

func b05Op(rt: JSContext, op: String, n: Int64): Float64 {
    let c = b05C()
    let env: IntNative = rt.env
    let bytes8 = unsafe { B05_S8.rawData() }
    let bytes1000 = unsafe { B05_S1000.rawData() }
    let u16s8 = Utf16String(B05_S8)
    match (op) {
        case "baseline" => b05Loop(rt, n, { j => 1.0 })
        // --- raw C primitives ---
        case "raw_ffi_floor" => b05Loop(rt, n, { j =>
            unsafe { c.createUndefined() }
            1.0
        })
        case "raw_utf8_0" => b05Loop(rt, n, { j =>
            unsafe {
                let h = acquireArrayRawData(bytes8)
                c.createUtf8(env, h.pointer, 0)
                releaseArrayRawData(h)
            }
            1.0
        })
        case "raw_utf8_8" => b05Loop(rt, n, { j =>
            unsafe {
                let h = acquireArrayRawData(bytes8)
                c.createUtf8(env, h.pointer, 8)
                releaseArrayRawData(h)
            }
            1.0
        })
        case "raw_utf8_1000" => b05Loop(rt, n, { j =>
            unsafe {
                let h = acquireArrayRawData(bytes1000)
                c.createUtf8(env, h.pointer, 1000)
                releaseArrayRawData(h)
            }
            1.0
        })
        case "raw_object" => b05Loop(rt, n, { j =>
            unsafe { c.createObject(env) }
            1.0
        })
        case "raw_is_heap" => b05Loop(rt, n, { j =>
            let v = unsafe { c.createObject(env) }
            if (unsafe { c.isHeapObject(v) }) { 1.0 } else { 0.0 }
        }) // subtract raw_object
        case "raw_global_object" => b05RawGlobals(rt, env, n, false)
        case "raw_global_str8" => b05RawGlobals(rt, env, n, true)
        case "raw_dispose_sync" => b05RawDispose(rt, env, n, true)
        case "raw_dispose_async" => b05RawDispose(rt, env, n, false)
        // --- Cangjie-side steps ---
        case "cj_acquire_release" => b05Loop(rt, n, { j =>
            unsafe {
                let h = acquireArrayRawData(bytes8)
                releaseArrayRawData(h)
            }
            1.0
        })
        case "cj_alloc_plain" => b05Loop(rt, n, { j =>
            B05Plain()
            1.0
        })
        case "cj_alloc_fin" => b05Loop(rt, n, { j =>
            B05Fin()
            1.0
        })
        // --- whole API calls ---
        case "api_object" => b05Loop(rt, n, { j =>
            rt.object()
            1.0
        })
        case "api_string0" => b05Loop(rt, n, { j =>
            rt.string("")
            1.0
        })
        case "api_string8" => b05Loop(rt, n, { j =>
            rt.string(B05_S8)
            1.0
        })
        case "api_string1000" => b05Loop(rt, n, { j =>
            rt.string(B05_S1000)
            1.0
        })
        case "api_string8_u16" => b05Loop(rt, n, { j =>
            rt.string(u16s8)
            1.0
        })
        case "api_scoped8" => b05Loop(rt, n, { j =>
            B05_S8.toJSValue(rt)
            1.0
        })
        case "api_scoped1000" => b05Loop(rt, n, { j =>
            B05_S1000.toJSValue(rt)
            1.0
        })
        case "api_object_keep" => b05Keep(rt, n, false)
        case "api_string8_keep" => b05Keep(rt, n, true)
        case _ => throw Exception("b05: unknown op ${op}")
    }
}

// CreateObject/CreateUtf8 + CreateGlobal + GetGlobalValue; globals disposed synchronously after the timed loop.
func b05RawGlobals(rt: JSContext, env: IntNative, n: Int64, str: Bool): Float64 {
    let c = b05C()
    let bytes8 = unsafe { B05_S8.rawData() }
    let globals = Array<CPointer<Unit>>(n, repeat: CPointer<Unit>())
    let sum = b05Loop(rt, n, { j =>
        unsafe {
            let v = if (str) {
                let h = acquireArrayRawData(bytes8)
                let s = c.createUtf8(env, h.pointer, 8)
                releaseArrayRawData(h)
                s
            } else {
                c.createObject(env)
            }
            let g = c.createGlobal(env, v)
            c.getGlobalValue(g)
            globals[j] = g
        }
        1.0
    })
    // disposed by b05Run after the clock stops
    B05_PENDING.set(globals)
    sum
}

// Disposal of n prepared globals, sync (delete now) or async (the finalizer's path: queue + one JS task).
func b05RawDispose(rt: JSContext, env: IntNative, n: Int64, sync: Bool): Float64 {
    let c = b05C()
    let globals = B05_PREPARED.get()
    b05Loop(rt, n, { j =>
        unsafe {
            if (sync) {
                c.disposeGlobalSync(env, globals[j])
            } else {
                c.disposeGlobal(env, globals[j])
            }
        }
        1.0
    })
}

// Create and keep every handle until after the timed loop: no finalization can happen during it.
func b05Keep(rt: JSContext, n: Int64, str: Bool): Float64 {
    let kept = ArrayList<Any>(n)
    let sum = b05Loop(rt, n, { j =>
        if (str) {
            kept.add(rt.string(B05_S8))
        } else {
            kept.add(rt.object())
        }
        1.0
    })
    B05_KEPT.set(kept)
    sum
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

func b05Run(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let c = b05C()
    let op = callInfo[0].toString()
    let cond = callInfo[1].toString()
    let n = Int64(callInfo[2].toNumber())
    let env: IntNative = runtime.env

    // setup (not timed)
    if (op == "raw_dispose_sync" || op == "raw_dispose_async") {
        let bytes8 = unsafe { B05_S8.rawData() }
        let globals = Array<CPointer<Unit>>(n, repeat: CPointer<Unit>())
        b05Loop(runtime, n, { j =>
            unsafe { globals[j] = c.createGlobal(env, c.createObject(env)) }
            1.0
        })
        B05_PREPARED.set(globals)
    }
    // conditions (the forced GC and a 30 ms pause happen before this call, from ArkTS):
    //   cold: nothing more
    //   spin: 20 ms busy loop without allocation (CPU frequency back up)
    //   warm: spin + 16000 plain Cangjie objects allocated and dropped (allocator / heap pages warm)
    //   debt: spin + 16000 runtime.string() dropped (finalizers and global handles pending)
    //   steady: nothing at all, and no forced GC before either (rows run back to back)
    if (cond != "cold" && cond != "steady") {
        spinNs(20_000_000)
    }
    if (cond == "warm") {
        b05Loop(runtime, 16000, { j =>
            B05Plain()
            B05Plain()
            1.0
        })
    }
    if (cond == "debt") {
        b05Loop(runtime, 16000, { j =>
            runtime.string(B05_S8)
            1.0
        })
    }

    let gc0 = getGCCount()
    let t0 = nowNs()
    let checksum = b05Op(runtime, op, n)
    let elapsed = nowNs() - t0
    let gcDuring = getGCCount() - gc0

    // teardown (not timed)
    match (B05_PENDING.value) {
        case Some(globals) =>
            for (g in globals) {
                unsafe { c.disposeGlobalSync(env, g) }
            }
            B05_PENDING.clear()
        case None => ()
    }
    B05_PREPARED.clear()
    B05_KEPT.clear()

    let res = runtime.object()
    res["ns"] = runtime.number(Float64(elapsed)).toJSValue()
    res["checksum"] = runtime.number(checksum).toJSValue()
    res["gcDuring"] = runtime.number(Float64(gcDuring)).toJSValue()
    res["via"] = runtime.string(c.via).toJSValue()
    res.toJSValue()
}

// Force a full GC and verify it happened: gc() is only a hint, and repeated requests may be ignored.
// Polls the GC count for up to ~300 ms per attempt, retrying up to 3 times.
func b05ForceGC(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let t0 = nowNs()
    var ran = false
    var attempts = 0
    while (!ran && attempts < 3) {
        attempts++
        let before = getGCCount()
        gc(heavy: true)
        var waited = 0
        while (getGCCount() == before && waited < 300) {
            sleep(Duration.millisecond)
            waited++
        }
        ran = getGCCount() != before
        if (!ran) {
            sleep(Duration.millisecond * 50)
        }
    }
    let res = runtime.object()
    res["ran"] = runtime.number(if (ran) { 1.0 } else { 0.0 }).toJSValue()
    res["attempts"] = runtime.number(Float64(attempts)).toJSValue()
    res["waitedMs"] = runtime.number(Float64(nowNs() - t0) / 1e6).toJSValue()
    res.toJSValue()
}

func b05Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b05_run"] = runtime.function(b05Run).toJSValue()
    exports["b05_force_gc"] = runtime.function(b05ForceGC).toJSValue()
}
