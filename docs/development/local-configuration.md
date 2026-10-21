# Local configuration

`apple/Config/Local.xcconfig` is ignored and may contain a developer's local signing team or other machine-specific values. Recreate it from `apple/Config/Local.xcconfig.example` when needed, then set only values required by the local Apple development environment. Keep certificates, provisioning profiles, credentials, device identifiers, and personal account data out of tracked files.

The ignored file is optional for simulator work that does not require code signing. For physical-device signing, select a valid development team in Xcode or configure a local team value. This is a local setup step; it does not alter bundle identifiers or app data paths by itself.

## Private references and public files

Keep private screenshots, mask policies, original filename mappings, diagnostics and local build evidence under ignored `.local/`. They are optional working material; a fresh checkout does not need them. FitShow references remain private even when redacted. Only the policy README under `docs/references/fitshow/` is public. Deliberately generated native-app screenshots with synthetic data may appear in the product documentation after visual review; they are distinct from private hardware captures and third-party references.

`scripts/_repository.py` defines the approved public roots and exclusions and generates `.gitignore`. Run `python3 scripts/_repository.py --write-gitignore` after changing that policy. `scripts/check-public-files` rejects drift between the generated Git exclusions and the public inventory. Root entries outside the approved set are ignored by default and reported for classification. `.impeccable/design.json` is public; other `.impeccable` metadata remains local. No Git repository is needed to generate or verify these files.
