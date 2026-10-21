import FitnessCore
import FitnessRuntime
import SwiftUI

struct HomeView: View {
    @Bindable var coordinator: WorkoutCoordinator
    let selectTab: (AppTab) -> Void
    let startWorkout: () -> Void
    let startProgram: (WorkoutProgram) -> Void
    @State private var recentSpeedSample: WorkoutRecordedSample?

    private var recent: WorkoutRecord? { coordinator.history.first }
    private var featured: WorkoutProgram? { coordinator.programs.first }

    var body: some View {
        ScreenContent {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "A TU RITMO.", bundle: .main)).font(FitnessType.title()).fixedSize(
                    horizontal: false, vertical: true
                ).accessibilityIdentifier("home-title")
                Text(String(localized: "Conoce tu equipo.\nDecide cómo entrenar.", bundle: .main)).font(
                    FitnessType.body()
                ).foregroundStyle(FitnessPalette.secondary)
            }.padding(.top, 12)

            NavigationLink {
                DeviceSettingsView(coordinator: coordinator)
            } label: {
                HStack(spacing: 14) {
                    Image(
                        systemName: coordinator.bluetooth.hasConnection
                            ? "figure.run" : "antenna.radiowaves.left.and.right"
                    ).font(FitnessType.body(.title3)).foregroundStyle(FitnessPalette.accent).frame(
                        width: 28, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connectionTitle).font(FitnessType.body(.subheadline, weight: .semibold))
                        Text(connectionCaption).font(FitnessType.metadata).foregroundStyle(
                            FitnessPalette.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(FitnessType.body(.caption, weight: .semibold))
                        .foregroundStyle(FitnessPalette.secondary)
                }.padding(.vertical, 17)
                    .overlay(alignment: .top) { Rectangle().fill(FitnessPalette.border).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(FitnessPalette.border).frame(height: 1) }
            }.buttonStyle(.plain).accessibilityIdentifier("home-device-connection")

            if let featured {
                SectionTitle(
                    title: String(localized: "Tu próxima sesión", bundle: .main),
                    action: { selectTab(.programs) })
                VStack(alignment: .leading, spacing: 18) {
                    Text(featured.localizedSeedName()).font(FitnessType.title(29, relativeTo: .title))
                        .foregroundStyle(FitnessPalette.text)
                    ProgramProfile(intervals: featured.intervals, dark: true)
                    HStack {
                        Text(String(localized: "\(max(1, featured.durationSeconds / 60)) min", bundle: .main))
                            .font(FitnessType.body(.title3, weight: .semibold))
                        Spacer()
                        Text(String(localized: "\(featured.intervals.count) etapas", bundle: .main)).font(
                            FitnessType.metadata
                        ).foregroundStyle(FitnessPalette.secondary)
                    }
                    NavigationLink {
                        ProgramDetailView(
                            coordinator: coordinator, program: featured, startWorkout: startProgram)
                    } label: {
                        Label(String(localized: "Ver programa", bundle: .main), systemImage: "arrow.right")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).tint(FitnessPalette.text).accessibilityLabel(
                        String(localized: "Ver \(featured.localizedSeedName())", bundle: .main))
                }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
            }

            Button(action: startWorkout) {
                Label(String(localized: "Entrenamiento libre", bundle: .main), systemImage: "play.fill")
                    .font(FitnessType.body(.headline, weight: .semibold)).frame(
                        maxWidth: .infinity, minHeight: 54)
            }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                FitnessPalette.canvas
            ).accessibilityIdentifier("start-free-workout")

            SectionTitle(
                title: String(localized: "Tu actividad", bundle: .main), action: { selectTab(.activity) })
            if let recent {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                recent.program?.localizedSeedName()
                                    ?? String(localized: "Entrenamiento libre", bundle: .main)
                            ).font(FitnessType.body(.headline))
                            Text(recent.startedAt.formatted(date: .abbreviated, time: .shortened)).font(
                                FitnessType.body(.caption)
                            ).foregroundStyle(FitnessPalette.secondary)
                        }
                        Spacer()
                        Text(
                            recent.interrupted
                                ? String(localized: "Interrumpida", bundle: .main)
                                : String(localized: "Guardada", bundle: .main)
                        ).font(FitnessType.body(.caption, weight: .medium)).padding(.horizontal, 10).padding(
                            .vertical, 6
                        ).background(.quaternary, in: Capsule())
                    }
                    HStack {
                        MetricValue(
                            value: (recent.latestSnapshot.measuredSpeed?.value ?? recentSpeedSample?.sample.value)?
                                .formatted(.number.precision(.fractionLength(1))) ?? "—", unit: "km/h",
                            title: String(localized: "Velocidad recibida", bundle: .main))
                        MetricValue(
                            value: recent.sampleCount.formatted(), unit: "",
                            title: String(localized: "Mediciones", bundle: .main))
                    }
                    if let recentSpeedSample {
                        Text(
                            recentSpeedSample.sample.source.label
                                + (recentSpeedSample.sample.source == .mock
                                    ? String(localized: " · datos simulados", bundle: .main)
                                    : String(localized: " · fuente de la máquina", bundle: .main))
                        ).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                    }
                }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.35), lineWidth: 1))
            } else {
                Text(
                    String(
                        localized: "Aquí aparecerán tus sesiones guardadas, con el origen de cada medición.",
                        bundle: .main)
                ).font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
            }
            Text(String(localized: "Tus datos se guardan en este dispositivo.", bundle: .main)).font(
                FitnessType.body(.caption)
            ).foregroundStyle(FitnessPalette.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
        .navigationTitle("VAGANCIA FITNESS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { FitnessBrandHeader() } }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(FitnessPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: recent?.id) { loadRecentEvidence() }
        .onChange(of: coordinator.history) { _, _ in loadRecentEvidence() }
        .refreshable { coordinator.refresh() }
    }

    private var connectionCaption: String {
        switch coordinator.bluetooth.phase {
        case .ready:
            String(localized: "Bluetooth conectado · Lecturas según lo observado", bundle: .main)
        case .connecting: String(localized: "Conectando al equipo recordado…", bundle: .main)
        default: String(localized: "Sin conexión · puedes consultar o editar programas", bundle: .main)
        }
    }

    private var connectionTitle: String {
        if coordinator.bluetooth.hasConnection {
            return coordinator.bluetooth.snapshot?.advertisedName
                ?? coordinator.bluetooth.rememberedTreadmill?.name
                ?? String(localized: "Equipo conectado", bundle: .main)
        }
        return coordinator.bluetooth.rememberedTreadmill?.name
            ?? String(localized: "Conecta tu equipo", bundle: .main)
    }

    private func loadRecentEvidence() {
        guard let recent else {
            recentSpeedSample = nil
            return
        }
        recentSpeedSample = try? coordinator.loadSamples(for: recent.id).last(where: {
            $0.metric == "speedKPH"
        })
    }
}
