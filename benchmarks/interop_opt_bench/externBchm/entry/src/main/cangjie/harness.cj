package ohos_app_cangjie_entry

import std.time.MonoTime

// Shared benchmark utilities (no interop in here).

let HARNESS_T0 = MonoTime.now()

// Monotonic nanoseconds since module load.
func nowNs(): Int64 {
    (MonoTime.now() - HARNESS_T0).toNanoseconds()
}

// Busy-wait for `ns` nanoseconds of wall time: stands in for "useful Cangjie work".
// Returns the iteration count so the loop can't be optimised away.
func spinNs(ns: Int64): Int64 {
    if (ns <= 0) {
        return 0
    }
    let end = nowNs() + ns
    var it = 0
    while (nowNs() < end) {
        it++
    }
    it
}
