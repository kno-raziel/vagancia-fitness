# Hardware evidence

Record physical observations separately from user reports, synthetic data, and software results. A useful observation records the app and version, device and treadmill context at a privacy-safe level, operator action, timestamps, original protocol bytes, replies, received telemetry, errors, and what was physically observed.

An advertised GATT service or capability is a device declaration. A control-point response is a protocol response. A successful BLE write means the transport accepted a write. None alone proves belt movement or calibration. Received speed and distance are observations reported by the treadmill, not independent measurements.

Any motor test requires explicit operator authorization and a safe, supervised setup. Do not automatically repeat movement after timeout or reconnect. Bluetooth stop is not an emergency stop; connection loss does not establish that movement ceased. Software checks do not replace physical testing.
