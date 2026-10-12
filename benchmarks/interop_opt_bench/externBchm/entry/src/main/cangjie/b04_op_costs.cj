package ohos_app_cangjie_entry

import ohos.ark_interop.*

/*
 * B04 - Per-operation interop cost.
 *
 * Every basic interop operation is timed in a tight loop, synchronously on the ArkTS thread:
 *   naive:  the obvious ark_interop code (keys as Cangjie Strings, values created per use)
 *   cached: everything constant (keys, method handles, constant argument values) created once
 *           before the loop.  Only for operations where something can be cached.
 * The ArkTS side (b04_op_costs.ets) times the same operations in pure ArkTS.
 *
 * Function and class handles are fetched once, before the loop, in both variants.
 * Loops rotate over 16 objects (index j & 15), like the ArkTS side.
 * `baseline` measures the loop itself; it is subtracted in the summary.
 *
 * ArkTS signature:
 *   b04_naive(op: string, fx: Object, n: number): {ns, checksum}
 *   b04_cached(op: string, fx: Object, n: number): {ns, checksum}   (ns = -1: no cached variant)
 */

// ---------------------------------------------------------------------------
// Fixture handles, fetched from the ArkTS fixture object once per call (not timed).
// ---------------------------------------------------------------------------

class B04Fixture {
    let objs: Array<JSObject>     // 16 instances of B04Obj {x = 1, child, m(v)}
    let f0: JSFunction            // () => 1
    let f1: JSFunction            // (x) => x + 1
    let fstr: JSFunction          // (s) => s.length
    let f5: JSFunction            // (a, b, c, d, e) => a + b + c + d + e
    let point: JSClass            // class B04Point(x, y), taken from an instance's .constructor
    let arr: JSArray              // [0, 1, ..., 15]
    let s8: JSValue               // 'aaaaaaaa'
    let s1000: JSValue            // 'a' x 1000
    let vals: Array<JSValue>      // 16 values, every other one a number

    init(fx: JSObject) {
        let objsArr = fx.getProperty("objs").asArray()
        objs = Array<JSObject>(16, { i => objsArr[i].asObject() })
        f0 = fx.getProperty("f0").asFunction()
        f1 = fx.getProperty("f1").asFunction()
        fstr = fx.getProperty("fstr").asFunction()
        f5 = fx.getProperty("f5").asFunction()
        point = fx.getProperty("pointSample").getProperty("constructor").asClass()
        arr = fx.getProperty("arr").asArray()
        s8 = fx.getProperty("s8")
        s1000 = fx.getProperty("s1000")
        let valsArr = fx.getProperty("vals").asArray()
        vals = Array<JSValue>(16, { i => valsArr[i] })
    }
}

func b04Repeat(s: String, times: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..times) {
        sb.append(s)
    }
    sb.toString()
}

let B04_S8 = "aaaaaaaa"
let B04_S1000 = b04Repeat("a", 1000)

// Runs body(j) for j in 0..n and sums the results. JS handles are released every 64 iterations.
func b04Loop(runtime: JSContext, n: Int64, body: (Int64) -> Float64): Float64 {
    var sum = 0.0
    var i = 0
    while (i < n) {
        let from = i
        let to = if (i + 64 < n) { i + 64 } else { n }
        sum += runtime.newScope({ =>
            var s = 0.0
            for (j in from..to) {
                s += body(j)
            }
            s
        })
        i = to
    }
    sum
}

// ---------------------------------------------------------------------------
// Naive variants.
// ---------------------------------------------------------------------------

func b04NaiveOp(rt: JSContext, h: B04Fixture, op: String, n: Int64): Float64 {
    let objs = h.objs
    let vals = h.vals
    let f0 = h.f0
    let f1 = h.f1
    let fstr = h.fstr
    let f5 = h.f5
    let point = h.point
    let arr = h.arr
    let s8 = h.s8
    let s1000 = h.s1000
    match (op) {
        case "baseline" => b04Loop(rt, n, { j => 1.0 })
        // properties
        case "read_num" => b04Loop(rt, n, { j => objs[j & 15].getProperty("x").toNumber() })
        case "read_obj" => b04Loop(rt, n, { j =>
            objs[j & 15].getProperty("child")
            1.0
        })
        case "write_num" => b04Loop(rt, n, { j =>
            objs[j & 15].setProperty("x", rt.number(1.0).toJSValue())
            1.0
        })
        case "has" => b04Loop(rt, n, { j => if (objs[j & 15].hasProperty("x")) { 1.0 } else { 0.0 } })
        // calls
        case "call0" => b04Loop(rt, n, { j => f0.call().toNumber() })
        case "call1" => b04Loop(rt, n, { j => f1.call(rt.number(Float64(j & 15)).toJSValue()).toNumber() })
        case "call_str" => b04Loop(rt, n, { j => fstr.call(rt.string("hello").toJSValue()).toNumber() })
        case "call5" => b04Loop(rt, n, { j =>
            let args = [rt.number(Float64(j & 15)).toJSValue(), rt.number(1.0).toJSValue(), rt.number(1.0).toJSValue(),
                rt.number(1.0).toJSValue(), rt.number(1.0).toJSValue()]
            f5.call(args).toNumber()
        })
        case "method" => b04Loop(rt, n, { j =>
            objs[j & 15].callMethod("m", [rt.number(Float64(j & 15)).toJSValue()]).toNumber()
        })
        // object creation
        case "new_obj" => b04Loop(rt, n, { j =>
            rt.object()
            1.0
        })
        case "new_obj2" => b04Loop(rt, n, { j =>
            let o = rt.object()
            o.setProperty("x", rt.number(1.0).toJSValue())
            o.setProperty("y", rt.number(2.0).toJSValue())
            1.0
        })
        case "new_class" => b04Loop(rt, n, { j =>
            point.new([rt.number(1.0).toJSValue(), rt.number(2.0).toJSValue()])
            1.0
        })
        case "new_arr8" => b04Loop(rt, n, { j =>
            rt.array(Array<JSValue>(8, { k => rt.number(Float64(k)).toJSValue() }))
            1.0
        })
        // arrays
        case "arr_get" => b04Loop(rt, n, { j => arr[j & 15].toNumber() })
        case "arr_set" => b04Loop(rt, n, { j =>
            arr[j & 15] = rt.number(Float64(j & 15)).toJSValue()
            1.0
        })
        // value marshalling
        case "num_to_js" => b04Loop(rt, n, { j =>
            rt.number(Float64(j))
            1.0
        })
        case "str8_to_js" => b04Loop(rt, n, { j =>
            rt.string(B04_S8)
            1.0
        })
        case "str1000_to_js" => b04Loop(rt, n, { j =>
            rt.string(B04_S1000)
            1.0
        })
        case "str8_to_cj" => b04Loop(rt, n, { j => Float64(s8.toString().size) })
        case "str1000_to_cj" => b04Loop(rt, n, { j => Float64(s1000.toString().size) })
        case "typecheck" => b04Loop(rt, n, { j => if (vals[j & 15].isNumber()) { 1.0 } else { 0.0 } })
        case _ => throw Exception("b04: unknown op ${op}")
    }
}

