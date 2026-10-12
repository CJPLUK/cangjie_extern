package ohos_app_cangjie_entry

import std.collection.ArrayList
import ohos.ark_interop.*

/*
 * B02 - B01 with a share of the operations issued from the ArkTS (main) thread.
 *
 * o = fraction of operations issued OFF the main thread:
 *     o = 0 -> every op is issued on the ArkTS thread
 *     o = 1 -> every op is issued by the t worker threads (same as B01)
 *
 * Every op first checks runtime.isInBindThread():
 *   on the ArkTS thread -> call fn directly: no post, no future.
 *                          (posting to yourself and then waiting would deadlock, so even
 *                           naive code must take this path)
 *   on a worker thread  -> naive: post + wait immediately
 *                          opt:   post, wait for the result d ops later (as in B01)
 *
 * Main-thread ops run in bursts of c ops. Each burst is one JS task, standing for
 * "ArkTS calls into Cangjie, which performs c interop ops and returns". A burst posts the
 * next burst when it finishes, so worker posts interleave with the bursts in the event loop.
 * While a burst runs (including its Cangjie work), the ArkTS thread cannot serve workers.
 *
 * Total ops = n * t for every o, so results are comparable along o.
 * Reuses B01Future / b01PostDirect / B01Stats / b01TimedWait / b01TimedWork from b01_js_futures.cj.
 *
 * ArkTS signature (identical for both):
 *   b02_{naive,opt}(fn: (x: number) => number, cfg: {n, w, d, t, o, c}): Promise<{ns, checksum, ...}>
 */

// Direct call; only valid on the ArkTS thread.
func b02Direct(runtime: JSContext, fn: JSFunction, x: Float64): Float64 {
    runtime.newScope({ => fn.call(runtime.number(x).toJSValue()).toNumber() })
}

// ---------------------------------------------------------------------------
// Worker threads.
// ---------------------------------------------------------------------------

// naive: check thread; direct call, or post + wait.
func b02WorkerNaive(runtime: JSContext, fn: JSFunction, base: Int64, count: Int64, workNs: Int64): B01Stats {
    let st = B01Stats()
    for (i in 0..count) {
        let x = Float64(base + i)
        if (runtime.isInBindThread()) {
            st.checksum += b02Direct(runtime, fn, x)
        } else {
            b01TimedWait(b01PostDirect(runtime, fn, x), st)
        }
        b01TimedWork(workNs, st)
    }
    st
}

// opt: check thread; direct call (nothing stored), or post and wait d ops later.
func b02WorkerOpt(runtime: JSContext, fn: JSFunction, base: Int64, count: Int64, workNs: Int64, d: Int64): B01Stats {
    let st = B01Stats()
    let ring = Array<?B01Future>(d + 1, repeat: None)
    for (i in 0..count) {
        let x = Float64(base + i)
        if (runtime.isInBindThread()) {
            st.checksum += b02Direct(runtime, fn, x)
            ring[i % (d + 1)] = None
        } else {
            ring[i % (d + 1)] = b01PostDirect(runtime, fn, x)
        }
        if (i >= d) {
            match (ring[(i - d) % (d + 1)]) {
                case Some(f) => b01TimedWait(f, st)
                case None => ()
            }
        }
        b01TimedWork(workNs, st)
    }
    // wait for the last d ops, still in flight
    let from = if (count > d) { count - d } else { 0 }
    for (i in from..count) {
        match (ring[i % (d + 1)]) {
            case Some(f) => b01TimedWait(f, st)
            case None => ()
        }
    }
    st
}

// ---------------------------------------------------------------------------
// Main-thread share: chained bursts of c ops, each burst one JS task.
// ---------------------------------------------------------------------------

class B02Main {
    var next: Int64 = 0              // next x to process
    var end: Int64 = 0               // one past the last x
    var st: B01Stats = B01Stats()
    var finished: B01Future = b01NewFuture()
}

// Runs on the ArkTS thread. Both variants take the direct path here.
func b02Burst(runtime: JSContext, fn: JSFunction, m: B02Main, c: Int64, workNs: Int64): Unit {
    let to = if (m.next + c < m.end) { m.next + c } else { m.end }
    for (i in m.next..to) {
        let x = Float64(i)
        if (runtime.isInBindThread()) {
            m.st.checksum += b02Direct(runtime, fn, x)
        } else {
            throw Exception("b02: burst not running on the ArkTS thread")
        }
        b01TimedWork(workNs, m.st)
    }
    m.next = to
    if (m.next < m.end) {
        runtime.postJSTask({ => b02Burst(runtime, fn, m, c, workNs) })
    } else {
        b01Complete(m.finished, 0.0)
    }
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

enum B02Mode {
    | Naive
    | Opt
}

func b02Run(runtime: JSContext, callInfo: JSCallInfo, mode: B02Mode): JSValue {
    let fn = callInfo[0].asFunction()
    let cfg = callInfo[1].asObject()
    let n = Int64(cfg["n"].toNumber())
    let workNs = Int64(cfg["w"].toNumber())
    let d = Int64(cfg["d"].toNumber())
    let threads = Int64(cfg["t"].toNumber())
    let o = cfg["o"].toNumber()
    let c = Int64(cfg["c"].toNumber())
    let promise = runtime.promiseCapability()

    // x values 0..offOps-1 go to the workers, offOps..total-1 to the main thread.
    let total = n * threads
    let offOps = Int64(Float64(total) * o + 0.5)
    let m = B02Main()
    m.next = offOps
    m.end = total

    spawn {
        try {
            let t0 = nowNs()
            // main-thread share
            if (m.next < m.end) {
                runtime.postJSTask({ => b02Burst(runtime, fn, m, c, workNs) })
            } else {
                b01Complete(m.finished, 0.0)
            }
            // worker share, split as evenly as possible
            let workers = ArrayList<Future<B01Stats>>()
            var base = 0
            for (k in 0..threads) {
                let count = offOps / threads + (if (k < offOps % threads) { 1 } else { 0 })
                let myBase = base
                base += count
                let worker = spawn {
                    match (mode) {
                        case B02Mode.Naive => b02WorkerNaive(runtime, fn, myBase, count, workNs)
                        case B02Mode.Opt => b02WorkerOpt(runtime, fn, myBase, count, workNs, d)
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
            b01Wait(m.finished)
            checksum += m.st.checksum
            workedNs += m.st.workedNs
            let elapsedNs = nowNs() - t0
            b01Resolve(runtime, promise, elapsedNs, checksum, blockedNs, workedNs)
        } catch (e: Exception) {
            let msg = e.toString()
            runtime.postJSTask({ => promise.reject(runtime.string(msg).toJSValue()) })
        }
    }
    promise.toJSValue()
}

func b02Naive(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b02Run(runtime, callInfo, B02Mode.Naive)
}

func b02Opt(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    b02Run(runtime, callInfo, B02Mode.Opt)
}

func b02Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b02_naive"] = runtime.function(b02Naive).toJSValue()
    exports["b02_opt"] = runtime.function(b02Opt).toJSValue()
}
