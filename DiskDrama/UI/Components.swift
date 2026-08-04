import SwiftUI

// Shared controls, built to the handoff's spec rather than to AppKit defaults.
//
// The handoff is explicit that the only borders in the app are neutral gray, used
// solely to separate a control from a same-colored background. No accent, danger
// or tier borders anywhere — emphasis is fill and text color only. Every earlier
// attempt at a colored border was removed during design, so a colored ring here
// would be re-introducing something already rejected.

// MARK: - Buttons

/// Solid accent. The one primary action in any given context.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 13
    var fontSize: CGFloat = 13
    /// Destructive variant — permitted only in delete confirmations and the
    /// low-space alert, per the handoff's single-red-moment rule.
    var isDestructive: Bool = false

    // A custom `ButtonStyle` gets no disabled appearance for free — SwiftUI only
    // dims the built-in styles. Without reading this, a disabled control renders
    // identically to a live one, which is worse than having no control at all:
    // the user clicks it and concludes the app is broken.
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(isDestructive ? Theme.danger : Theme.accent,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .brightness(isHovering && isEnabled ? 0.06 : 0)
            .shadow(color: isHovering && isEnabled ? Theme.accent.opacity(0.30) : .black.opacity(0.20),
                    radius: isHovering && isEnabled ? 8 : 1, y: isHovering && isEnabled ? 0 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.transition, value: configuration.isPressed)
            .animation(Theme.transition, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Outlined. Secondary actions that still need to be findable.
struct GhostButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 12
    var fontSize: CGFloat = 13

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(fontSize, weight: .medium))
            .foregroundStyle(isHovering && isEnabled ? Theme.accent : Theme.text)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .stroke(Theme.hairline2, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.transition, value: configuration.isPressed)
            .animation(Theme.transition, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// No chrome at all until hovered. For the "I'd rather not" actions that must be
/// available without competing for attention.
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var fontSize: CGFloat = 12.5

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(fontSize, weight: .medium))
            .foregroundStyle(isHovering ? Theme.text : Theme.text3)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(isHovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(Theme.transition, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Small parts

/// The 5px capacity bar used in the sidebar and the dropdown.
///
/// Neutral, never accent-colored: it shows how full the disk is, which is a fact
/// about the machine rather than an action the user can take, and the handoff
/// reserves accent for interactivity.
struct CapacityTrack: View {
    let fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.text3)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Accent pill on an item row — "Back again", "Regenerates".
struct RowBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.ui(11.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.10), in: Capsule())
    }
}

/// The bordered explanatory box the design uses for "not on this list" and the
/// regrowth note. Neutral by construction — it is information, not a warning.
struct Callout: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.text3)
                .padding(.top, 1)
            Text(text)
                .font(Theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}

/// Tracked small caps section label — "TIERS", "WHERE IT ALL WENT".
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.eyebrow())
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.text3)
    }
}

/// A full-pane message for the states where there is nothing to list.
///
/// Every empty state in this app names its own situation. "No items" would be
/// indistinguishable from a scan that silently failed, which is the one thing a
/// tool that deletes files cannot afford to look like.
struct EmptyPane<Actions: View>: View {
    let title: String
    let message: String
    var symbol: String = "tray"
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(Theme.display(17))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(Theme.body(13.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension EmptyPane where Actions == EmptyView {
    init(title: String, message: String, symbol: String = "tray") {
        self.init(title: title, message: message, symbol: symbol) { EmptyView() }
    }
}

// MARK: - Backgrounds

/// The content pane's two-corner wash (`--grad-wash`).
///
/// Purely decorative depth. Kept very low opacity on purpose — it is the reason
/// the pane doesn't read as a flat gray rectangle, and the moment it is visible
/// as a gradient it is too strong.
struct ContentWash: View {
    var body: some View {
        ZStack {
            Theme.content
            RadialGradient(
                colors: [Theme.accent.opacity(0.10), .clear],
                center: UnitPoint(x: 0.12, y: -0.20), startRadius: 0, endRadius: 620)
            RadialGradient(
                colors: [Color(hex: 0x6366F1).opacity(0.07), .clear],
                center: UnitPoint(x: 1.0, y: 0.0), startRadius: 0, endRadius: 520)
        }
    }
}

// MARK: - Helpers

enum PathDisplay {
    /// Home-relative form. Operates on the raw string via `NSString` — never by
    /// constructing a `URL` — because §5.1's File-Provider XPC traps live on
    /// `URL`'s property accessors and this runs on the main thread for every
    /// visible row.
    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// `Formatter` subclasses are not `Sendable`, and building one per row is
/// measurable on a long history list — so the shared instance is pinned to the
/// main actor, which is the only place anything here renders.
@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Anything inside the last minute is "just now".
    ///
    /// `RelativeDateTimeFormatter` renders a scan that finished a moment ago as
    /// "in 0 seconds" — future tense, zero magnitude — because `completedAt` can
    /// land a hair ahead of the comparison instant. The first thing the user sees
    /// after their first ever scan should not be a sentence that parses as
    /// nonsense.
    static func phrase(_ date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Terse form for dense tables: `2d ago`, `9mo ago`.
    ///
    /// Hand-built rather than `RelativeDateTimeFormatter(.abbreviated)`, which
    /// localizes and would reintroduce the separator mismatch `ByteFormat.count`
    /// exists to avoid — these sit in a monospaced column beside sizes.
    static func compact(_ date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1:   return "today"
        case ..<31:  return "\(days)d ago"
        case ..<365: return "\(days / 30)mo ago"
        default:     return "\(days / 365)y ago"
        }
    }
}
