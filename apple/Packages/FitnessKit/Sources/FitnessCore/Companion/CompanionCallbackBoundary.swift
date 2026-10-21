import Foundation

/// Adapts system callbacks, which may arrive on arbitrary queues, to UI state
/// owned by MainActor. Convert non-Sendable errors to text before the hop.
public enum CompanionCallbackBoundary {
    public nonisolated static func voidHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in handler() } }
    }

    public nonisolated static func errorHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) -> @Sendable (Error) -> Void {
        { error in
            let text = error.localizedDescription
            Task { @MainActor in handler(text) }
        }
    }

    public nonisolated static func mirrorSendHandler(
        _ handler: @escaping @MainActor @Sendable (Bool, String?) -> Void
    ) -> @Sendable (Bool, Error?) -> Void {
        { success, error in
            let text = error?.localizedDescription
            Task { @MainActor in handler(success, text) }
        }
    }
}
