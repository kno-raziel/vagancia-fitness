# Product scope

VAGANCIA FITNESS is an offline-first native iOS workout product for FTMS treadmills. VaganciaFitness handles workouts, VaganciaFitnessDebug provides separate Bluetooth diagnosis, and VaganciaFitnessWatch captures workout and health data. The local FitnessKit package supplies shared Apple code. No account or project backend is required.

## Supported software behavior

The product provides free and programmed workouts, speed and inclination goals, local routines and history, notes, a share card and diagnostic exports. It supports Spanish and English in iPhone, Watch and FitnessKit resources. Device ranges and increments constrain targets; advertised support and received observations determine what the app can offer for the connected device.

Watch provides workout/HealthKit capture and metric presentation through the product's preparation flow. Watch pairing, immediate messaging, workout mirroring and health capture are distinct states. The Watch does not control the treadmill motor. [Using the app](docs/guides/using-the-app.md) explains these workflows.

## Evidence and movement

The app distinguishes advertised capabilities, protocol replies, received measurements and physical observations. Successful BLE writes or FTMS responses establish protocol outcomes, not calibrated speed, belt movement or physical stop. Missing metrics remain absent; synthetic metrics retain their source labels. [Device compatibility](docs/compatibility/devices.md) describes the reference device and current evidence boundaries.

Movement requires an explicit operator action. Commands are not automatically repeated after timeout or reconnection. A Bluetooth stop request is not an emergency stop, and disconnection does not establish that the belt stops. [Architecture](docs/architecture.md) describes enforcement and persistence boundaries.

## Platforms and limitations

Apple is implemented with SwiftUI, CoreBluetooth, HealthKit and SQLite on iOS/watchOS 26 or later. Android is future native work with no application, build or compatibility claim here. [Platform scope](docs/compatibility/platforms.md) is the platform reference; [project settings](apple/project.yml) define build versions.

FTMS is preferred. The proprietary FitShow path exposes bounded observation/diagnostic behavior; proprietary movement remains disabled. The app does not infer vendor compatibility from UUIDs alone. Physical treadmill behavior, background continuity and sensor accuracy require explicitly scoped hardware validation.

## Distribution and reporting

This repository distributes source code. Contributors build the Apple apps locally using the [development guide](docs/development/apple.md). Reports and questions use the repository's GitHub Issues, following [SECURITY.md](SECURITY.md).

Project code uses the [MIT License](LICENSE). Fonts retain OFL, authorized project brand assets carry reserved trademark rights, and FitShow reference screenshots/manifests remain private. [Third-party notices](THIRD_PARTY_NOTICES.md) define the asset conditions.
