# Contributing

Thanks for helping improve VAGANCIA FITNESS. The project is maintained by one developer, so changes should be focused and easy to review. There is no promised response time or support service.

Before changing behavior, read [product scope](PRODUCT.md), [architecture](docs/architecture.md), and the relevant guide under `docs/`. Keep protocol parsing independent from SwiftUI and CoreBluetooth. Preserve the separation between VaganciaFitness, VaganciaFitnessDebug, and their shared FitnessKit code.

For a change, describe the user-visible effect, the relevant platform, and the checks you ran. Do not claim a build, test, hardware observation, or physical behavior unless you performed and recorded it. Label synthetic fixtures and user-reported details. Do not include private exports, device backups, local signing settings, or personal identifiers in issues or pull requests.

For documentation, contracts or repository tooling, run `./scripts/check-repository` with Python 3.11 or newer. This path does not require Xcode and includes synthetic regression cases for the repository tools. Native app changes also use the [Apple development checks](docs/development/apple.md). The [hardware-free walkthrough](docs/guides/using-the-app.md#try-a-workout-without-hardware) provides a first product run in the simulator.

Spanish and English are supported by the app. Localization changes should preserve stable meaning across both languages, plural variants, format arguments, and accessibility text. Run `python3 apple/scripts/validate-localizations.py` for catalog changes and report the result.

Swift formatting uses the checked-in `apple/.swift-format` configuration: four spaces, a 120-column target and the tool's enabled rules. From the root, apply it with `xcrun swift format format --configuration apple/.swift-format --recursive --in-place apple/Apps apple/Packages`, then run `./apple/scripts/check-format`. Do not weaken rules or exclude production callbacks to pass a check.

Do not send movement commands to a treadmill without explicit operator authorization for that test. Never retry a movement command automatically after a timeout or reconnection. Bluetooth stop is not an emergency stop.

Use the issue templates for bug or compatibility reports and the pull request template for code changes. Project code contributions use the [MIT License](LICENSE). Keep font OFL notices and project trademark conditions separate, and do not contribute private FitShow screenshots or local diagnostic exports.

The public distribution boundary is defined in `scripts/_repository.py`. When changing root classifications or private-file exclusions, regenerate `.gitignore` with `python3 scripts/_repository.py --write-gitignore` and run `scripts/check-public-files`. Unclassified root files are ignored by default and still reported for review by that check. Only `.impeccable/design.json` is public within `.impeccable/`; other local design metadata is ignored.

Write documentation, design-reference prose and code comments in English. The app interface continues to support Spanish and English. Preserve existing localization source keys, argument contracts, protocol IDs and raw diagnostic evidence; translating documentation must not change these values. Quoted localized UI labels may remain in their original language within an English explanation. Preserve third-party license texts and proper names.

Documentation describes the current system in present tense. Update the affected topic in place with behavior, constraints, rationale and verification links; use [the documentation map](docs/README.md) to find its source. Keep one maintained explanation per topic. Put proposed work in task tracking and change history in the change/release description. Do not add ADRs, delivery notes or dated test reports to public source; preserve original evidence privately. Public policies and contracts remain maintained references, not chronological records.
