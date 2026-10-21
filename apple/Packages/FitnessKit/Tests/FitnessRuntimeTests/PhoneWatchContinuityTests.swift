import FitnessCore
import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct PhoneWatchContinuityTests {
    @Test func channelErrorHandlerFromBackgroundQueueUpdatesServiceAndRecordsEvent() async {
        let service = PhoneWatchService()
        let callback = service.channelErrorHandler()
        let event: (String, String) = await withCheckedContinuation { continuation in
            service.onEvent = { kind, text in continuation.resume(returning: (kind, text)) }
            DispatchQueue.global(qos: .utility).async {
                callback(
                    NSError(
                        domain: "PhoneWatchContinuityTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "WC utility queue error"]))
            }
        }
        #expect(event.0 == "watch.channel.sendFailed")
        #expect(event.1 == "WC utility queue error")
        #expect(service.errorMessage == "WC utility queue error")
    }

    @Test func mirrorSendCallbackFromDetachedTaskPreservesResultAndErrorText() async {
        let failure: (Bool, String?) = await withCheckedContinuation { continuation in
            let callback = CompanionCallbackBoundary.mirrorSendHandler { success, text in
                continuation.resume(returning: (success, text))
            }
            Task.detached {
                callback(
                    false,
                    NSError(
                        domain: "PhoneWatchContinuityTests", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Mirror delivery failed"]))
            }
        }
        #expect(failure.0 == false)
        #expect(failure.1 == "Mirror delivery failed")

        let success: (Bool, String?) = await withCheckedContinuation { continuation in
            let callback = CompanionCallbackBoundary.mirrorSendHandler { delivered, text in
                continuation.resume(returning: (delivered, text))
            }
            Task.detached { callback(true, nil) }
        }
        #expect(success.0 == true)
        #expect(success.1 == nil)
    }

    @Test func inboundMessagesWaitForDurableHandlerBeforeNextDelivery() async {
        let queue = CompanionInboundQueue()
        var order: [String] = []
        queue.submit {
            order.append("save-start")
            await Task.yield()
            order.append("save-complete")
        }
        queue.submit { order.append("next-message") }
        await queue.drain()
        #expect(order == ["save-start", "save-complete", "next-message"])
    }
}
