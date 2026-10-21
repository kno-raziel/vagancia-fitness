import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

@main
struct VaganciaFitnessApp: App {
    var body: some Scene {
        WindowGroup {
            VaganciaFitnessRootView()
                .tint(FitnessPalette.accent)
                .font(FitnessType.body())
                .foregroundStyle(FitnessPalette.text)
                .preferredColorScheme(.dark)
        }
    }
}

extension WorkoutPhase {
    var title: String { localizedTitle() }
}

extension WorkoutInterval {
    var durationLabel: String {
        let seconds = max(0, durationSeconds)
        return seconds >= 60
            ? String(localized: "\(seconds / 60) min", bundle: .main)
                + (seconds % 60 == 0 ? "" : String(localized: " \(seconds % 60) s", bundle: .main))
            : String(localized: "\(seconds) s", bundle: .main)
    }
}

extension WorkoutProgram {
    var durationSeconds: Int { intervals.reduce(0) { $0 + $1.durationSeconds } }
    var estimatedDistance: Double {
        intervals.reduce(0) { $0 + $1.targetSpeedKPH * Double($1.durationSeconds) / 3600 }
    }
}

struct VaganciaFitnessRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = Self.makeCoordinator()
    @State private var watchService = PhoneWatchService()
    #if DEBUG
        @State private var diagnosticFixtureTask: Task<Void, Never>?
        @State private var naturalEndFixtureStarted = false
    #endif
    @State private var selectedTab: AppTab = .home
    @State private var showWorkout = false
    @State private var banner: String?

    private static var dataDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["VAGANCIAFITNESS_DATA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return ApplicationDataDirectory.resolve()
    }

    private static func makeCoordinator() -> WorkoutCoordinator {
        #if DEBUG
            let delay: Duration? =
                ProcessInfo.processInfo.arguments.contains("--ui-test-settings-writes-4hz")
                ? .milliseconds(350) : nil
            return WorkoutCoordinator(directory: dataDirectory, diagnosticWriterDelay: delay)
        #else
            return WorkoutCoordinator(directory: dataDirectory)
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(
                    coordinator: coordinator, selectTab: { selectedTab = $0 }, startWorkout: beginFree,
                    startProgram: beginProgram)
            }
            .tabItem { Label(String(localized: "Inicio", bundle: .main), systemImage: "house") }.tag(
                AppTab.home)
            NavigationStack { ProgramListView(coordinator: coordinator, startWorkout: beginProgram) }
                .tabItem {
                    Label(String(localized: "Programas", bundle: .main), systemImage: "list.bullet.rectangle")
                }.tag(AppTab.programs)
            NavigationStack {
                ActivityView(coordinator: coordinator, selectPrograms: { selectedTab = .programs })
            }
            .tabItem {
                Label(String(localized: "Actividad", bundle: .main), systemImage: "waveform.path.ecg")
            }.tag(AppTab.activity)
            NavigationStack { settingsView }
                .tabItem { Label(String(localized: "Ajustes", bundle: .main), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tabBarMinimizeBehavior(.never)
        .toolbarBackground(FitnessPalette.paper, for: .tabBar)
        .fullScreenCover(isPresented: $showWorkout, onDismiss: { coordinator.refresh() }) {
            WorkoutFlowView(
                coordinator: coordinator, close: { showWorkout = false },
                returnToActivity: {
                    selectedTab = .activity
                    showWorkout = false
                }
            )
            .statusBarHidden(false)
        }
        .alert(
            "VAGANCIA FITNESS",
            isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })
        ) {
            Button("OK") { banner = nil }
        } message: {
            Text(banner ?? "")
        }
        .environment(watchService)
        .onAppear {
            coordinator.attachCompanion(watchService)
            watchService.onEvent = { kind, message in
                coordinator.recordCompanionEvent(kind, message: message)
            }
            watchService.activate()
            coordinator.refresh()
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-watch-conflict") {
                    watchService.configureUITestFixture()
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-natural-end"),
                    !naturalEndFixtureStarted
                {
                    naturalEndFixtureStarted = true
                    Task {
                        do {
                            coordinator.setMockMode(true)
                            let fixture = WorkoutProgram(
                                name: String(localized: "Final natural de prueba", bundle: .main),
                                intervals: [
                                    WorkoutInterval(durationSeconds: 15, targetSpeedKPH: 0.8, phase: .steady)
                                ])
                            try await coordinator.start(program: fixture)
                            showWorkout = true
                            try await coordinator.confirmAndStart()
                        } catch {
                            notify(
                                String(
                                    localized:
                                        "No se pudo iniciar la prueba sintética: \(error.localizedDescription)",
                                    bundle: .main))
                        }
                    }
                }
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: coordinator.foregrounded()
            case .background: coordinator.backgrounded()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private func beginFree() {
        Task {
            do {
                try await coordinator.startFree()
                showWorkout = true
            } catch { notify(error.localizedDescription) }
        }
    }
    private func beginProgram(_ program: WorkoutProgram) {
        Task {
            do {
                try await coordinator.start(program: program)
                showWorkout = true
            } catch { notify(error.localizedDescription) }
        }
    }
    private func notify(_ message: String) { banner = message }

    @ViewBuilder private var settingsView: some View {
        #if DEBUG
            SettingsView(
                coordinator: coordinator, showMessage: notify,
                diagnosticFixtureControl: controlDiagnosticFixture)
        #else
            SettingsView(coordinator: coordinator, showMessage: notify)
        #endif
    }

    #if DEBUG
        private func controlDiagnosticFixture(_ shouldRun: Bool) {
            if !shouldRun {
                diagnosticFixtureTask?.cancel()
                diagnosticFixtureTask = nil
                return
            }
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-settings-writes-4hz"),
                diagnosticFixtureTask == nil
            else { return }
            diagnosticFixtureTask = Task { @MainActor in
                // Synthetic evidence exercises the real delayed SQLite writer.
                // It neither opens Bluetooth nor sends a treadmill command.
                try? coordinator.store.startSession()
                while !Task.isCancelled {
                    try? coordinator.store.record(
                        kind: "ftms.treadmill.received", source: .synthetic,
                        payload: ["fixture": .string("ui-test-4hz")])
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    #endif
}

enum AppTab: Hashable { case home, programs, activity, settings }

struct ScreenContent<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }.padding(.horizontal, 22).padding(
                .top, 12
            ).padding(.bottom, 32).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.fitnessSurface()
    }
}

