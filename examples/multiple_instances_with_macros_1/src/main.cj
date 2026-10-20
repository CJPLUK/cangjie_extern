package multiple_instances_with_macros_1

import multiple_instances_with_macros_1.macros.ArkTSInstance

@ArkTSInstance(ArkTS1)
@ArkTSInstance(ArkTS2)

func foo<T>() where T <: ArkTSRuntime<T> {
    println(T.getContext())
}

main() {
    try {
        println(ArkTSRuntime<ArkTS1>.getContext())
    } catch (e: Exception) {
        println("Expected exception: ${e.message}")
    }
    try {
        ArkTSRuntime<ArkTS1>.setContext(1)
    } catch (e: Exception) {
        println("Expected exception: ${e.message}")
    }
    println(ArkTS1.setContext(1))
    println(ArkTS2.setContext(2))

    println(ArkTS1.getContext())
    println(ArkTS2.getContext())

    // Updating one runtime leaves the other runtime's context unchanged.
    ArkTS1.setContext(42)

    println(ArkTS1.getContext())
    println(ArkTS2.getContext())

    println("calling foo")
    foo<ArkTS1>()
    foo<ArkTS2>()
}
