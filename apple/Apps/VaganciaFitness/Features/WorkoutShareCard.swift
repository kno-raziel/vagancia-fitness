import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

/// A local image of saved evidence. Missing readings are omitted rather than estimated.
@MainActor
enum WorkoutShareCardRenderer {
    static func png(record: WorkoutRecord, samples: [WorkoutRecordedSample], isExample: Bool) throws
        -> URL
    {
        let distance = samples.last { $0.metric == "sessionDistanceMeters" }
        let activeSeconds = max(
            0,
            record.latestSnapshot.activeElapsedSeconds
                ?? (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
        let card = WorkoutShareCard(
            record: record, distance: distance, activeSeconds: activeSeconds, isExample: isExample
        )
        .frame(width: 390, height: 690)
        .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaganciaFitnessShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vagancia-sesion-\(record.id).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct WorkoutShareCard: View {
    let record: WorkoutRecord
    let distance: WorkoutRecordedSample?
    let activeSeconds: TimeInterval
    let isExample: Bool

    private var duration: String {
        let seconds = Int(activeSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var distanceSource: String {
        guard let distance else { return "" }
        return switch distance.sample.source {
        case .machineFTMS: String(localized: "FTMS · máquina", bundle: .main)
        case .derived: String(localized: "Derivada de FTMS", bundle: .main)
        case .watchHealthKit: "HealthKit · Watch"
        case .mock: String(localized: "Simulada", bundle: .main)
        case .unknown: String(localized: "Origen desconocido", bundle: .main)
        }
    }

    var body: some View {
        ZStack {
            FitnessPalette.canvas
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image("FitnessMark").resizable().scaledToFit().frame(width: 38, height: 38)
                    Image("FitnessWordmark").resizable().scaledToFit().frame(width: 112, height: 38)
                    Spacer()
                }
                Spacer(minLength: 52)
                Text(
                    record.interrupted
                        ? String(localized: "SESIÓN INTERRUMPIDA", bundle: .main)
                        : String(localized: "SESIÓN GUARDADA", bundle: .main)
                )
                .font(FitnessType.metadata).tracking(1.1).foregroundStyle(
                    record.interrupted ? Color.orange : FitnessPalette.accent)
                Text(
                    record.program?.localizedSeedName()
                        ?? String(localized: "Entrenamiento libre", bundle: .main)
                )
                .font(FitnessType.title(34)).foregroundStyle(FitnessPalette.text)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                Text(record.startedAt.formatted(date: .complete, time: .shortened))
                    .font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary).padding(
                        .top, 10)
                Rectangle().fill(FitnessPalette.border).frame(height: 1).padding(.vertical, 30)
                Text(duration).font(
                    .system(size: 72, weight: .semibold, design: .rounded).monospacedDigit()
                )
                .foregroundStyle(FitnessPalette.text)
                Text(String(localized: "TIEMPO ACTIVO", bundle: .main)).font(FitnessType.metadata).tracking(
                    1
                ).foregroundStyle(FitnessPalette.secondary)
                if let distance, distance.sample.value.isFinite {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text((distance.sample.value / 1_000).formatted(.number.precision(.fractionLength(2))))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("km").font(FitnessType.body(.title2))
                    }.foregroundStyle(FitnessPalette.text).padding(.top, 28)
                    Text(String(localized: "DISTANCIA REGISTRADA · \(distanceSource)", bundle: .main))
                        .font(FitnessType.metadata).foregroundStyle(FitnessPalette.secondary)
                }
                Spacer(minLength: 24)
                if record.interrupted {
                    Text(
                        String(
                            localized: "Parada física sin confirmar. Usa la consola del equipo.", bundle: .main)
                    )
                    .font(FitnessType.body(.caption)).foregroundStyle(.orange)
                }
                if isExample {
                    Text(String(localized: "EJEMPLO · DATOS SIMULADOS", bundle: .main))
                        .font(FitnessType.body(.headline, weight: .bold)).tracking(0.5)
                        .foregroundStyle(FitnessPalette.canvas)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(FitnessPalette.text)
                        .padding(.top, 16)
                }
            }.padding(28)
        }
    }
}
