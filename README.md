# VAGANCIA FITNESS

VAGANCIA FITNESS is a native iOS workout app for FTMS treadmills, with an Apple Watch companion for workout and HealthKit capture. VaganciaFitnessDebug is a separate Bluetooth diagnostic app. The Apple apps share the local FitnessKit package. The product and Watch interface support Spanish and English.

The app inspects Bluetooth services, decodes FTMS telemetry, records workouts and exports evidence locally. Movement commands require an explicit operator action. Bluetooth stop is not an emergency stop. [Product scope](PRODUCT.md) defines supported features and evidence limits.

Distribution is source-only. Build the apps locally using the [Apple development guide](docs/development/apple.md); use the repository's GitHub Issues for reports and questions.

## Native app preview

<table>
  <tr>
    <th>Home</th><th>Workout</th><th>History</th><th>Debug</th>
  </tr>
  <tr>
    <td><img src="docs/images/app-home.png" alt="Native home screen with workout and program entry points" width="200"></td>
    <td><img src="docs/images/app-workout.png" alt="Demonstration workout with explicitly simulated measurements" width="200"></td>
    <td><img src="docs/images/app-history.png" alt="Local workout history containing a synthetic session" width="200"></td>
    <td><img src="docs/images/app-debug.png" alt="Separate Bluetooth diagnostic app showing synthetic telemetry" width="200"></td>
  </tr>
</table>

Open the full-size captures: [Home](docs/images/app-home.png), [Workout](docs/images/app-workout.png), [History](docs/images/app-history.png), [Debug](docs/images/app-debug.png).

These are native SwiftUI simulator captures from isolated UI-test scenarios, with synthetic data. They do not establish hardware compatibility or sensor accuracy. [Try the demonstration walkthrough](docs/guides/using-the-app.md#try-a-workout-without-hardware); [capture sources](docs/images/README.md) identify the reproducible test flows.

## Start here

- [Use the app](docs/guides/using-the-app.md): connect a treadmill, prepare Watch capture, train and export.
- [Develop on Apple platforms](docs/development/apple.md): tools, project generation, builds and tests.
- [Understand the architecture](docs/architecture.md): app boundaries, runtime behavior and rationale.
- [Browse the documentation](docs/README.md): current guides, contracts and policies.

Generate with `./apple/scripts/generate-project`, then open [`apple/VaganciaFitness.xcodeproj`](apple/VaganciaFitness.xcodeproj). Choose `VaganciaFitness`, `VaganciaFitnessDebug` or `VaganciaFitnessWatch`. The [project specification](apple/project.yml) defines build settings; [local configuration](docs/development/local-configuration.md) explains optional signing setup.

For documentation and repository tooling, `./scripts/check-repository` runs on macOS or Linux with Python 3.11+ and requires no Xcode. The [Apple setup guide](docs/development/apple.md#prepare-a-development-machine) covers the native toolchain and simulators.

The source targets iOS/watchOS 26 and uses Swift 6, SwiftUI, CoreBluetooth, HealthKit and SQLite. Android has no app, build, runtime or CI support in this repository; see [platform scope](docs/compatibility/platforms.md). [Shared contracts and vectors](shared/README.md) remain independent of Apple frameworks.

## Contribute and share

See [CONTRIBUTING.md](CONTRIBUTING.md), [privacy](PRIVACY.md) and [security reporting](SECURITY.md). Documentation and code comments use English; the app interface supports Spanish and English. Private captures, diagnostic originals, signing configuration and local verification evidence remain outside public source.

## License

Project code uses [MIT](LICENSE). Fonts retain OFL, the project brand has separate trademark conditions, and FitShow screenshots remain private. See [third-party notices](THIRD_PARTY_NOTICES.md).
