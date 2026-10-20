macro package multiple_instances_with_macros_2.macros

import std.ast.*

// Usage: @ArkTSInstance(ArkTS1)
public macro ArkTSInstance(input: Tokens): Tokens {
    if (input.size != 1 || input[0].kind != TokenKind.IDENTIFIER) {
        diagReport(DiagReportLevel.ERROR, input,
            "ArkTSInstance expects one class name",
            "Use @ArkTSInstance(ArkTS1).")
        return quote()
    }

    return quote(
        class $(input) <: ForeignRuntime<$(input)> {
            // Each generated class owns a distinct runtime object.
            private static let arkTSRuntime = ArkTSRuntime<$(input)>()

            public static func getContext(): Int64 {
                arkTSRuntime.getContext()
            }
            public static func setContext(context: Int64): Unit {
                arkTSRuntime.setContext(context)
            }

            public static func memberAccess(e: Extern<$(input)>, field: String): Extern<$(input)> {
                arkTSRuntime.memberAccess(e, field)
            }
            public static func indexedAccess(e: Extern<$(input)>, arg: Any): Extern<$(input)> {
                arkTSRuntime.indexedAccess(e, arg)
            }
            public static func memberUpdate(e: Extern<$(input)>, field: String, value: Any): Unit {
                arkTSRuntime.memberUpdate(e, field, value)
            }
            public static func indexedUpdate(e: Extern<$(input)>, field: Any, value: Any): Unit {
                arkTSRuntime.indexedUpdate(e, field, value)
            }
            public static func functionCall(e: Extern<$(input)>, args: Array<Any>): Extern<$(input)> {
                arkTSRuntime.functionCall(e, args)
            }

            public static func fromExtern<R>(value: Extern<$(input)>): R {
                arkTSRuntime.fromExtern<R>(value)
            }
            public static func toExtern<R>(value: R): Extern<$(input)> {
                arkTSRuntime.toExtern<R>(value)
            }
        }
    )
}
