import FitnessCore

/// Control-plane envelopes are classified before workout data validation.
enum CompanionInboundRoute {
    case preparationReadiness
    case terminalResult(HealthSaveResult)
    case statusRequest
    case workoutData

    init(_ message: CompanionMessage, pendingID: String?, cancelledIDs: Set<String>) {
        switch message.payload {
        case .readiness
        where message.sessionID == "setup" || message.sessionID == pendingID
            || cancelledIDs.contains(message.sessionID):
            self = .preparationReadiness
        case .healthResult(let result)
        where [.saved, .failed, .uncertain, .discarded].contains(result.state):
            self = .terminalResult(result)
        case .statusRequest:
            self = .statusRequest
        default:
            self = .workoutData
        }
    }
}
