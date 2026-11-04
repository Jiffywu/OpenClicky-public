import SwiftUI

/// `@State` without the SwiftUI macro. In the macOS 27 SDK `@State` is a macro whose plugin ships only with
/// Xcode, so builds with the Command Line Tools fail on it. This wraps the underlying `SwiftUI.State` storage,
/// which SwiftUI still installs because the wrapper is a `DynamicProperty`.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) { storage = SwiftUI.State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
