import Foundation

extension FitnessText {
    /// Presentation of known Spanish control messages saved in prior sessions.
    /// Unknown reasons and error details remain exactly as received.
    public static func controlMessage(_ raw: String, locale: Locale? = nil) -> String {
        let known: [String: String] = [
            "Prepara el canal de control. No se enviará movimiento.": "control.prepare",
            "La prueba necesita una acción explícita del operador.": "control.authorization",
            "Primero prepara las indicaciones FTMS.": "control.indications",
            "Hay una respuesta pendiente o incierta. Desconecta y prepara una conexión nueva.":
                "control.pending",
            "La parada Bluetooth no está preparada. Usa la consola física.": "control.stopUnavailable",
            "La parada anterior quedó incierta. Usa la consola física; reconecta antes de otra prueba Bluetooth.":
                "control.stopUncertain",
            "La parada ya está pendiente; no se reenvía automáticamente.": "control.stopPending",
            "La máquina todavía no concedió control FTMS.": "control.permission",
            "Prueba primero Parar y espera una velocidad reciente de 0 km/h.": "control.zeroFirst",
            "Espera velocidad reciente en movimiento antes de cambiar el objetivo.":
                "control.speedRecent",
            "Objetivo fuera del rango de velocidad anunciado o rango no disponible.":
                "control.speedRange",
            "El objetivo debe respetar el incremento anunciado; no se redondea silenciosamente.":
                "control.increment",
            "Espera velocidad reciente en movimiento antes de cambiar la inclinación.":
                "control.inclineRecent",
            "Objetivo fuera del rango de inclinación anunciado o rango no disponible.":
                "control.inclineRange",
            "Respuesta FTMS malformada; resultado incierto.": "control.malformed",
            "Respuesta FTMS inválida. Se conservaron sus bytes.": "control.invalidResponse",
            "La máquina retiró el permiso de control.": "control.permissionLost",
            "La conexión se interrumpió con un procedimiento pendiente.": "control.interrupted",
            "Control desconectado. Los resultados anteriores son históricos.": "control.disconnected",
            "Desactiva el modo de demostración para buscar Bluetooth.": "control.disableMockScan",
            "Ya se está preparando una sesión.": "control.selectionPreparing",
            "Ya hay una sesión preparada.": "control.selectionPrepared",
            "Ya hay un procedimiento en curso.": "control.procedureBusy",
            "Conecta la caminadora y prepara FTMS antes de iniciar.": "control.connectFirst",
            "El equipo conectado no anuncia control y rango de velocidad FTMS; no se iniciará el entrenamiento.":
                "control.capabilityUnavailable",
            "No hay un entrenamiento activo para pausar.": "control.noActivePause",
            "El entrenamiento no está pausado.": "control.notPaused",
            "No hay un segmento automático activo para saltar.": "control.noSegment",
            "El objetivo manual requiere un entrenamiento en marcha.": "control.manualRequiresRunning",
            "La velocidad está fuera del rango permitido.": "control.speedOutOfRange",
            "La inclinación está fuera del rango permitido.": "control.inclineOutOfRange",
            "La inclinación no está disponible en esta sesión; la velocidad continúa.":
                "control.inclineUnavailable",
            "No hay un registro abierto para guardar.": "control.noOpenRecord",
            "No hay un entrenamiento abierto para finalizar.": "control.noOpenFinish",
            "El canal FTMS perdió permiso o quedó incierto; no se envían objetivos automáticos.":
                "control.automaticSuspended",
            "Stop Bluetooth no está listo. Usa la consola física.": "control.stopNotReady",
            "Se perdió la conexión o el permiso FTMS mientras se verificaba la velocidad.":
                "control.lostDuringSpeed",
            "No se observó velocidad FTMS fresca de 0 km/h después de Stop.": "control.noZeroAfterStop",
            "No se observó velocidad FTMS positiva y fresca después de Start.":
                "control.noSpeedAfterStart",
            "La orden fue interrumpida por una acción prioritaria del operador.":
                "control.operatorPriority",
            "Se perdió el control FTMS al verificar el objetivo de velocidad.":
                "control.lostTargetObservation",
        ]
        if let key = known[raw] { return string(key, locale: locale) }

        let writePrefix = "Escritura fallida: "
        if raw.hasPrefix(writePrefix) {
            return format("control.writeFailed", locale: locale, String(raw.dropFirst(writePrefix.count)))
        }
        let samplesPrefix = "Falló el guardado de muestras FTMS: "
        if raw.hasPrefix(samplesPrefix) {
            return format(
                "control.samplesSaveFailed", locale: locale, String(raw.dropFirst(samplesPrefix.count)))
        }
        let lateWritePrefix =
            "La escritura BLE informó un error después de recibirse la respuesta FTMS: "
        let lateWriteSuffix = ". Se conserva la respuesta del protocolo."
        if raw.hasPrefix(lateWritePrefix), raw.hasSuffix(lateWriteSuffix) {
            let detail = String(raw.dropFirst(lateWritePrefix.count).dropLast(lateWriteSuffix.count))
            return format("control.lateWriteError", locale: locale, detail)
        }

        let failSuffix = " No se reenvía; usa los controles físicos y reconecta para continuar."
        if raw.hasSuffix(failSuffix) {
            let reason = String(raw.dropLast(failSuffix.count))
            return controlMessage(reason, locale: locale) + string("control.failSuffix", locale: locale)
        }

        let actions: [(String, String)] = [
            ("Solicitar control", "requestControl"), ("Iniciar banda", "start"),
            ("Parar banda", "stop"), ("Cambiar velocidad", "speed"),
            ("Cambiar inclinación", "inclination"),
        ]
        for (spanish, code) in actions where raw.hasPrefix(spanish + ": ") {
            let action = string("ftms.action.\(code)", locale: locale)
            let tail = String(raw.dropFirst(spanish.count + 2))
            if tail == "esperando respuesta del procedimiento." {
                return format("control.waiting", locale: locale, action)
            }
            if tail == "aceptado por FTMS; comprueba la respuesta de la banda." {
                return format("control.accepted", locale: locale, action)
            }
            let prefix = "rechazado (código "
            let suffix = "). No se reintenta."
            if tail.hasPrefix(prefix), tail.hasSuffix(suffix) {
                let code = String(tail.dropFirst(prefix.count).dropLast(suffix.count))
                return format("control.rejected", locale: locale, action, code)
            }
        }
        return raw
    }
}
