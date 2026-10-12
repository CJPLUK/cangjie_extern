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
