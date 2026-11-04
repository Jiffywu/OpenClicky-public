import Observation

/// Reads observable state, applies what it read, and does both again whenever that state changes. `refresh()` can
/// also be called by hand when something the observation can't see changed (a plain stored flag): the new
/// observation replaces the pending one instead of adding a second, so however often it is called only one
/// observation stays live.
@MainActor
final class ObservationLoop<Value> {
    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    /// Bumped by every refresh and by `cancel()`; an observation that fires for an older generation is dropped.
    private var generation = 0

    init(read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.apply = apply
    }

    func refresh() {
        generation += 1
        let current = generation
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        apply(value)
    }

    /// Stops reacting to changes until the next `refresh()`.
    func cancel() { generation += 1 }
}
