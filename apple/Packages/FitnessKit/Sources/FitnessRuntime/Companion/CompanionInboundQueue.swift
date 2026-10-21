/// Serializes companion messages across Watch Connectivity and HealthKit.
/// The receiver may suspend on durable storage before acknowledging samples.
@MainActor
final class CompanionInboundQueue {
    private var tail: Task<Void, Never>?
    func submit(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }
    func drain() async { await tail?.value }
}
