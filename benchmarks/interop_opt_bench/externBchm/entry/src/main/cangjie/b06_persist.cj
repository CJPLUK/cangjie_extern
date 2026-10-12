package ohos_app_cangjie_entry

import std.runtime.getGCCount
import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B06 - Do not persist short-lived values.
 *
 * asObject(), asArray(), asString(), asFunction(), runtime.string(), runtime.object() each create a
 * persistent reference: an engine GC root + a Cangjie object with a finalizer (~0.34 µs, see B05).
 * A plain JSValue is scoped: valid until the current scope ends, no GC root, no finalizer.
 * A compiler may keep a value scoped when it does not escape (not stored beyond the call,
 * not sent to another thread, not used after the scope ends).
 *
 *   P2 array iteration, nothing escapes:
 *        naive   arr = v.asArray(); for i: o = arr[i].asObject(); sum += o["x"]
 *        opt     for i: sum += v.getElement(i).getProperty("x")
 *   P5 filter, some elements escape (kept in a list for later):
 *        naive   o = arr[i].asObject(); if (o["price"] >= limit) { selected.add(o) }
 *        opt     e = v.getElement(i); if (e.getProperty("price") >= limit) { selected.add(e.asObject()) }
 *   P4 string argument per call:
 *        naive   f.call(rt.string(s).toJSValue())
 *        opt     f.call(s.toJSValue(rt))
 *
 * All synchronous on the ArkTS thread. One pass = one walk over the array (or n calls); each pass
 * runs in its own scope.
 *
 * ArkTS signature:
 *   b06_run(prog: string, variant: string, arr: Object[], f: Function, limit: number, passes: number)
 *     -> {ns, checksum, persisted, gcDuring}
 */

let B06_NAMES: Array<String> = ["alpha001", "bravo002", "charlie3", "delta004", "echo0005", "foxtrot6", "golf0007",
    "hotel008", "india009", "juliet10", "kilo0011", "lima0012", "mike0013", "november", "oscar015", "papa0016"]

// ---------------------------------------------------------------------------
// P2: array iteration, nothing escapes. Returns (checksum, persistent references created).
// ---------------------------------------------------------------------------

func b06P2Naive(rt: JSContext, arrV: JSValue, passes: Int64): (Float64, Int64) {
    var sum = 0.0
    var persisted = 0
    for (_ in 0..passes) {
        let (s, p) = rt.newScope({ =>
            let arr = arrV.asArray()
            var s = 0.0
            for (i in 0..arr.size) {
                let o = arr[i].asObject()
                s += o["x"].toNumber()
            }
            (s, arr.size + 1)
        })
        sum += s
        persisted += p
    }
    (sum, persisted)
}

func b06P2Opt(rt: JSContext, arrV: JSValue, passes: Int64): (Float64, Int64) {
    var sum = 0.0
    for (_ in 0..passes) {
        sum += rt.newScope({ =>
            let n = Int64(arrV.getProperty("length").toNumber())
            var s = 0.0
            for (i in 0..n) {
                s += arrV.getElement(i).getProperty("x").toNumber()
            }
            s
        })
    }
    (sum, 0)
}

// ---------------------------------------------------------------------------
// P5: filter; selected elements escape into `selected` (kept until after the timed loop).
// ---------------------------------------------------------------------------

func b06P5Naive(rt: JSContext, arrV: JSValue, limit: Float64, passes: Int64, selected: ArrayList<JSObject>): (Float64, Int64) {
    var sum = 0.0
    var persisted = 0
    for (_ in 0..passes) {
        let (s, p) = rt.newScope({ =>
            let arr = arrV.asArray()
            var s = 0.0
            for (i in 0..arr.size) {
                let o = arr[i].asObject()
                let price = o["price"].toNumber()
                if (price >= limit) {
                    selected.add(o)
                    s += price
                }
            }
            (s, arr.size + 1)
        })
        sum += s
        persisted += p
    }
    (sum, persisted)
}

func b06P5Opt(rt: JSContext, arrV: JSValue, limit: Float64, passes: Int64, selected: ArrayList<JSObject>): (Float64, Int64) {
    var sum = 0.0
    var persisted = 0
    for (_ in 0..passes) {
        let (s, p) = rt.newScope({ =>
            let n = Int64(arrV.getProperty("length").toNumber())
            var s = 0.0
            var p = 0
            for (i in 0..n) {
                let e = arrV.getElement(i)
                let price = e.getProperty("price").toNumber()
                if (price >= limit) {
                    selected.add(e.asObject())  // persisted only on the escaping path
                    s += price
                    p++
                }
            }
            (s, p)
        })
        sum += s
        persisted += p
    }
    (sum, persisted)
}

// ---------------------------------------------------------------------------
// P4: string argument per call; f returns s.length.
// ---------------------------------------------------------------------------

func b06P4Naive(rt: JSContext, f: JSFunction, calls: Int64, passes: Int64): (Float64, Int64) {
    var sum = 0.0
    for (_ in 0..passes) {
        sum += rt.newScope({ =>
            var s = 0.0
            for (j in 0..calls) {
                s += f.call(rt.string(B06_NAMES[j & 15]).toJSValue()).toNumber()
            }
            s
        })
    }
    (sum, calls * passes)
}

func b06P4Opt(rt: JSContext, f: JSFunction, calls: Int64, passes: Int64): (Float64, Int64) {
    var sum = 0.0
    for (_ in 0..passes) {
        sum += rt.newScope({ =>
            var s = 0.0
            for (j in 0..calls) {
                s += f.call(B06_NAMES[j & 15].toJSValue(rt)).toNumber()
            }
            s
        })
    }
    (sum, 0)
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

func b06Run(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let prog = callInfo[0].toString()
    let variant = callInfo[1].toString()
    let arrV = callInfo[2]
    let f = callInfo[3].asFunction()  // fetched once in both variants (calling requires a JSFunction)
    let limit = callInfo[4].toNumber()
    let passes = Int64(callInfo[5].toNumber())
    let n = Int64(arrV.getProperty("length").toNumber())
    let selected = ArrayList<JSObject>()
    let naive = variant == "naive"

    let gc0 = getGCCount()
    let t0 = nowNs()
    let (checksum, persisted) = match (prog) {
        case "p2" => if (naive) { b06P2Naive(runtime, arrV, passes) } else { b06P2Opt(runtime, arrV, passes) }
        case "p5" => if (naive) { b06P5Naive(runtime, arrV, limit, passes, selected) } else { b06P5Opt(runtime, arrV, limit, passes, selected) }
        case "p4" => if (naive) { b06P4Naive(runtime, f, n, passes) } else { b06P4Opt(runtime, f, n, passes) }
        case _ => throw Exception("b06: unknown program ${prog}")
    }
    let elapsed = nowNs() - t0
    let gcDuring = getGCCount() - gc0
    selected.clear()  // escaped values are dropped only after the timed loop

    let res = runtime.object()
    res["ns"] = runtime.number(Float64(elapsed)).toJSValue()
    res["checksum"] = runtime.number(checksum).toJSValue()
    res["persisted"] = runtime.number(Float64(persisted)).toJSValue()
    res["gcDuring"] = runtime.number(Float64(gcDuring)).toJSValue()
    res.toJSValue()
}

func b06Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b06_run"] = runtime.function(b06Run).toJSValue()
}
