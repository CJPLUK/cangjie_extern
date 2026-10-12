package ohos_app_cangjie_entry

import ohos.ark_interop.*

/*
 * B11 - Shipping small programs to an ArkTS interpreter.
 *
 * Instead of one FFI call per operation, Cangjie generates a small program (JSON text) and one FFI call
 * runs it in a fixed ArkTS interpreter (b11_dsl.ets). All on the ArkTS thread, synchronous.
 *
 * Workloads (n repetitions each):
 *   path   read o.k(8-d)...k7, depth d                         (as B03)
 *   read   read id, meta.title, meta.brand, price.amount, meta.description of one item  (as B09)
 *   write  create {id, score, kind, brand, price} and push it onto an array             (as B09)
 *
 * Variants:
 *   naive          one FFI call per operation (property names as Cangjie String literals)
 *   stub           one call of a hand-written ArkTS function (what a compiler could generate at build time)
 *   interp         one call of the interpreter with the program text; parsed (JSON.parse) on every call
 *   interp_cached  program loaded once; one call of the interpreter with the program id
 * Values that cross the boundary (results, arguments) are converted the same way in all variants.
 *
 * ArkTS signature:
 *   b11_run(cfg: {work, variant, d, n}, fixture: Object, lib: Object): {ns, checksum}
 */

let B11_KEYS: Array<String> = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"]
let B11_CHUNK = 64

// Program text. Opcodes: 0 get, 1 set, 2 new object, 3 push, 4 make array, 5 return (see b11_dsl.ets).
func b11PathProgram(d: Int64): String {
    var s = "["
    for (level in (8 - d)..8) {
        let src = if (level == 8 - d) { 0 } else { 1 }
        s = s + "[0,1,${src},\"k${level}\"],"
    }
    s + "[5,1]]"
}

let B11_READ_PROGRAM = "[[0,1,0,\"meta\"],[0,2,0,\"price\"],[0,3,0,\"id\"],[0,4,1,\"title\"],[0,5,1,\"brand\"]," +
    "[0,6,2,\"amount\"],[0,7,1,\"description\"],[4,8,3,4,5,6,7],[5,8]]"

// r0 = results, r1..r5 = id, score, kind, brand, price
let B11_WRITE_PROGRAM = "[[2,6],[1,6,\"id\",1],[1,6,\"score\",2],[1,6,\"kind\",3],[1,6,\"brand\",4]," +
    "[1,6,\"price\",5],[3,0,6],[5,6]]"

// Variant codes
let B11_NAIVE = 0
let B11_STUB = 1
let B11_INTERP = 2
let B11_CACHED = 3

// Everything one repetition needs, prepared before the timed loop.
class B11Setup {
    B11Setup(
        let rt: JSContext,
        let work: Int64,          // 0 path, 1 read, 2 write
        let variant: Int64,
        let d: Int64,
        let fixture: JSValue,
        let results: ?JSObject,   // write only
        let stub: JSFunction,
        let evalFn: JSFunction,
        let callFn: JSFunction,
        let src: JSString,        // program text, converted once
        let progId: Float64
    ) {}
}

// Sum of the 5 values an item read returns, from the array [id, title, brand, amount, description].
func b11Unpack(r: JSValue): Float64 {
    let title = r.getElement(1).toString()
    let brand = r.getElement(2).toString()
    let desc = r.getElement(4).toString()
    r.getElement(0).toNumber() + r.getElement(3).toNumber() + Float64(title.size + brand.size + desc.size)
}

// Call the interpreter (parse or cached) with the given arguments.
func b11Interp(s: B11Setup, args: Array<JSValue>): JSValue {
    let head = if (s.variant == B11_INTERP) { s.src.toJSValue() } else { s.rt.number(s.progId).toJSValue() }
    let all = Array<JSValue>(args.size + 1, { k => if (k == 0) { head } else { args[k - 1] } })
    if (s.variant == B11_INTERP) { s.evalFn.call(all) } else { s.callFn.call(all) }
}

func b11Path(s: B11Setup): Float64 {
    if (s.variant == B11_NAIVE) {
        var v = s.fixture
        for (level in (8 - s.d)..8) {
            v = v.getProperty(B11_KEYS[level])
        }
        v.toNumber()
    } else if (s.variant == B11_STUB) {
        s.stub.call(s.fixture).toNumber()
    } else {
        b11Interp(s, [s.fixture]).toNumber()
    }
}

