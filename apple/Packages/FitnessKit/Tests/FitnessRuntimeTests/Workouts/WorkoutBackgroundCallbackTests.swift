import Dispatch
import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct WorkoutBackgroundCallbackTests {
    @Test func taskExpirationCallbackEntersMainActorFromUtilityQueue() async {
        let receivedOnMainActor = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            // This is the same factory assigned to BGTask.expirationHandler.
            let callback = SystemWorkoutBackgroundService.taskExpirationHandler {
                MainActor.preconditionIsolated()
                continuation.resume(returning: Thread.isMainThread)
            }
            DispatchQueue.global(qos: .utility).async {
                precondition(!Thread.isMainThread)
                callback()
            }
        }
        #expect(receivedOnMainActor)
    }
}
