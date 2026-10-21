import FitnessCore
import Foundation

/// Internal seam for deterministic runtime tests. Production uses the one
/// BluetoothExplorer owned and exposed by WorkoutCoordinator for UI controls.
@MainActor
protocol WorkoutControlTransport: AnyObject {
    var phase: BluetoothPhase { get }
    var selectedProtocol: DiagnosticProtocol { get }
    var control: FTMSControl { get }
    var snapshot: GATTDevice? { get }
    func prepareControlAndWait(timeout: Duration) async throws
    func executeAndWait(
        _ action: FTMSAction, speed: Double?, inclination: Double?,
        allowProgramBackground: Bool, timeout: Duration
    ) async throws -> FTMSProcedure
    func setProgramBackgroundLease(_ enabled: Bool)
}

extension BluetoothExplorer: WorkoutControlTransport {}

extension WorkoutControlTransport {
    func prepareControlAndWait() async throws {
        try await prepareControlAndWait(timeout: .seconds(10))
    }
    func executeAndWait(
        _ action: FTMSAction, speed: Double? = nil, inclination: Double? = nil,
        allowProgramBackground: Bool = false
    ) async throws -> FTMSProcedure {
        try await executeAndWait(
            action, speed: speed, inclination: inclination,
            allowProgramBackground: allowProgramBackground, timeout: .seconds(10))
    }
}
