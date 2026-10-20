package multiple_instances_with_macros_2

import multiple_instances_with_macros_2.macros.ArkTSInstance

@ArkTSInstance(ArkTS1)
@ArkTSInstance(ArkTS2)

// Generic dispatch now uses ForeignRuntime<T>, which does not expose context
// accessors. Its static operations forward to the runtime object's methods.
func foo<T>(): Unit where T <: ForeignRuntime<T> {
    try {
        let _ = T.toExtern<Int64>(42)
    } catch (e: Exception) {
        println("Expected conversion exception: ${e.message}")
    }
}

main(): Unit {
    try {
        println(ArkTS1.getContext())
    } catch (_: NoneValueException) {
        println("Expected exception: ArkTS1 context is not set")
    }
    try {
        println(ArkTS2.getContext())
    } catch (_: NoneValueException) {
        println("Expected exception: ArkTS2 context is not set")
    }

    ArkTS1.setContext(1)
    ArkTS2.setContext(2)
    println(ArkTS1.getContext())
    println(ArkTS2.getContext())

    // Updating one runtime leaves the other runtime's context unchanged.
    ArkTS1.setContext(42)
    println(ArkTS1.getContext())
    println(ArkTS2.getContext())

    // Ordinary runtime objects can also have independent contexts, even with
    // the same type argument as one of the generated classes.
    let runtime = ArkTSRuntime<ArkTS1>()
    runtime.setContext(100)
    println(runtime.getContext())
    println(ArkTS1.getContext())

    // The operation bodies remain the same throwing placeholders as example 1.
    try {
        ArkTS1.memberAccess(Extern<ArkTS1>(()), "field")
    } catch (e: Exception) {
        println("Expected member access exception: ${e.message}")
    }

    println("calling foo")
    foo<ArkTS1>()
    foo<ArkTS2>()
}
