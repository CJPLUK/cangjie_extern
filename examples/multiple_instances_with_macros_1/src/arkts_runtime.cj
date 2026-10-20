package multiple_instances_with_macros_1

// ForeignRuntime<T> and Extern<T> are provided by this SDK's std.core.
// The base class below is unchanged from /home/claudio/cangjie_sdk/tests/test20.cj.
abstract public class ArkTSRuntime<T> <: ForeignRuntime<T> where T <: ArkTSRuntime<T> {
    // Context
    protected static func getContext(): Int64 { throw Exception("cannot getContext in abstract class") }
    public static func setContext(context: Int64): Unit { throw Exception("cannot setContext in abstract class") }

    // Dynamic operations
    public static func memberAccess(e: Extern<T>, field: String): Extern<T> { throw Exception("not implemented!") }
    public static func indexedAccess(e: Extern<T>, arg: Any): Extern<T> { throw Exception("not implemented!") }
    public static func memberUpdate(e: Extern<T>, field: String, value: Any): Unit { throw Exception("not implemented!") }
    public static func indexedUpdate(e: Extern<T>, field: Any, value: Any): Unit { throw Exception("not implemented!") }
    public static func functionCall(e: Extern<T>, args: Array<Any>): Extern<T> { throw Exception("not implemented!") }

    // Conversions
    public static func fromExtern<R>(value: Extern<T>): R { throw Exception("not implemented!") }
    public static func toExtern<R>(value: R): Extern<T> { throw Exception("not implemented!") }
}
