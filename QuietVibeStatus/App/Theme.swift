import SwiftUI

/// Quiet Apps design tokens, translated from `.claude/skills/quiet-apps-design/colors_and_type.css`.
/// The token names are the contract — keep these in sync with the CSS rather than inventing values.
enum Theme {
    // MARK: Brand

    static let blue = Color(hex: 0x1E88E5)
    static let blue600 = Color(hex: 0x1565C0)
    static let blue400 = Color(hex: 0x4FA3EA)
    static let accentTeal = Color(hex: 0x80CBC4)

    // MARK: Dark surfaces (the notch panel is always dark)

    static let dark1 = Color(hex: 0x0B0D11)
    static let dark2 = Color(hex: 0x16191F)
    static let dark3 = Color(hex: 0x20242C)
    static let darkLine = Color(hex: 0x2A2F38)
    static let onDark = Color(hex: 0xF2F3F5)
    static let onDark2 = Color(hex: 0xB8BDC6)
    static let onDark3 = Color(hex: 0x6C737E)

    // MARK: Semantic

    static let success = Color(hex: 0x1F9D6B)
    static let warning = Color(hex: 0xC98A12)
    static let danger = Color(hex: 0xC8392F)
    /// Approval and question cards share one attention color.
    static let attention = Color(hex: 0xE08A2B)

    // MARK: Radii

    static let rSm: CGFloat = 6
    static let rMd: CGFloat = 10
    static let rLg: CGFloat = 14
    static let rXl: CGFloat = 20

    // MARK: Spacing

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    // MARK: Motion — calm by default

    static let ease = SwiftUI.Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let easeSlow = SwiftUI.Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)

    /// The notch opening and closing. A spring rather than a curve: the panel is physically
    /// growing out of the notch, and a little settle at the end sells that far better than a
    /// timing curve, without any overshoot wobble.
    static let morph = SwiftUI.Animation.spring(response: 0.38, dampingFraction: 0.9)
    /// Content crossfade inside the morph — quicker, so text is legible before the growth ends.
    static let morphFade = SwiftUI.Animation.easeOut(duration: 0.2)

    // MARK: Type

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
