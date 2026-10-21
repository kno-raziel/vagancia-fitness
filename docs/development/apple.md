# Apple development

`apple/project.yml` is the XcodeGen source. From the repository root, regenerate with `./apple/scripts/generate-project`, then open `apple/VaganciaFitness.xcodeproj` and select `VaganciaFitness`, `VaganciaFitnessDebug`, or a test scheme in Xcode. Use the wrapper: it supplies the default bundle IDs and supports environment overrides. Do not invoke XcodeGen directly with unset ID variables.

The source targets iOS and watchOS 26 and uses Swift 6 language mode. Simulator builds do not require the operator's signing identity. Device signing requires a locally configured Apple development team.

## Prepare a development machine

1. Use a Mac supported by the chosen full Xcode installation. Xcode 26.1.1 and 26.2 require macOS Sequoia 15.6 or later; check [Apple's requirements](https://developer.apple.com/xcode/system-requirements/) for other versions. The standalone Command Line Tools do not include the required platform SDKs and simulators.
2. Obtain Xcode from [Apple Developer downloads](https://developer.apple.com/download/all/) or the Mac App Store. Open it, accept its license and finish the platform setup. Select the installation in Xcode Settings → Locations → Command Line Tools, or set `DEVELOPER_DIR` to its `Contents/Developer` directory for the current shell. Confirm `xcodebuild -version` and `xcrun swift --version`.
3. In Xcode Settings → Components, make an iOS 26-or-newer simulator runtime available that the selected Xcode supports. Include the watchOS SDK for the companion build. In Window → Devices and Simulators, create an iPhone simulator if none exists. `xcrun simctl list devices available` lists the installed choices; an SDK being present does not establish that its simulator runtime is installed.
4. Install [XcodeGen 2.44.1](https://github.com/yonaskolb/XcodeGen/releases/tag/2.44.1) and put its `xcodegen/bin` directory on `PATH`. The workflow verifies the release archive's SHA-256 before using it; use the same pinned release when reproducing project generation. Confirm `xcodegen --version`.
5. Supply Python 3.11 or newer, for example from [Python's macOS downloads](https://www.python.org/downloads/macos/), and confirm `python3 --version`. Repository checks and font conversion use the standard library. The optional local screenshot redactor additionally requires Pillow; ordinary development and checks do not depend on Pillow.
6. Run `./scripts/doctor`. It diagnoses the tools and available iOS 26+ simulators without installing them. Resolve missing components in Xcode or select an existing compatible installation, then generate the project.

| Environment | Xcode | Bundled Swift | Simulator runtime |
| --- | --- | --- | --- |
| Local reference | 26.1.1 | 6.2.1 | iOS 26.1 |
| GitHub Actions configuration | 26.2 | 6.2.3 | iOS 26.2, iPhone 17 Pro |

XcodeGen remains pinned to 2.44.1. The doctor supports the Xcode 26/Swift 6.2 family; `EXPECTED_XCODE_VERSION` and `EXPECTED_SWIFT_VERSION` request exact checks, as CI does. Supported environment selection is distinct from a recorded passing result.

The [official macOS runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) lists the CI Xcode and simulator pair. CI checks their actual availability before tests. Runner contents change, so review the pair together when updating the workflow. A local run does not establish that a hosted workflow passes.

## Generate, build and test

From the repository root:

```sh
./scripts/check
./apple/scripts/generate-project
./apple/scripts/build VaganciaFitness
./apple/scripts/build VaganciaFitnessDebug
./apple/scripts/build VaganciaFitnessWatch
CONFIGURATION=Release ./apple/scripts/build VaganciaFitness
CONFIGURATION=Release ./apple/scripts/build VaganciaFitnessDebug
CONFIGURATION=Release ./apple/scripts/build VaganciaFitnessWatch
./apple/scripts/test all
```

`DESTINATION` selects an iOS simulator; `WATCH_DESTINATION` separately selects a Watch simulator. Without an override, test groups select an available iPhone simulator on iOS 26 or newer. Results go to ignored `build/apple/Results/` bundles and full logs to `build/apple/logs/`. Method filters replace the whole-group selection, for example `./apple/scripts/test runtime -only-testing:FitnessRuntimeTests/PublicSupportExportTests`.

`CONFIGURATION` accepts `Debug` (the default) or `Release`. Release builds check the production conditional-compilation paths without signing. `test all` collects failures across independent groups and returns failure if any group fails. Native UI tests run synthetic scenarios in the simulator. Use the [hardware-free walkthrough](../guides/using-the-app.md#try-a-workout-without-hardware) for an interactive first run.

For documentation, contracts or repository tooling on macOS or Linux, use `./scripts/check-repository`. It needs Python but no Apple SDK, signing configuration or private evidence. The full `./scripts/check` also checks the Apple environment, Swift formatting and localization catalogs.

The localization validator is at `apple/scripts/validate-localizations.py`. From the repository root, run `python3 apple/scripts/validate-localizations.py`. It checks extracted resource catalogs and plural/argument consistency. The script can optionally compare compiler-extracted keys; see its command-line help for supported options.

The production callback factories are covered by tests that invoke them from detached/background execution. The `VaganciaFitnessWatchCallbackTests` target compiles callback result handling used by the Watch app without querying HealthKit. Keep these checks when changing callback isolation. Core, Runtime, product UI, Debug UI, and callback groups are separate software checks; passing them does not prove physical device behavior.

The [software-check guide](../testing/software.md) defines suite responsibilities, executable commands and result interpretation. Store dated results with their exact environment under ignored build/evidence directories; this guide does not assert a permanent passing result.

## App naming and update identity

Open `apple/VaganciaFitness.xcodeproj`. The product, diagnostics and companion schemes are `VaganciaFitness`, `VaganciaFitnessDebug` and `VaganciaFitnessWatch`; their source directories and test targets follow those names. The installed names are VAGANCIA FITNESS and VAGANCIA FITNESS Debug.

`Config/InstallationIdentity.sh` contains the fixed installation identifiers. They deliberately retain their original namespace so an update uses the existing iOS containers, HealthKit ownership and Watch companion association. Rename targets freely; do not change these IDs for an update to an existing installation. Fork overrides use the `VAGANCIAFITNESS_*_BUNDLE_ID` environment variables shown in `Config/Local.xcconfig.example`.

Before opening the iOS database, `ApplicationDataDirectory` renames the legacy Application Support directory within the same app container. The entire directory moves, including SQLite sidecars, routines, diagnostics and cached settings. If migration fails or both directories exist, the established directory is used without merging or overwriting stores. Watch paths, preference keys, message schemas and SQLite schemas retain their existing identities.

The root `scripts/check` includes `scripts/check-names`, which rejects obsolete naming in public paths and text except fixed installation IDs and the storage compatibility identifiers. Private historical evidence and recoverable backups are excluded from public source and retain original bytes.
