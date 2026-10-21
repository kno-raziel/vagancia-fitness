# FTMS contract

Fitness Machine Service is `1826`; Treadmill Data is `2ACD`; Feature is `2ACC`; Control Point is `2AD9`; machine status is `2ADA`. Refer to the [Bluetooth specification](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0/) for normative definitions.

The current decoder owns flag-controlled lengths, signed values, little-endian integers and FTMS units. Speed is encoded in 0.01 km/h, total distance in metres and inclination in 0.1 percent. Absent fields are absent, not zero. Truncated or reserved/unsupported forms must not replace the last valid observation.

Capabilities/ranges describe advertised support. GATT presence, accepted writes and protocol responses do not independently verify physical movement. Values must satisfy the current connected device range and increment, not a fixed UI limit.

One controller owns an outstanding procedure. Prepare response indications and a Stop path before movement. Record an explicit operator request durably before writing. A timeout/disconnect is indeterminate, never a reason to retry movement. Connection generation and event identity distinguish observations: a reused speed event cannot count as several confirmations. Target confirmation requires sustained distinct post-acceptance observations; losing it suspends automation.

Distance has two meanings: original machine counter and accumulated session distance. A counter reset must not subtract already recorded distance. Keep the original sample and derived accumulation separate.

The common [hardware-derived replay](../test-vectors/ftms/yk-motion-replay.json) has fictional IDs and shifted timestamps, with packet bytes and relative timing preserved. It tests interpretation, not calibration, sensors or present-day hardware behavior.
