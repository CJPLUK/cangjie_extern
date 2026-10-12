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
