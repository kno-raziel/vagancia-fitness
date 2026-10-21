import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct ControlPreparationGateTests {
    @Test func waitsForDelayedSubscriptionCallback() async throws {
        var indicated = false
        var statusNotifying = false
        let clock = ContinuousClock()
        let started = clock.now
        let callback = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(80))
            indicated = true
            statusNotifying = true
        }
        try await ControlPreparationGate.wait(
            timeout: .milliseconds(500),
            ready: { indicated && statusNotifying }, available: { true })
        try await callback.value
        #expect(clock.now - started >= .milliseconds(70))
    }

    @Test func deadlineAndConnectionLossDoNotClaimReadiness() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await ControlPreparationGate.wait(
                timeout: .milliseconds(90), ready: { false }, available: { true })
            Issue.record("El gate aceptó una suscripción nunca confirmada")
        } catch {}
        #expect(clock.now - started >= .milliseconds(80))

        var connected = true
        let disconnect = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(40))
            connected = false
        }
        do {
            try await ControlPreparationGate.wait(
                timeout: .seconds(1), ready: { false }, available: { connected })
            Issue.record("El gate aceptó la conexión perdida")
        } catch {}
        try await disconnect.value
    }
}
