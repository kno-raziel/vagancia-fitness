# Diagnostic export contract

## Complete evidence

Base `schemaVersion` is `1.0`. The full diagnostic contains `manifest.json`, `device.json`, `results.json`, `events.jsonl` and `summary.txt`. It retains original bytes, event order, sources, notes, timestamps, errors and operation references. The manual share action may disclose personal or health data; do not post full archives to public issues.

Product archives may add `watch-rejected-envelopes.json` and `.jsonl`. These cover all received Watch rejections, including setup and other workouts. Full `rawData` Base64 and `rawHex` are alternate encodings of the same complete bytes. Rejection logs cannot reconstruct events predating their installation.

`manifest.watchDiagnostics.syncStatus` distinguishes `snapshotConfirmed`, `localSnapshot`, `unavailable` and `timedOut`. Only a correlated confirmed snapshot establishes reception of its declared IDs. An empty offline local snapshot is not evidence of no Watch errors. Persist chunks and complete entries before ACK; late/duplicate entries preserve stable identity.

## Public-support profile

`DiagnosticExportProfile.publicSupport` produces a five-file metadata projection. It omits all event payloads, workout bodies, notes, health values, raw Watch entries, device identities and unknown UUIDs. Events retain sequence, relative seconds, an allowed kind or `other`, and source. IDs use `session-1` and `event-<sequence>`. App version/build and known standard GATT UUIDs have strict allowlists. The manifest declares omissions, dropped counts and Watch coverage. `workoutIncluded` is false; `workoutPresentBeforeOmission` describes whether a body was supplied before omission. Complete evidence remains the API default.

Sentinel tests cover archive members, names, encoded raw Watch bytes, notes, HealthKit text and UUIDs. The [software-check guide](../../../docs/testing/software.md) describes coverage and result interpretation. A source feature or simulator result does not establish availability or physical behavior in an installed build.
