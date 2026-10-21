# Using the app

VaganciaFitness handles workouts; VaganciaFitnessDebug handles separate Bluetooth investigations. The Watch companion captures health/workout data for the product. Product and Watch interface labels are localized in Spanish and English; Spanish labels below identify the corresponding screens. [Product scope](../../PRODUCT.md) lists current limits.

## Try a workout without hardware

This walkthrough runs in the iPhone simulator or on an installed development build. It needs no treadmill, Apple Watch or Health authorization.

1. Open the product app and choose Settings (`Ajustes`). Turn on Demonstration mode (`Modo de demostración`). Leave Sample metrics (`Métricas de ejemplo`) on only if you want supplementary simulated values.
2. Return to Home (`Inicio`), choose the free workout and review its preparation screen. Confirm the start explicitly. The demonstration label identifies synthetic treadmill data; no Bluetooth movement command is sent.
3. Open the speed/inclination adjustment sheet and change a target with the bounded controls. Observe the simulated measurements and elapsed time.
4. Use Finish and save (`Finalizar y guardar…`) and confirm the save. Review the summary and its metric sources, then use Return to Activity (`Volver a Actividad`) to inspect the record in History (`Historial`).
5. Open the saved record to explore its summary and sharing actions. Treat exported demonstration values as synthetic evidence.

Demonstration mode and sample metrics are independent settings. Switch off demonstration mode before preparing a real treadmill session. Radio compatibility, physical response, locked-phone continuity and Watch sensors require the separate [hardware process](../testing/hardware.md).

## Connect a treadmill

1. Open Settings (`Ajustes`) → Device connection (`Conexión del equipo`). Start a search and select the treadmill.
2. Check connection state and available capabilities. A visible advertisement does not establish a completed connection, and advertised control support does not confirm physical behavior.
3. Remember the selected device if you want to reuse it. Enable connection on open only when you want the app to attempt that BLE connection. Remembering or reconnecting does not authorize movement.
4. Use the connected device's ranges and increments for targets. Unavailable, stale or unsupported metrics are not zero values.

If connection fails, use the diagnostic export to retain the error and connection context. Do not treat reconnection as permission to repeat a movement command. [Compatibility](../compatibility/devices.md) describes evidence for the reference treadmill.

## Prepare Apple Watch capture

Open Settings → Apple Watch and check pairing with iOS, companion app availability, Health access review, current session state and the age of its report. Complete Health authorization on the device that requests it; the app does not infer read permission from an empty response.

Preparation belongs to the selected workout. If the app reports a conflicting preparation, use the offered resolution flow and check the Watch's current session. Pairing, immediate message reachability, mirrored workout state and confirmed health capture are separate facts. A stale report or a report for another session does not confirm this workout.

The workout flow supports continuing without Watch capture. Missing health metrics remain absent or explicitly simulated when sample metrics are enabled. Watch screens show capture and metric freshness; they do not send treadmill start, speed or stop commands.

## Start and adjust a workout

Choose a free workout or a program. Program editing changes the local routine and its interval targets; it does not start the belt. Review preparation, planned targets and device support before using the explicit start confirmation.

The workout screen separates planned targets, effective settings and received measurements. Manual controls use device limits. Read the source and age of each value; enabling demonstration or sample metrics does not turn synthetic values into physical observations.

Keep the physical stop/emergency control accessible. Use the explicit belt-stop action (`Parar banda`) when requesting a Bluetooth stop, and check the physical machine. Session completion, a stop response, confirmed zero telemetry and a saved Health workout are distinct outcomes. An uncertain stop or lost connection does not establish that the belt is stationary.

The app does not automatically retry movement after timeout or reconnection. Stale or lost target confirmation can suspend automation. Locked-phone telemetry and automatic interval execution depend on system scheduling and device behavior; validate continuity through the supervised process in [hardware evidence](../testing/hardware.md).

## Notes, history and exports

Add notes through the session note action. Completed records appear in Activity (`Actividad`), where the summary distinguishes metric sources and offers sharing/export actions. A share card contains personal workout values and is a separate output from a diagnostic ZIP.

Settings → Export diagnostic ZIP (`Exportar diagnóstico ZIP`) is available when a diagnostic session exists, including sessions without a started workout. The export waits for its persistence barrier before preparing the system share sheet.

- Complete export (`Exportación completa`) preserves original evidence, including notes, raw bytes and applicable Watch diagnostics. Keep it private for investigation.
- Public support (`Soporte público`) projects limited metadata and declares omitted data and Watch coverage. It cannot replace complete evidence or guarantee anonymization for every possible input.

Choose the destination yourself in the system share sheet; exports are not automatically uploaded. [Diagnostic sharing](../privacy/sharing-diagnostics.md) explains the privacy boundaries; [export contracts](../../shared/contracts/diagnostic-export/README.md) define archive contents.

## Use Debug for investigations

Open VaganciaFitnessDebug to create a diagnostic session, inspect GATT services/properties, observe FTMS capabilities and telemetry, add operator notes and export evidence. Its store is independent of the product app. Physical controls let you compare console values with received samples without sending movement commands.

FTMS is the preferred protocol. FitShow channel comparison preserves raw bytes and units; matching UUIDs is not compatibility proof, and proprietary movement remains disabled. The [FitShow contract](../../shared/protocols/fitshow.md) describes the bounded diagnostic path.

## Demonstration and local data

Settings separates treadmill demonstration mode from sample supplementary metrics. Both remain explicitly labeled; enabling them does not start Bluetooth. History deletion is unavailable during an active session and preserves programs, the remembered treadmill and stored limits. Do not delete data to fix an uncertain hardware state; keep the complete export when investigating an issue.
