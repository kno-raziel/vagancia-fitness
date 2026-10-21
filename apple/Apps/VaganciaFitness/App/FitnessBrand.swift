import SwiftUI

// VAGANCIA FITNESS: VP Black Paper, approved v8 symbol and reduced wordmark.
// Native navigation, data sources, control actions and storage remain independent.
enum FitnessPalette {
    static let canvas = Color(hex: 0x080808)
    static let paper = Color(hex: 0x141416)
    static let surface = Color(hex: 0x242428)
    static let red = Color(hex: 0xF02D2A)
    static let accent = Color(hex: 0xFF6247)
    static let text = Color(hex: 0xE6E3DF)
    static let secondary = Color(hex: 0xB1AFB5)
    static let border = Color(hex: 0x424248)
}

enum FitnessType {
    static func title(_ size: CGFloat = 32, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("Asimovian-Regular", size: size, relativeTo: style)
    }
    static func body(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline, .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        default: size = 11
        }
        let family =
            weight == .bold
            ? "Inter-Bold" : weight == .semibold || weight == .medium ? "Inter-SemiBold" : "Inter-Regular"
        return .custom(family, size: size, relativeTo: style)
    }
    static let metadata = Font.custom("Lekton-Regular", size: 13, relativeTo: .caption)
}

struct FitnessBrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("FitnessMark").resizable().scaledToFit().frame(width: 34, height: 34)
            Image("FitnessWordmark").resizable().scaledToFit().frame(width: 88, height: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VAGANCIA FITNESS")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home-brand")
    }
}

private struct FitnessSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(FitnessPalette.canvas)
            .toolbarBackground(FitnessPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    func fitnessSurface() -> some View { modifier(FitnessSurface()) }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255)
    }
}
