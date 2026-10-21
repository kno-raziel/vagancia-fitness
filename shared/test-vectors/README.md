# Public protocol vectors

Canonical files live here. SwiftPM needs resources inside its package, so selected files have byte-identical test-resource copies listed in [manifest.json](manifest.json). Run `./scripts/check-contracts` to detect drift. Change the canonical file and its declared copy together; do not maintain different expected behavior per platform.

- FTMS replay: sanitized derivative of historical hardware evidence; fictional identifiers and shifted times, preserving packet order and relative intervals.
- FitShow frames: synthetic inputs with expected fields or an invalid-frame outcome.

Private originals are optional and never required. A successful test does not verify treadmill motion. Future Android tests must consume the same vector behavior; Android implementation/CI is not present yet.