struct SectionTitle: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle: String = String(localized: "Ver todo", bundle: .main)
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }
    var body: some View {
        layout {
            Text(title).font(FitnessType.body(.title3, weight: .semibold)).fixedSize(
                horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let action {
                Button(actionTitle, action: action).font(FitnessType.body(.subheadline, weight: .semibold))
                    .frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricValue: View {
    let value: String
    let unit: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                Text(unit).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgramProfile: View {
    let intervals: [WorkoutInterval]
    var dark = false
    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(intervals.enumerated()), id: \.element.id) { index, interval in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(interval.phase == .work ? FitnessPalette.red : FitnessPalette.text.opacity(0.42))
                        .frame(
                            height: max(12, proxy.size.height * CGFloat(min(16, interval.targetSpeedKPH) / 16))
                        )
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(
                            String(
                                localized:
                                    "Etapa \(index + 1), \(interval.phase.title), \(interval.targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) kilómetros por hora",
                                bundle: .main))
                }
            }
        }.frame(height: 72).accessibilityElement(children: .combine).accessibilityLabel(
            String(localized: "Perfil de velocidad del programa", bundle: .main))
    }
}

struct EmptyHistory: View {
    var action: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(
                String(localized: "Tu historia empieza aquí", bundle: .main), systemImage: "figure.walk")
        } description: {
            Text(
                String(
                    localized: "Termina una sesión para ver aquí su duración y las mediciones recibidas.",
                    bundle: .main))
        } actions: {
            Button(String(localized: "Explorar programas", bundle: .main), action: action).buttonStyle(
                .glassProminent)
        }.accessibilityIdentifier("activity-empty-state")
    }
}
