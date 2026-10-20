package multiple_instances_with_macros_2

// T implements ForeignRuntime<T>; this class holds the instance state and
// implementation used by T's static forwarding methods.
public class ArkTSRuntime<T> where T <: ForeignRuntime<T> {
    // Context belongs to this runtime object.
    private var context: ?Int64 = None
    public func getContext(): Int64 { context.getOrThrow() }
    public func setContext(context: Int64): Unit { this.context = context }

    // Dynamic operations
    public func memberAccess(e: Extern<T>, field: String): Extern<T> { throw Exception("not implemented!") }
    public func indexedAccess(e: Extern<T>, arg: Any): Extern<T> { throw Exception("not implemented!") }
    public func memberUpdate(e: Extern<T>, field: String, value: Any): Unit { throw Exception("not implemented!") }
    public func indexedUpdate(e: Extern<T>, field: Any, value: Any): Unit { throw Exception("not implemented!") }
    public func functionCall(e: Extern<T>, args: Array<Any>): Extern<T> { throw Exception("not implemented!") }

    // Conversions
    public func fromExtern<R>(value: Extern<T>): R { throw Exception("not implemented!") }
    public func toExtern<R>(value: R): Extern<T> { throw Exception("not implemented!") }
}
