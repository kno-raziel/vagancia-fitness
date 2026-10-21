# Architecture

The repository contains native Apple clients, a local Swift package and platform-independent contracts. It is offline-first: storage and diagnostic export are local, and no project backend is required. [Product scope](../PRODUCT.md) defines supported behavior and platform availability.

## Applications and module boundaries

| Component | Responsibility | Source |
| --- | --- | --- |
| VaganciaFitness | Workout UI, routines, history and iPhone control flow | [Product source](../apple/Apps/VaganciaFitness) |
| VaganciaFitnessDebug | GATT inspection and diagnostic evidence | [Diagnostic source](../apple/Apps/VaganciaFitnessDebug) |
| VaganciaFitnessWatch | Workout/HealthKit capture and metric presentation | [Watch source](../apple/Apps/VaganciaFitnessWatch) |
| FitnessCore | Protocol decoding, models and companion contracts | [Core source](../apple/Packages/FitnessKit/Sources/FitnessCore) |
| FitnessRuntime | BLE transport, persistence, exports and coordination | [Runtime source](../apple/Packages/FitnessKit/Sources/FitnessRuntime) |
| shared | Language-independent protocols, export contracts, vectors and canonical brand assets | [Shared material](../shared/README.md) |

Product and Debug have independent installation identities and data containers so diagnostic exploration does not share the workout app's store. The Watch belongs to the product companion flow and has no motor-control authority.

FitnessCore keeps parsers and domain models independent of SwiftUI and CoreBluetooth so captured packets exercise production decoding without a radio connection. FitnessRuntime supplies Apple execution behavior. HealthKit, platform lifecycle and callback isolation remain native because they depend on platform APIs. A mobile monorepo does not require a shared cross-platform runtime; Android can implement the same contracts and vector expectations with its own lifecycle and health integration.

## Find the implementation for a change

| Area | Implementation entry point | Executable coverage |
| --- | --- | --- |
| FTMS decoding and range units | [FTMSDecoder](../apple/Packages/FitnessKit/Sources/FitnessCore/Protocols/FTMS/FTMSDecoder.swift) | [FTMS tests](../apple/Packages/FitnessKit/Tests/FitnessCoreTests/FTMS) |
| BLE discovery, subscriptions and procedure handling | [BluetoothExplorer](../apple/Packages/FitnessKit/Sources/FitnessRuntime/Bluetooth/BluetoothExplorer.swift) | [Bluetooth evidence tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/Diagnostics/BluetoothEvidenceTests.swift) and [reception tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/Diagnostics/DistanceAndReceptionTests.swift) |
| Workout lifecycle, targets and background coordination | [WorkoutCoordinator](../apple/Packages/FitnessKit/Sources/FitnessRuntime/Workouts/WorkoutCoordinator.swift) | [Coordinator integration tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/Workouts/WorkoutCoordinatorIntegrationTests.swift) |
| Durable diagnostic capture | [SessionStore](../apple/Packages/FitnessKit/Sources/FitnessRuntime/Evidence/SessionStore.swift) | [Session store tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/Diagnostics/SessionStoreTests.swift) |
| Diagnostic archive projections and privacy | [DiagnosticExporter](../apple/Packages/FitnessKit/Sources/FitnessRuntime/Evidence/DiagnosticExporter.swift) | [Public-support tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/Diagnostics/PublicSupportExportTests.swift) |
| iPhone/Watch delivery and reconciliation | [PhoneWatchService](../apple/Packages/FitnessKit/Sources/FitnessRuntime/Companion/PhoneWatchService.swift) | [Continuity tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/PhoneWatchContinuityTests.swift) and [sync integration tests](../apple/Packages/FitnessKit/Tests/FitnessRuntimeTests/WatchSyncIntegrationTests.swift) |
| Native workout and diagnostic navigation | [Product features](../apple/Apps/VaganciaFitness/Features) and [Debug source](../apple/Apps/VaganciaFitnessDebug) | [Product UI tests](../apple/Apps/VaganciaFitness/UITests) and the Debug UI suite in the [project specification](../apple/project.yml) |

## Connection and workout flow

The iPhone discovers/connects through CoreBluetooth and uses FTMS where supported. Remembered-device connection restores a BLE link; it does not start movement or replay a command. Advertised ranges constrain targets, while received telemetry supplies measurements and target confirmation.

Workout coordination owns session state, interval targets, manual overrides and companion integration. Planned targets, effective settings and received measurements remain distinct. A stale/missing observation cannot establish sustained confirmation. Background telemetry reception does not itself guarantee background interval execution; software behavior and real-device continuity require separate validation.

The Watch captures heart rate, energy and workout state through HealthKit. WatchConnectivity and workout mirroring provide distinct communication paths; immediate reachability is not continuous connectivity or proof of health capture. The iPhone reconciles companion messages through persisted identity and acknowledgements. [Workout contracts](../shared/contracts/workout-export/README.md) define stored evidence and companion result semantics.

## Movement constraints and evidence

A successful BLE write, control-point reply or advertised GATT capability does not prove physical movement. The app durably records explicit operator intent before a motor request. A persistence failure prevents that write. Prepare subscriptions and a Stop path before movement; Bluetooth stop does not replace a physical emergency stop.

Timeouts and connection loss produce uncertainty. The app does not automatically retry movement or infer that the belt stops. Target verification uses distinct, fresh post-acceptance observations; loss of confirmation suspends automation. These restrictions prevent a reconnection or stale event from silently authorizing another motor action.

[FTMS](../shared/protocols/ftms.md) defines units, procedure ownership and distance semantics. [FitShow](../shared/protocols/fitshow.md) defines bounded vendor observation behavior; proprietary movement remains disabled. Matching UUIDs does not establish compatible commands.

## Persistence, callbacks and exports

System entry points use production callback factories that accept off-main invocation and publish actor-isolated state on the appropriate actor. The Watch callback target compiles the same result handling source as the companion app, without requiring a live health query.

The runtime preserves FIFO event capture, durable-write ordering, export barriers, stable-identity deduplication and persisted acknowledgements. Accepted evidence reaches storage before an export crosses its barrier. Companion rejections retain original bytes and context in complete exports; unknown or omitted data is not treated as successful verification.

[Diagnostic contracts](../shared/contracts/diagnostic-export/README.md) define complete and public-support projections. [Privacy](../PRIVACY.md) defines local storage and sharing boundaries. Keeping projections explicit protects the complete evidence stream from destructive redaction.

Installation IDs and existing preferences remain stable across app updates. The data-directory resolver runs before opening iOS stores; same-container renaming includes SQLite sidecars, routines, journals and unknown files. On failure or a conflicting destination, it uses the established store without merging or replacing it. [Apple development](development/apple.md#app-naming-and-update-identity) documents configuration and update identity.

## Verification

[Software checks](testing/software.md) map behavior to the Core, Runtime, callback and UI suites. Canonical vector/asset mirrors are checked by `scripts/check-contracts`; the localization validator checks five Spanish/English catalogs and optional compiler extraction. [Hardware evidence](testing/hardware.md) describes the additional observations required for physical claims. Run results remain timestamped evidence rather than permanent claims in this guide.
