# Design system

VAGANCIA FITNESS uses the VP Black Paper palette, a red action accent, ivory text, and native SwiftUI controls. Product screens keep planned goals, effective settings, and received measurements distinct. Each metric retains its unit, source, and freshness. Synthetic values and simulator captures are labeled as such.

VaganciaFitness and VaganciaFitnessDebug remain separate iOS apps with FitnessKit shared locally. The Watch companion supports workout capture and HealthKit presentation; motor controls remain on iPhone. Android has no implementation yet.

## Typography and assets

The app bundles Asimovian, Inter, and Lekton font files with their SIL Open Font License 1.1 texts. The font manifest records file hashes and WOFF-to-TTF conversion details, but not upstream release identifiers. See [third-party notices](../THIRD_PARTY_NOTICES.md).

The product uses the v8 mark, wordmark and app icon. The maintainer authorizes their inclusion and distribution with source and builds, with trademark rights reserved; see the [brand notice](../shared/brand/NOTICE.md). FitShow reference screenshots remain private and are not distributed. Keep any public design captures synthetic or reviewed for privacy; no local build or simulator capture proves physical treadmill behavior.

## Design values

- Black and graphite surfaces, ivory text, and red for key actions.
- Native, accessible controls and adaptive text sizing.
- Visible unit and provenance for each metric.
- Clear distinction between product, diagnostics, and Watch responsibilities.

## Current implementation references

`FitnessBrandHeader` in `apple/Apps/VaganciaFitness/App/FitnessBrand.swift` combines a 34 pt mark, an 88 × 30 pt wordmark and an 8 pt gap. Native controls, semantic styles and adaptive layout preserve the system interaction model. `.impeccable/design.json` describes current design rules and components; it does not publish screenshots, historical test verdicts or release reports.

The HTML prototype is a separate interactive demonstration, not a renderer for native controls or proof of runtime behavior. Design changes describe the current source behavior here and preserve dated captures/results in private evidence. Accessibility claims require their corresponding software and device checks.
