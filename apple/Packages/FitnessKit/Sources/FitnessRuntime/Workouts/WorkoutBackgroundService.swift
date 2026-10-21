import BackgroundTasks
import FitnessCore
import Foundation

/// Finite, operator-initiated execution. A lease grants runtime, never motor authority.
@MainActor
public protocol WorkoutBackgroundService: AnyObject {
    func begin(totalSeconds: Int, onExpiration: @escaping @MainActor () -> Void) async throws
    func update(completedSeconds: Int, totalSeconds: Int)
    func end(success: Bool) async
}

@MainActor
public final class SystemWorkoutBackgroundService: WorkoutBackgroundService {
    // Registration is process-wide; one task/one workout can own this identifier.
    private static let identifier =
        (Bundle.main.bundleIdentifier ?? "dev.vaganciafitness.kraziel.app") + ".workout"
    private static var registered = false
    private static weak var owner: SystemWorkoutBackgroundService?
    private var task: BGContinuedProcessingTask?
    private var awaitingAdmission = false
    private var expiration: (@MainActor () -> Void)?
    private var totalSeconds = 1

    public init() {}

    public func begin(totalSeconds: Int, onExpiration: @escaping @MainActor () -> Void) async throws {
        guard task == nil, !awaitingAdmission,
            Self.owner == nil || Self.owner === self
        else {
            throw WorkoutBackgroundError.alreadyRunning
        }
        if !Self.registered {
            // The supplied main queue makes this synchronous actor assertion valid.
            Self.registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.identifier, using: .main
            ) { raw in
                MainActor.assumeIsolated {
                    guard let owner = Self.owner, owner.awaitingAdmission,
                        let continued = raw as? BGContinuedProcessingTask
                    else {
                        raw.setTaskCompleted(success: false)
                        return
                    }
                    owner.task = continued
                    continued.progress.totalUnitCount = Int64(owner.totalSeconds)
                    continued.progress.completedUnitCount = 0
                    continued.expirationHandler = Self.taskExpirationHandler { [weak owner] in
                        owner?.expire()
                    }
                }
            }
            guard Self.registered else { throw WorkoutBackgroundError.registrationFailed }
        }
        Self.owner = self
        self.totalSeconds = max(1, totalSeconds)
        expiration = onExpiration
        awaitingAdmission = true
        do {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.identifier,
                title: "VAGANCIA FITNESS", subtitle: FitnessText.string("background.subtitle"))
            request.strategy = .fail
            try BGTaskScheduler.shared.submit(request)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while task == nil, clock.now < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            guard task != nil else { throw WorkoutBackgroundError.admissionTimedOut }
            awaitingAdmission = false
        } catch {
            await end(success: false)
            throw error
        }
    }

    public func update(completedSeconds: Int, totalSeconds: Int) {
        guard let task else { return }
        let total = Int64(max(1, totalSeconds))
        task.progress.totalUnitCount = total
        // Keep the task unfinished while the final stop still needs confirmation.
        let completed = min(total - 1, Int64(max(0, completedSeconds)))
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, completed)
    }

    public func end(success: Bool) async {
        awaitingAdmission = false
        expiration = nil
        if let task {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
        }
        task = nil
        if Self.owner === self {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            Self.owner = nil
        }
    }

    private func expire() {
        guard task != nil || awaitingAdmission else { return }
        let callback = expiration
        expiration = nil
        awaitingAdmission = false
        task?.setTaskCompleted(success: false)
        task = nil
        if Self.owner === self { Self.owner = nil }
        callback?()
    }

    // BGTask's expiration block has no actor or queue guarantee in the SDK.
    static func taskExpirationHandler(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        CompanionCallbackBoundary.voidHandler(action)
    }
}

public enum WorkoutBackgroundError: LocalizedError {
    case alreadyRunning, registrationFailed, admissionTimedOut
    public var errorDescription: String? { localizedMessage() }
    public func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .alreadyRunning: FitnessText.string("error.background.alreadyRunning", locale: locale)
        case .registrationFailed:
            FitnessText.string("error.background.registrationFailed", locale: locale)
        case .admissionTimedOut:
            FitnessText.string("error.background.admissionTimedOut", locale: locale)
        }
    }
}
