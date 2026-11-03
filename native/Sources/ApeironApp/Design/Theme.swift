import AppKit
import SwiftUI

// MARK: - Colour tokens
//
// A warm, paper-like palette in light mode and a soft graphite in dark mode.
// Every colour is a dynamic NSColor so views never branch on colour scheme.

extension Color {
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

enum Palette {
    static let canvas = Color(light: 0xFAF8F4, dark: 0x1B1A18)
    static let sidebar = Color(light: 0xF1EEE7, dark: 0x151413)
    static let surface = Color(light: 0xFFFFFF, dark: 0x252321)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x2C2A27)
    static let surfaceSunken = Color(light: 0xF4F1EB, dark: 0x201F1D)
    static let userBubble = Color(light: 0xEFEBE2, dark: 0x2E2C29)
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.045)
    static let selection = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.07)
    static let border = Color(light: 0xE5E0D6, dark: 0x3A3733)
    static let borderStrong = Color(light: 0xD3CDC0, dark: 0x4A4641)
    static let textPrimary = Color(light: 0x22201C, dark: 0xECE9E3)
    static let textSecondary = Color(light: 0x6A665E, dark: 0xA6A29A)
    static let textTertiary = Color(light: 0x9B968B, dark: 0x77736C)
    static let code = Color(light: 0xF3F0EA, dark: 0x1F1E1C)
    static let success = Color(light: 0x2F8A5B, dark: 0x5CC18B)
    static let warning = Color(light: 0xB7791F, dark: 0xE0A84B)
    static let danger = Color(light: 0xC0442E, dark: 0xEB7A62)
    static let diffAdded = Color(light: 0x2F8A5B, dark: 0x5CC18B, alpha: 0.13)
    static let diffRemoved = Color(light: 0xC0442E, dark: 0xEB7A62, alpha: 0.13)
    static let shadow = Color(light: 0x3A2E1E, dark: 0x000000, alpha: 0.10)
}

/// User-selectable accent colours.
enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case ember, indigo, sage, ocean, plum, graphite

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .ember: return Color(light: 0xC8613A, dark: 0xE07B52)
        case .indigo: return Color(light: 0x5458C9, dark: 0x8A8DF0)
        case .sage: return Color(light: 0x4E7D5B, dark: 0x7DB48A)
        case .ocean: return Color(light: 0x23739B, dark: 0x5AAED6)
        case .plum: return Color(light: 0x8A4A86, dark: 0xC487C0)
        case .graphite: return Color(light: 0x3B3935, dark: 0xD8D4CC)
        }
    }

    /// Text/icon colour that sits on top of the accent.
    var onAccent: Color {
        self == .graphite ? Color(light: 0xFFFFFF, dark: 0x1B1A18) : .white
    }
}

enum ReadingFont: String, Codable, CaseIterable, Identifiable {
    case serif, sans, rounded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Rounded"
        }
    }
    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        }
    }
}

// MARK: - Theme environment

struct Theme {
    var accent: AccentChoice = .ember
    var readingFont: ReadingFont = .serif
    var textScale: CGFloat = 1

    var accentColor: Color { accent.color }

    func body(_ size: CGFloat = 15) -> Font {
        .system(size: size * textScale, weight: .regular, design: readingFont.design)
    }

    func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight)
    }

    func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight, design: .monospaced)
    }

    func display(_ size: CGFloat = 30) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Metrics

enum Metrics {
    static let transcriptWidth: CGFloat = 760
    static let cornerSmall: CGFloat = 8
    static let corner: CGFloat = 12
    static let cornerLarge: CGFloat = 20
    static let composerCorner: CGFloat = 22
}

// MARK: - Motion

enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.9)
    static let fade = Animation.easeInOut(duration: 0.18)
}
