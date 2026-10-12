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
