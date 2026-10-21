# Diagnostic data and sharing

The apps store workout and diagnostic records locally on the device. VaganciaFitness and VaganciaFitnessDebug are separate apps and keep separate app data. The product's Watch companion may process workout and health data through HealthKit and WatchConnectivity according to the permissions and actions chosen on the device.

Creating a diagnostic export is an explicit user action. The app does not automatically upload diagnostic files or send them to a project server. The operator chooses whether and where to share an exported file through the system share sheet. Exports can contain detailed protocol bytes, timestamps, device context, notes, and Watch messages; inspect a file before sharing it publicly. A personal workout share card is also created locally and shared only when the user chooses to share it.

The source provides an explicit public-support ZIP option alongside complete export. It omits payloads, free text, notes, HealthKit data, workout details and raw Watch messages across all archive members. Events retain sequence, relative times, known kinds and source; IDs are local to the archive. Only known standard GATT UUIDs and strictly formatted app version/build values are retained. Omission counts and Watch snapshot coverage are explicit. Unknown proprietary UUIDs are omitted as well.

The public profile deliberately provides limited metadata. Keep the complete export privately when investigating protocol bytes or metric values. [Software checks](../testing/software.md) describe sentinel coverage; each run's results retain their date and environment outside the maintained guides. A public-support ZIP is not a general anonymization guarantee for every input or permission to publish private original captures.
