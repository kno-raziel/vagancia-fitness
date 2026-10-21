import HealthKit
import SwiftUI
import WatchKit

@main
struct VaganciaFitnessWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var service = WatchWorkoutService.shared
    var body: some Scene {
        WindowGroup {
            WatchRootView(service: service)
                .tint(WatchBrand.fire).preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--watch-ui-preview"),
                            ProcessInfo.processInfo.arguments.indices.contains(index + 1)
                        {
                            service.loadPreview(ProcessInfo.processInfo.arguments[index + 1])
                            return
                        }
                    #endif
                    service.activate()
                }
        }
    }
}

@MainActor
final class WatchAppDelegate: NSObject, WKExtensionDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchWorkoutService.shared.handleLaunchConfiguration(workoutConfiguration)
    }
    func handleActiveWorkoutRecovery() { WatchWorkoutService.shared.scheduleRecovery() }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchWorkoutService.shared.handleBackgroundTasks(backgroundTasks)
    }
}
