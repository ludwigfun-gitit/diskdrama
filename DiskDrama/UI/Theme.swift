import SwiftUI
import AppKit

/// DiskDrama's design tokens.
///
/// ## Provenance — read before editing
///
/// The surface, text, and accent tokens below are a **deliberate copy** of
/// `Repos/Visuals/Visuals/UI/Theme.swift` in Ideaverse, trimmed to what
/// DiskDrama uses. Visuals is canonical; DiskDrama is a consumer. If Visuals'
/// theme changes, these values must be updated by hand — nothing enforces it.
///
/// This is a documented pragmatic call, not an oversight (preflight §Theme
/// reuse): extracting a real shared Swift Package would mean touching Visuals'
/// build, which is a live shipping product, to deduplicate two files. The
/// trigger to do it properly is a *third* app needing these tokens, not this one.
///
/// DiskDrama adds exactly three things Visuals has no need for, all from the
/// Claude Design handoff:
///
/// - `danger` — destructive-only. Permitted in exactly two places in the whole
///   app: delete confirmations and the low-space alert. Nowhere else.
/// - `tier1/2/3` — one flat violet at three opacities, *not* three colors and
///   *not* a gradient. Safe is faintest, Review is most saturated.
/// - `brandGradient` — decorative only. Wordmark and badges. Never on a
///   functional control.
///
/// Appearance resolves automatically through dynamic `NSColor` providers, so no
/// call site branches on light/dark. Per the handoff, DiskDrama follows the
/// system appearance and offers no in-app theme switch.
enum Theme {

    // MARK: - Surfaces (mirrors Visuals)

    static let chrome  = dyn(dark: 0x1B1C20, light: 0xE9E9EC)
    static let panel   = dyn(dark: 0x212329, light: 0xE3E3E7)
    static let content = dyn(dark: 0x0F1013, light: 0xFBFBFC)
    static let rail    = dyn(dark: 0x191A1F, light: 0xE6E6EA)

    // MARK: - Text (mirrors Visuals)

    static let text  = dyn(dark: 0xE9EAEF, light: 0x1D1E22)
    static let text2 = dyn(dark: 0x9C9EA8, light: 0x62646C)
    static let text3 = dyn(dark: 0x6A6C75, light: 0x9A9CA4)

    // MARK: - Accents (mirrors Visuals)

    static let accent      = dyn(dark: 0x3F87F5, light: 0x2F7BF6)
    static let accentPress = dyn(dark: 0x2E6FE0, light: 0x1E63D6)

    /// Live-status cyan — freshness dot, confidence indicator, waiting-for-
    /// permission pulse, explanation-source label.
    ///
    /// `#0CECFD` on dark, darkened to `#056B73` on light.
    ///
    /// The light variant is the same colour, not a different one: identical hue
    /// (184.2°) and saturation, value dropped until it is legible. It has to be
    /// darkened because this token is not only dots — the confidence label and
    /// the explanation-source label are *text*, and they sit on `panel`, which
    /// is `#E3E3E7` in light mode. `#0CECFD` on that measures 1.12:1, which is
    /// not low contrast so much as invisible.
    ///
    /// `#056B73` measures 4.89:1 there and 6.05:1 on `content`, so it clears AA
    /// on both surfaces the token appears against. Worth noting the old light
    /// value (`#0EA59D`) was 2.63:1 on panel and had never cleared it.
    ///
    /// Still ~33° of hue from `accent` (184° vs 217°), which is what keeps a
    /// status signal from reading as a button.
    static let glow = dyn(dark: 0x0CECFD, light: 0x056B73)

    // MARK: - Lines, selection, hover (mirrors Visuals)

