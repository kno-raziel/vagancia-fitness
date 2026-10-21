# Regression fixtures

These fixtures derive from historical hardware observations. Public copies use fictional stable identifiers, shifted timestamps and generic program/status text. Protocol bytes, ordering, state transitions and relative timing needed by the regressions are retained. They are not new measurements or proof of current physical behavior. Private originals are optional and are never a build or test dependency.

`WatchLedger081.json` retains the dictionary shape required by its decoder, so provenance is documented here rather than inserted as a session. Other JSON fixtures include an additive `sanitization` field. Public fixtures are paired with the regression tests that consume them.

Ledger wall-clock values from the observation and monotonic values are each shifted by a common offset. Static program epoch defaults are normalized separately; their absolute gap to the observed session is not a preserved property. Timing within the actual observed lifecycle remains intact.
