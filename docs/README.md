# Documentation

These guides describe the system as it works now. Each topic has one maintained explanation, updated in place when its behavior changes. Architecture includes the rationale for current boundaries; documentation does not use ADRs, numbered decision logs or delivery reports.

## Use and develop

- [Product scope](../PRODUCT.md): features, limitations and distribution conditions.
- [Using the app](guides/using-the-app.md): connection, Watch preparation, workouts and exports.
- [Architecture](architecture.md): components, data flow, constraints and rationale.
- [Apple development](development/apple.md): toolchain, generation, builds and tests.
- [Local configuration](development/local-configuration.md): optional signing and private working files.

## Verify and interpret

- [Software checks](testing/software.md): commands, coverage and result interpretation.
- [Hardware evidence](testing/hardware.md): supervised observations and evidence boundaries.
- [Platform scope](compatibility/platforms.md) and [device compatibility](compatibility/devices.md).
- [Shared protocols, contracts and vectors](../shared/README.md): wire formats and export semantics.
- [Release checklist](releasing.md): source distribution and release verification.

## Design, privacy and contribution

- [Design system](../design/DESIGN.md) and the [interactive prototype](../design/prototype/index.html).
- [Privacy](../PRIVACY.md), [diagnostic sharing](privacy/sharing-diagnostics.md) and [security reporting](../SECURITY.md).
- [Contribution guide](../CONTRIBUTING.md) and [third-party notices](../THIRD_PARTY_NOTICES.md).

## Writing and evidence

Public documentation, design-reference prose and code comments use English and present tense. Instructions use direct imperatives. Product and Watch interface resources remain Spanish/English; localization keys, quoted labels, third-party licenses and raw evidence keep their original values.

Describe behavior, constraints, rationale, code location and verification where useful. Link to the source of a shared rule instead of repeating it across guides. Planned work belongs in task tracking, not in descriptions of implemented behavior.

Dated results and historical documents remain private under ignored `.local/`; executable checks produce logs and structured results under ignored `build/`. Preserve their original bytes, timestamp and environment. A past passing count does not establish the result of the current checkout. Source changes and their rationale belong in the relevant guide and change description; they do not create a new delivery document.