func b11Read(s: B11Setup): Float64 {
    if (s.variant == B11_NAIVE) {
        let it = s.fixture
        let meta = it.getProperty("meta")
        let price = it.getProperty("price")
        let id = it.getProperty("id").toNumber()
        let title = meta.getProperty("title").toString()
        let brand = meta.getProperty("brand").toString()
        let amount = price.getProperty("amount").toNumber()
        let desc = meta.getProperty("description").toString()
        id + amount + Float64(title.size + brand.size + desc.size)
    } else if (s.variant == B11_STUB) {
        b11Unpack(s.stub.call(s.fixture))
    } else {
        b11Unpack(b11Interp(s, [s.fixture]))
    }
}

func b11Write(s: B11Setup, i: Int64): Float64 {
    let rt = s.rt
    let id = rt.number(Float64(i)).toJSValue()
    let score = rt.number(0.5).toJSValue()
    let kind = "prefix".toJSValue(rt)
    let brand = "sonora".toJSValue(rt)
    let price = rt.number(99.0).toJSValue()
    if (s.variant == B11_NAIVE) {
        let o = rt.object()
        o.setProperty("id", id)
        o.setProperty("score", score)
        o.setProperty("kind", kind)
        o.setProperty("brand", brand)
        o.setProperty("price", price)
        s.results.getOrThrow().callMethod("push", [o.toJSValue()])
    } else if (s.variant == B11_STUB) {
        s.stub.call([s.fixture, id, score, kind, brand, price])
    } else {
        b11Interp(s, [s.fixture, id, score, kind, brand, price])
    }
    0.0
}

func b11Run(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let cfg = callInfo[0].asObject()
    let workName = cfg["work"].toString()
    let variantName = cfg["variant"].toString()
    let d = Int64(cfg["d"].toNumber())
    let n = Int64(cfg["n"].toNumber())
    let fixture = callInfo[1]
    let lib = callInfo[2].asObject()

    // setup, not timed
    let work = match (workName) {
        case "path" => 0
        case "read" => 1
        case _ => 2
    }
    let variant = match (variantName) {
        case "naive" => B11_NAIVE
        case "stub" => B11_STUB
        case "interp" => B11_INTERP
        case _ => B11_CACHED
    }
    let stub = match (work) {
        case 0 => lib["path${d}"].asFunction()
        case 1 => lib["reader"].asFunction()
        case _ => lib["writer"].asFunction()
    }
    let text = match (work) {
        case 0 => b11PathProgram(d)
        case 1 => B11_READ_PROGRAM
        case _ => B11_WRITE_PROGRAM
    }
    let src = runtime.string(text)
    let progId = lib["loadProg"].asFunction().call(src.toJSValue()).toNumber()
    let results: ?JSObject = if (work == 2) { fixture.asObject() } else { None }
    let s = B11Setup(runtime, work, variant, d, fixture, results, stub, lib["evalProg"].asFunction(),
        lib["callProg"].asFunction(), src, progId)

    var checksum = 0.0
    let t0 = nowNs()
    var i = 0
    while (i < n) {
        let chunk = if (n - i < B11_CHUNK) { n - i } else { B11_CHUNK }
        let base = i
        checksum += runtime.newScope({ =>
            var acc = 0.0
            for (j in 0..chunk) {
                acc += match (work) {
                    case 0 => b11Path(s)
                    case 1 => b11Read(s)
                    case _ => b11Write(s, base + j)
                }
            }
            acc
        })
        i += chunk
    }
    let elapsed = nowNs() - t0

    let res = runtime.object()
    res["ns"] = runtime.number(Float64(elapsed)).toJSValue()
    res["checksum"] = runtime.number(checksum).toJSValue()
    res.toJSValue()
}

// Probe: does the VM run eval / the Function constructor when called from Cangjie through the global object?
func b11Probe(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    var out = ""
    try {
        let r = runtime.global["eval"].asFunction().call("1 + 2".toJSValue(runtime))
        out = out + "eval: ${r.toNumber()}; "
    } catch (e: Exception) {
        out = out + "eval failed: ${e}; "
    }
    try {
        let f = runtime.global["Function"].asFunction().call(["o".toJSValue(runtime), "return o.k0.k1;".toJSValue(runtime)])
        let o = runtime.object()
        let inner = runtime.object()
        inner["k1"] = runtime.number(42.0).toJSValue()
        o["k0"] = inner.toJSValue()
        let r = f.asFunction().call(o.toJSValue())
        out = out + "Function: ${r.toNumber()}"
    } catch (e: Exception) {
        out = out + "Function failed: ${e}"
    }
    runtime.string(out).toJSValue()
}

func b11Register(runtime: JSContext, exports: JSObject): Unit {
    exports["b11_run"] = runtime.function(b11Run).toJSValue()
    exports["b11_probe"] = runtime.function(b11Probe).toJSValue()
}
