package ohos_app_cangjie_entry

import ohos.ark_interop.JSModule
import ohos.ark_interop.JSContext
import ohos.ark_interop.JSCallInfo
import ohos.ark_interop.JSValue

func testCJ(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    let result = "Hello ${callInfo[0].toString()}"
    runtime.string(result).toJSValue()
}

// Module registration only; each benchmark lives in its own bNN_*.cj file.
let EXPORT_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["testCJ"] = runtime.function(testCJ).toJSValue()
    b01Register(runtime, exports)
    b02Register(runtime, exports)
    b03Register(runtime, exports)
    b04Register(runtime, exports)
    b05Register(runtime, exports)
    b06Register(runtime, exports)
    b07Register(runtime, exports)
    b08Register(runtime, exports)
    b09Register(runtime, exports)
    b11Register(runtime, exports)
    b12Register(runtime, exports)
}
