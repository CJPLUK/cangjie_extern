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
