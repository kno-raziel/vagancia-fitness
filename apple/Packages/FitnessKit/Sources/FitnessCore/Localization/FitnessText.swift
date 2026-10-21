import Foundation

/// Presentation strings shared by the iPhone and Watch apps. Keys and persisted
/// model values are stable; only the returned text depends on the app language.
public enum FitnessText {
    public static func string(_ key: String, locale: Locale? = nil) -> String {
        let bundle: Bundle
        if let locale {
            let language = locale.language.languageCode?.identifier ?? "es"
            let supported = language == "en" ? "en" : "es"
            bundle =
                Bundle.module.path(forResource: supported, ofType: "lproj")
                .flatMap(Bundle.init(path:)) ?? .module
        } else {
            bundle = .module
        }
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    public static func format(_ key: String, locale: Locale? = nil, _ arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), locale: locale ?? .current, arguments: arguments)
    }

    public static func number(
        _ value: Double, locale: Locale = .current, maximumFractionDigits: Int = 1
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = max(0, maximumFractionDigits)
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func intervalCount(_ count: Int, locale: Locale? = nil) -> String {
        format("count.interval", locale: locale, count)
    }

    public static func date(
        _ value: Date, locale: Locale = .current,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .short
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: value)
    }

    /// Maps known legacy, persisted Watch messages for display. Unknown text,
    /// including device errors, passes through unchanged with its provenance.
    public static func watchPreparationMessage(_ raw: String, locale: Locale? = nil) -> String {
        switch raw {
        case "Preparación cancelada; no se guardó entrenamiento.":
            string("watch.preparation.cancelled", locale: locale)
        case "Preparación anterior descartada por el operador; no hubo captura.":
            string("watch.preparation.discarded", locale: locale)
        case "Ejemplo de preparación anterior en el Watch; no hay captura activa.":
            string("watch.preparation.examplePrevious", locale: locale)
        case "Ejemplo sintético: preparación anterior sin captura.":
            string("watch.preparation.exampleSynthetic", locale: locale)
        case "Ejemplo sintético: preparación resuelta sin captura.":
            string("watch.preparation.exampleResolved", locale: locale)
        default: raw
        }
    }
}

extension WorkoutPhase {
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("phase.\(rawValue)", locale: locale)
    }
}

extension WorkoutState {
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("state.\(rawValue)", locale: locale)
    }
}

extension MetricSource {
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("source.\(rawValue)", locale: locale)
    }
}

extension WorkoutDeviationMetric {
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("metric.\(rawValue)", locale: locale)
    }
}

extension WorkoutProgram {
    /// Seed names are stored as originally created; presentation follows the ID
    /// so previously saved seeds remain byte-for-byte compatible.
    public func localizedSeedName(locale: Locale? = nil) -> String {
        switch (id, name) {
        case ("essential", "Intervalos esenciales"):
            FitnessText.string("seed.essential", locale: locale)
        case ("steady", "A tu ritmo"): FitnessText.string("seed.steady", locale: locale)
        case (let id, "Entrenamiento libre") where id.hasPrefix("free-"):
            FitnessText.string("seed.free", locale: locale)
        default: name
        }
    }
}
