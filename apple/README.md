# Apple apps

This directory contains the generated Xcode project, its XcodeGen source, two iOS apps, the watchOS companion, shared FitnessKit package, configuration, and localization validator.

- `VaganciaFitness`: workout product.
- `VaganciaFitnessDebug`: Bluetooth diagnostic app with a separate identity and data.
- `VaganciaFitnessWatch`: workout capture and HealthKit companion; it has no treadmill motor authority.
- `Packages/FitnessKit`: shared protocol, runtime, persistence, and export code.

See the [Apple development guide](../docs/development/apple.md) for commands and signing setup. Keep local signing settings in `Config/Local.xcconfig`, which is ignored; recreate it from `Config/Local.xcconfig.example` when needed.
