# Workout evidence contract

Workout payload schema `2` is additive to the diagnostic archive base schema `1.0`; Companion message schema is independently versioned (`1`). Do not infer one version from another.

A workout contains its stable record, metric samples and events. Each metric retains physical unit, source, original sample time and receive time where available. FTMS measurements, cumulative distance, HealthKit values and synthetic data remain distinguishable. Missing metrics are absent; targets are not observations.

Sample identity is stable across retries and persistence. An identical replay does not create another sample; a conflicting value under the same identity is rejected. ACK follows durable persistence. End of local workout, physical stop and HealthKit save are separate outcomes. An uncertain HealthKit save is reconciled by its stable identity rather than saved again.

Machine-readable codes and JSON keys are language-independent. Historical device/system text and operator notes are originals, not translated UI. A public-support export may deliberately omit these values and must declare that restriction.

The PNG share card is a separate local rendering of saved evidence. It is not a diagnostic archive or proof of physical stop. Public documentation cards use synthetic data or explicit redaction; an operator may choose to share their personal card.
