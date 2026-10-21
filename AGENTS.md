# Repository guidance

## Product and platform boundaries

- This is a solo-maintained project. Do not assume an external team or support staff.
- Keep two native iOS apps: VaganciaFitness for workouts and VaganciaFitnessDebug for Bluetooth diagnosis. Both use the local FitnessKit package.
- Android is a future native implementation. It has no app, runtime, build, or CI support yet. Keep shared protocol contracts independent from Apple frameworks.
- Watch, HealthKit, routines, backend services, and proprietary treadmill control require explicit product scope. Preserve the current implementation and its platform boundaries.
- Prefer FTMS. Add a vendor-specific FitShow path only where evidence identifies it and the feature needs it.

## Evidence and device interaction

- Label user-reported information, synthetic fixtures, software observations, and observations from physical hardware distinctly.
- A GATT service, advertised capability, successful BLE write, or protocol response does not prove physical treadmill behavior.
- Send movement commands only after an explicit operator action authorizes the test or goal.
- Never retry a movement command automatically after timeout or reconnection.
- Do not infer that Bluetooth loss stops the treadmill. Bluetooth stop is not an emergency stop.
- Do not brute-force vendor commands, write unknown descriptors, or use OAD/DFU for active testing.
- Subscribe to known characteristics through CoreBluetooth; subscriptions are not motor commands.
- Preserve original bytes, context, responses, errors, and conclusions with their evidence.

## Living documentation and comment language

- Write public documentation, design-reference prose and code comments in English. Describe the current system in present tense and update its topic in place.
- Keep one maintained explanation per topic, including rationale where useful. Do not create ADRs, numbered decision logs, delivery reports or dated verification narratives in public source. Preserve originals and evidence under ignored .local/ or build/; do not turn historical results into current guarantees.
- Preserve Spanish/English user interface resources, existing localization keys and argument contracts. Do not translate protocol identifiers, raw evidence or operator notes as documentation cleanup.
- Quoted UI labels may retain their original language when the surrounding explanation is in English. Preserve third-party license texts and proper names. Keep private historical captures and backups unchanged.

## Implementation and validation

- Keep protocol code independent from SwiftUI and CoreBluetooth so captured inputs can verify it.
- Preserve the production callback factories and their off-main invocation coverage, including the VaganciaFitnessWatchCallbackTests target. The five Spanish/English String Catalogs span iPhone, Watch, and FitnessKit. The localization validator checks keys, plural variants, argument contracts, duplicate JSON keys, and optionally compiler-extracted keys.
- Preserve durable-write ordering, FIFO event capture, export barriers, acknowledgements, and stable-identity deduplication.
- Run checks appropriate to the change. Documentation changes should check local links, examples, and consistency. Report only checks actually run; do not turn prior release results into new validation.
- Do not initialize Git, create commits or remotes, publish, install to devices, or perform physical treadmill tests unless explicitly requested.