// ---------------------------------------------------------------------------
// Cached variants: constants created once, before the timed loop. -1.0 = not applicable.
// ---------------------------------------------------------------------------

class B04Cache {
    let keyX: JSString
    let keyY: JSString
    let keyChild: JSString
    let one: JSValue
    let two: JSValue
    let hello: JSValue
    let method: JSFunction
    let pointArgs: Array<JSValue>
    let arr8: Array<JSValue>

    init(rt: JSContext, h: B04Fixture) {
        keyX = rt.string("x")
        keyY = rt.string("y")
        keyChild = rt.string("child")
        one = rt.number(1.0).toJSValue()
        two = rt.number(2.0).toJSValue()
        hello = rt.string("hello").toJSValue()
        method = h.objs[0].getProperty("m").asFunction()
        pointArgs = [one, two]
        arr8 = Array<JSValue>(8, { k => rt.number(Float64(k)).toJSValue() })
    }
}

func b04CachedOp(rt: JSContext, h: B04Fixture, c: B04Cache, op: String, n: Int64): Float64 {
    let objs = h.objs
    let fstr = h.fstr
    let point = h.point
    let keyX = c.keyX
    let keyY = c.keyY
    let keyChild = c.keyChild
    let one = c.one
    let two = c.two
    let hello = c.hello
    let method = c.method
    let pointArgs = c.pointArgs
    let arr8 = c.arr8
    match (op) {
        case "baseline" => b04Loop(rt, n, { j => 1.0 })
        case "read_num" => b04Loop(rt, n, { j => objs[j & 15].getProperty(keyX).toNumber() })
        case "read_obj" => b04Loop(rt, n, { j =>
            objs[j & 15].getProperty(keyChild)
            1.0
        })
        case "write_num" => b04Loop(rt, n, { j =>
            objs[j & 15].setProperty(keyX, one)
            1.0
        })
        case "has" => b04Loop(rt, n, { j => if (objs[j & 15].hasProperty(keyX)) { 1.0 } else { 0.0 } })
        case "call_str" => b04Loop(rt, n, { j => fstr.call(hello).toNumber() })
        case "method" => b04Loop(rt, n, { j =>
            let o = objs[j & 15]
            method.call([rt.number(Float64(j & 15)).toJSValue()], thisArg: o.toJSValue()).toNumber()
        })
        case "new_obj2" => b04Loop(rt, n, { j =>
            let o = rt.object()
            o.setProperty(keyX, one)
            o.setProperty(keyY, two)
            1.0
        })
        case "new_class" => b04Loop(rt, n, { j =>
            point.new(pointArgs)
            1.0
        })
        case "new_arr8" => b04Loop(rt, n, { j =>
            rt.array(arr8)
            1.0
        })
        case _ => -1.0
    }
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

func b04Run(runtime: JSContext, callInfo: JSCallInfo, cached: Bool): JSValue {
    let op = callInfo[0].toString()
    let h = B04Fixture(callInfo[1].asObject())
    let n = Int64(callInfo[2].toNumber())
    let c = B04Cache(runtime, h)  // built for both variants, outside the timed region

    let t0 = nowNs()
    let checksum = if (cached) { b04CachedOp(runtime, h, c, op, n) } else { b04NaiveOp(runtime, h, op, n) }
    let elapsed = nowNs() - t0

    let res = runtime.object()
    res["ns"] = runtime.number(if (checksum == -1.0) { -1.0 } else { Float64(elapsed) }).toJSValue()
    res["checksum"] = runtime.number(checksum).toJSValue()
    res.toJSValue()
}

func b04Naive(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b04Run(runtime, callInfo, false)
}

func b04Cached(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b04Run(runtime, callInfo, true)
}

func b04Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b04_naive"] = runtime.function(b04Naive).toJSValue()
    exports["b04_cached"] = runtime.function(b04Cached).toJSValue()
}
