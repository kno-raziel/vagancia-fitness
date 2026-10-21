# Software checks

Software checks exercise protocol parsing, persistence, exports, callbacks and interfaces. Fixtures identify whether inputs are synthetic or derived from captured bytes. Each result belongs to its exact source, toolchain and environment; a historical passing count is not a current guarantee.

## Run the checks

From the repository root:

```sh
./scripts/check-repository
./scripts/check
./apple/scripts/test core
./apple/scripts/test runtime
./apple/scripts/test callbacks
./apple/scripts/test ui-product
./apple/scripts/test ui-debug
```

`./scripts/check` validates the local environment, Swift formatting, five Spanish/English catalogs, documentation links and current-state rules, shared contracts/resource mirrors, public distribution policy and app naming. [Apple development](../development/apple.md) describes simulator destinations, build commands and compiler-extracted localization checks. UI tests install synthetic scenarios on a simulator; run only repository/documentation checks for a prose-only change when app behavior is unchanged.

`./scripts/check-repository` runs repository policy, source privacy declarations, localization catalogs and synthetic tooling regressions without Xcode. It is the entry point for documentation-only contributions and the Linux repository workflow. Negative cases cover missing localization catalogs and unsupported format arguments, private-reference path containment and preflight behavior. Apple wrapper checks use mock tools rather than downloading SDKs; resource-tool fixtures exercise privacy declarations and font conversion.

The Apple workflow uses an explicitly selected Xcode/runtime pair, compiles all three apps in Debug and Release, checks privacy manifests in the built bundles, and runs the five test groups. Independent groups continue after a test failure; setup and build failures stop test execution. Failure evidence is retained through a pinned artifact action with bounded retention, limited to synthetic CI logs and test results. The repository’s GitHub Actions runs report hosted results for each commit; local results do not establish that a hosted run passes.

## Coverage and interpretation

| Group | Behavior under test |
| --- | --- |
| Core | FTMS/FitShow decoding, ranges, units, distance resets, workout/companion models and shared vectors |
| Runtime | BLE coordination, target verification, FIFO storage, export barriers, deduplication, durable ACKs and storage migration |
| Watch callbacks | Production callback result handling invoked off the main actor, without a live HealthKit query |
| Product UI | Workout/program navigation, controls, accessibility layouts, persistence, Watch preparation and exports |
| Debug UI | Diagnostic session flow, GATT/capability display, synthetic telemetry, protocol comparison and export |

Public-support export tests use sentinels across text, UUIDs and raw/encoded bytes to check omissions across archive members. Complete-export cases verify evidence retention. Storage-migration cases cover real repository/session restoration with synthetic data, SQLite sidecars, repeat resolution, conflicts and filesystem failure. Stale-writer checks flush the first writer before asserting that the second writer reconciles against its committed event sequence; independent queues do not establish cross-store submission order. Coordinator interleaving tests wait for the pending command or persistence state before injecting Stop or background expiration. A bounded monotonic deadline fails missing preconditions without assuming a fixed runner speed; simulator timing does not change production command deadlines.

The catalog validator checks keys, duplicate JSON keys, plural variants, argument contracts, helper references and optional compiler-extracted keys. `scripts/check-contracts` compares SwiftPM vectors and native brand copies with their canonical files and checks font hashes/OFL notices.

`./apple/scripts/check-privacy` checks the five app/package privacy manifests against audited API usage and resource declarations. After Debug and Release builds, run `./apple/scripts/check-privacy --built-products build/apple/DerivedData/Build/Products` to verify the copied manifests in each app, embedded Watch app and linked FitnessKit resource bundle. This source-token check does not replace data-flow review or App Store validation.

## Result storage

Commands write full logs under ignored `build/apple/logs/` and per-run structured `.xcresult` bundles under `build/apple/Results/`. Record the exact commands, environment, suite counts, failures, skips and limits with the result or change description. Keep private source snapshots and historical reports under ignored `.local/`; they are not build dependencies or public architecture documentation.

Changes to concurrency, persistence, identities or movement boundaries require their affected suites. Documentation changes require link, example, distribution and consistency checks; do not relabel an earlier test run as new validation. A documentation-link check cannot establish every claim in prose, so review behavioral claims against source and executable coverage.

A build, unit/UI test or simulator capture does not establish physical belt motion, calibrated speed, sensor accuracy, real-device background continuity or a successful physical Watch/HealthKit session. [Hardware evidence](hardware.md) defines those observations.
