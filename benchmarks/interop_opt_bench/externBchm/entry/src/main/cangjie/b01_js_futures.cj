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
