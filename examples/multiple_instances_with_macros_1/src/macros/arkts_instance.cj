macro package multiple_instances_with_macros_1.macros

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
        class $(input) <: ArkTSRuntime<$(input)> {
            private static var context: ?Int64 = None
            protected static func getContext(): Int64 { context.getOrThrow() }
            public static func setContext(context: Int64): Unit { $(input).context = context }
        }
    )
}
