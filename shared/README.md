# Platform-independent material

This directory contains wire specifications, versioned export contracts, public test vectors and brand provenance. It is not a cross-platform runtime. Apple code remains Swift; Android is planned as a native client.

- [Protocols](protocols/ftms.md): bytes, units and evidence boundaries.
- [Diagnostic export](contracts/diagnostic-export/README.md): full and public-support outputs.
- [Workout export](contracts/workout-export/README.md): versioned workout evidence.
- [Test vectors](test-vectors/README.md): common inputs and expected results.

Machine keys, opcodes, units and identifiers do not change with the UI language. Apple String Catalogs remain in Apple bundles; Android localization requires its own platform implementation.
