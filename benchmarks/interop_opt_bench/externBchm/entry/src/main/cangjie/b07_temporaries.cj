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
