# Release checklist

A source release uses the maintained guides and an explicitly verified public inventory. Signing, publication, remote setup and physical-device installation require their own operator authorization.

## Source verification

- Confirm [third-party notices](../THIRD_PARTY_NOTICES.md) match distributed assets: MIT code, OFL fonts, project brand with reserved trademark rights and private FitShow screenshots/manifests excluded.
- Run `./scripts/check` and the affected [software suites](testing/software.md). Preserve the result's source/toolchain context and report only checks actually run.
- Create a fresh source copy with `scripts/check-public-files --copy-to NEW_DIRECTORY_OUTSIDE_SOURCE`. Check that it contains no local configuration, private reference assets, certificates, device backups or personal exports.
- Generate with `apple/scripts/generate-project` and build the three Apple targets from that copy. Behavior changes require the corresponding Core, Runtime, callback and UI checks.
- Review concurrency, writer barriers, stable identity, export contracts and movement restrictions against the implementation.
- Verify es/en resources and permission text. Physical behavior requires a separately authorized hardware session.

## Documentation and distribution

- Update the relevant topic in place: supported behavior, constraints, rationale and verification. Keep plans, delivery notes, ADRs and dated test reports out of the public documentation.
- Preserve historical source notes, run results and raw evidence privately with their dates and environment; do not rewrite them as present-day guarantees.
- Describe release changes in the release/change description. Hosted release notes, Git history and CI artifacts are available only when their infrastructure is configured; local evidence remains under ignored `.local/` and `build/`.
- Keep [SECURITY.md](../SECURITY.md) aligned with the source-only publication and GitHub Issues reporting policy. Do not advertise private reporting, binary downloads or support guarantees that the project does not provide.
- Execute remote workflows only when a remote exists and publication is authorized. Local checks do not establish remote CI status.

[Local configuration](development/local-configuration.md) defines the public/private file boundary. Complete personal diagnostic exports and signing artifacts remain private.