    static let hairline      = dyn(dark: 0xFFFFFF, light: 0x000000, darkA: 0.075, lightA: 0.09)
    static let hairline2     = dyn(dark: 0xFFFFFF, light: 0x000000, darkA: 0.05,  lightA: 0.06)
    static let selectionFill = dyn(dark: 0x3F87F5, light: 0x2F7BF6, darkA: 0.22,  lightA: 0.14)
    static let hover         = dyn(dark: 0xFFFFFF, light: 0x000000, darkA: 0.05,  lightA: 0.04)
    static let track         = dyn(dark: 0xFFFFFF, light: 0x000000, darkA: 0.08,  lightA: 0.07)

    // MARK: - DiskDrama additions

    /// Destructive. Same value in both appearances, intentionally.
    /// Permitted **only** in delete confirmations and the low-space alert.
    static let danger = Color(hex: 0xC6324E)

    /// Tier intensity: one hue, three opacities. Safe → Review, faint → saturated.
    static func tierFill(_ level: Int) -> Color {
        let opacities: [Double] = NSApp.effectiveAppearanceIsDark
            ? [0.07, 0.14, 0.24]
            : [0.05, 0.11, 0.19]
        let hex = NSApp.effectiveAppearanceIsDark ? 0x8B9AFA : 0x3F5CDD
        let index = min(max(level - 1, 0), 2)
        return Color(hex: hex, alpha: opacities[index])
    }

    /// Decorative only — wordmark, badges. Never a functional control.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: NSApp.effectiveAppearanceIsDark
                ? [Color(hex: 0x2E6FE0), Color(hex: 0x5B3FCC)]
                : [Color(hex: 0x1D5FDB), Color(hex: 0x4C3AC4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Active sidebar-tier fill — a darkened `brandGradient`, same two hues, so
    /// it reads as the same family at rest rather than an unrelated navy.
    static var tierActiveGradient: LinearGradient {
        LinearGradient(
            colors: NSApp.effectiveAppearanceIsDark
                ? [Color(hex: 0x1B4386), Color(hex: 0x36267A)]
                : [Color(hex: 0x14398C), Color(hex: 0x332270)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Metrics (handoff values)

    static let windowRadius:  CGFloat = 12
    static let controlRadius: CGFloat = 10   // --r-sm: buttons, tier cards, item rows
    static let dialogRadius:  CGFloat = 14   // --r-md: dialogs, feature cards
    static let sidebarWidth:  CGFloat = 262
    static let titleBarHeight: CGFloat = 46
    static let rowPaddingV:   CGFloat = 11
    static let rowPaddingH:   CGFloat = 14

    /// Every transition in the app. `200ms cubic-bezier(.22,1,.36,1)`.
    static let transition = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    // MARK: - Type
    //
    // Three faces, each with a job (handoff §Typography):
    //   Space Grotesk — headline weight only: wordmark, screen/tier titles,
    //                   item names in the explanation panel, dialog titles.
    //   system (SF Pro) — everything else: buttons, nav, sidebar, chrome.
    //   Epilogue      — longer explanatory body copy.
    //   monospaced    — every numeric value, without exception. Hard rule.

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.custom("Space Grotesk", size: size).weight(weight)
    }

    static func body(_ size: CGFloat = 13.5, weight: Font.Weight = .regular) -> Font {
        Font.custom("Epilogue", size: size).weight(weight)
    }

    static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Any GB / percentage / count / timestamp. Never render a number without it.
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Tracked small caps used for section eyebrows ("TIERS"). Apply
    /// `.textCase(.uppercase)` and `.tracking(0.8)` at the call site.
    static func eyebrow() -> Font { .system(size: 10.5, weight: .semibold) }

    // MARK: - Helpers

    private static func dyn(dark: Int, light: Int, darkA: CGFloat = 1, lightA: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let alpha = isDark ? darkA : lightA
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   alpha)
        })
    }
}

extension Color {
    init(hex: Int, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension NSApplication {
    /// Tier opacities and the brand gradients are opacity/stop ramps rather than
    /// single colors, so they can't ride the dynamic-`NSColor` path the way the
    /// flat tokens do and have to resolve appearance explicitly.
    var effectiveAppearanceIsDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
