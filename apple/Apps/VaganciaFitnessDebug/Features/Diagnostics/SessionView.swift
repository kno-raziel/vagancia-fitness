import FitnessCore
import FitnessRuntime
import SwiftUI

// Direction: a native iPhone session journal. One task at a time, semantic colors,
// Dynamic Type and system navigation. The first screen explains the current scope
// and exposes session creation; a running session exposes notes, closure and export.
// Evidence is real app activity; hardware verification remains explicitly pending.
struct SessionView: View {
    let store: SessionStore
    let bluetooth: BluetoothExplorer
    let metadata: AppMetadata
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNote = false
    @State private var confirmingClose = false
    @State private var export: DiagnosticExport?
    @State private var errorMessage: String?
    @State private var exporting = false
    @State private var preparingSession = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BluetoothDiscoveryView(explorer: bluetooth, store: store)
                    } label: {
                        Label("Conectar caminadora", systemImage: "antenna.radiowaves.left.and.right").frame(
                            minHeight: 44)
                    }
                    .accessibilityIdentifier("openBluetooth")
                    if store.session?.device != nil {
                        NavigationLink {
                            LiveDashboardView(explorer: bluetooth, store: store)
                        } label: {
                            Label("Panel y protocolos", systemImage: "slider.horizontal.3").frame(minHeight: 44)
                        }.accessibilityIdentifier("openLivePanel")
                    }
                    Text(
                        "Explora los servicios Bluetooth y comparte el diagnóstico. El registro también guarda tus notas."
                    )
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let startupError = store.startupError {
                    Section("No se pudo abrir el registro") {
                        Text(startupError).foregroundStyle(Color.primary)
                        Button("Volver a intentar") { perform { try store.reload() } }
                    }
                }
                if let persistenceError = store.persistenceError {
                    Section("No se pudo guardar el registro") {
                        Text(persistenceError)
                    }
                }

                if let session = store.session {
                    sessionSection(session)
                    actionsSection(session)
                    eventsSection(session)
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("Tu primera sesión", systemImage: "text.book.closed")
                        } description: {
                            Text("Inicia un registro para guardar notas y comprobar la exportación.")
                                .foregroundStyle(Color.primary)
                        }
                        Button(action: startSession) {
                            Label("Iniciar sesión", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("ActionFill"))
                        .foregroundStyle(.white)
                        .disabled(!store.storageReady || preparingSession)
                        .accessibilityIdentifier("startSession")
                    }
                }
            }
            .navigationTitle("Registro")
            .sheet(isPresented: $showingNote) { NoteView(store: store) }
            .sheet(item: $export) { export in ExportView(export: export) }
            .confirmationDialog(
                "¿Finalizar la sesión?", isPresented: $confirmingClose, titleVisibility: .visible
            ) {
                Button("Finalizar sesión") { perform { try store.closeSession() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(
                    "El registro quedará guardado y podrás exportarlo. Después puedes iniciar otra sesión.")
            }
            .alert(
                "No se pudo completar la acción",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("Aceptar", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func sessionSection(_ session: DiagnosticSession) -> some View {
        Section("Sesión") {
            LabeledContent("Estado") {
                Text(session.isOpen ? "En curso" : "Finalizada").foregroundStyle(Color.primary)
            }
            LabeledContent("Inicio") {
                Text(session.startedAt, format: .dateTime.day().month().hour().minute()).foregroundStyle(
                    Color.primary
                ).multilineTextAlignment(.trailing)
            }
            if let end = session.endedAt {
                LabeledContent("Fin") {
                    Text(end, format: .dateTime.hour().minute()).foregroundStyle(Color.primary)
                }
            }
            LabeledContent("Caminadora") {
                Text(bluetooth.hasConnection ? bluetooth.phase.title : "Sin conectar").foregroundStyle(
                    Color.primary)
            }
            Text(
                "La presencia de servicios no verifica funciones físicas. Las notas se conservan como observaciones del operador."
            )
            .font(.footnote).foregroundStyle(Color.primary)
            if session.droppedEventCount > 0 {
                Label(
                    "Se omitieron \(session.droppedEventCount) eventos antiguos por el límite del registro. El reporte lo indicará.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
            }
        }
    }

    private func actionsSection(_ session: DiagnosticSession) -> some View {
        Section {
            if session.isOpen {
                Button {
                    showingNote = true
                } label: {
                    Label("Agregar nota", systemImage: "square.and.pencil").frame(minHeight: 44)
                }
                .accessibilityIdentifier("addNote")
            }
            Button {
                exporting = true
                Task { @MainActor in
                    defer { exporting = false }
                    do { export = try await store.exportAsync(metadata: metadata) } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    Label("Exportar diagnóstico", systemImage: "square.and.arrow.up")
                    if exporting { ProgressView() }
                }.frame(minHeight: 44)
            }
            .disabled(exporting)
            .accessibilityIdentifier("exportDiagnostic")
            if session.isOpen {
                Button {
                    confirmingClose = true
                } label: {
                    Label("Finalizar sesión", systemImage: "stop.circle").frame(minHeight: 44)
                }
                .disabled(bluetooth.hasActivity)
                .accessibilityIdentifier("closeSession")
                if bluetooth.hasActivity {
                    Text("Desconecta la caminadora y detén la búsqueda antes de finalizar la sesión.").font(
                        .footnote
                    ).foregroundStyle(Color.primary)
                }
            } else {
                Button(action: startSession) {
                    Label("Nueva sesión", systemImage: "plus").frame(minHeight: 44)
                }
                .disabled(preparingSession)
                .accessibilityIdentifier("startSession")
            }
        } footer: {
            Text(
                "El registro se guarda en este iPhone. Las sesiones anteriores permanecen almacenadas; exporta la actual antes de comenzar otra para tenerla a mano."
            ).foregroundStyle(Color.primary)
        }
    }

    private func eventsSection(_ session: DiagnosticSession) -> some View {
        Section("Registro · \(session.totalEventCount - session.droppedEventCount) eventos guardados") {
            if session.events.count < session.totalEventCount - session.droppedEventCount {
                Text(
                    "Aquí se muestran los últimos \(session.events.count). El ZIP incluye todos los eventos guardados."
                )
                .font(.footnote).foregroundStyle(Color.primary)
            }
            ForEach(session.events.reversed()) { event in
                NavigationLink {
                    EventDetailView(event: event)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title).font(.headline)
                            Spacer()
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption).foregroundStyle(Color.primary).monospacedDigit()
                        }
                        Text(event.detail).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func startSession() {
        guard !preparingSession else { return }
        preparingSession = true
        Task { @MainActor in
            defer { preparingSession = false }
            do {
                try await store.flush()
                try store.startSession()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NoteView: View {
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var errorMessage: String?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Observación del operador") {
                    TextEditor(text: $note)
                        .frame(minHeight: 180)
                        .focused($editing)
                        .accessibilityLabel("Nota")
                        .accessibilityIdentifier("noteEditor")
                    Text("\(note.count) / 2.000 caracteres").font(.caption).foregroundStyle(Color.primary)
                }
                Section {
                    Text(
                        "La nota se identificará como información reportada por ti, separada de las mediciones del equipo."
                    ).foregroundStyle(Color.primary)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(
                            Color.primary)
                    }
                }
            }
            .navigationTitle("Agregar nota")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        do {
                            try store.addNote(note)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(
                        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2_000
                    )
                    .accessibilityIdentifier("saveNote")
                }
            }
            .interactiveDismissDisabled(!note.isEmpty)
            .onAppear { editing = true }
        }
    }
}

private struct ExportView: View {
    let export: DiagnosticExport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Reporte preparado", systemImage: "checkmark.circle").font(.headline)
                    Text(
                        "Guárdalo en Archivos o compártelo. El ZIP contiene el contexto, los resultados pendientes y el registro de eventos."
                    ).foregroundStyle(Color.primary)
                    ShareLink(item: export.archiveURL) {
                        Label("Compartir ZIP", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("shareZIP")
                }
                Section("Archivos individuales") {
                    ForEach(export.fileURLs, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.lastPathComponent, systemImage: "doc").frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("Exportar diagnóstico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }
}

private struct EventDetailView: View {
    let event: DiagnosticEvent
    var body: some View {
        List {
            Section("Evento") {
                LabeledContent("Origen") {
                    Text(
                        event.source == .userReported
                            ? "Operador"
                            : event.source == .hardware
                                ? "Bluetooth observado" : event.source == .synthetic ? "Sintético" : "Aplicación"
                    ).foregroundStyle(Color.primary)
                }
                LabeledContent("Secuencia") { Text(String(event.sequence)).foregroundStyle(Color.primary) }
                LabeledContent("Tiempo registrado") {
                    Text("\(event.elapsedMilliseconds) ms").foregroundStyle(Color.primary)
                }
                Text(event.detail).textSelection(.enabled)
            }
            Section("JSON original") {
                Text(
                    (try? EvidenceJSON.encoder(pretty: true).encode(event)).flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? "No se pudo presentar el evento."
                )
                .font(.footnote.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
