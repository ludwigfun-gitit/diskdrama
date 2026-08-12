import SwiftUI

/// The 262px rail (F08).
///
/// Reading order top to bottom is deliberate and comes straight from the
/// handoff: *how bad is it* (free space) → *what can I do about it* (tiers) →
/// *has this happened before* (changes/history) → *where did it actually go*
/// (map) → settings. Each block answers the question the one above it provokes.
struct Sidebar: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            freeSpaceSummary
            divider(top: 0, bottom: 10)
            Eyebrow(text: "Tiers").padding(.horizontal, 11).padding(.bottom, 8)
            tierCards
            divider(top: 14, bottom: 14)
            navigation
            Spacer(minLength: 12)
            storageMap
            settingsRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Theme.sidebarWidth)
        .background(Theme.rail)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    // MARK: - Free space

    private var freeSpaceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.disk.info.map { ByteFormat.compact($0.availableBytes) } ?? "—")
                    .font(Theme.mono(21, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let info = model.disk.info {
                    Text("free of \(ByteFormat.compact(info.totalBytes))")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.text3)
                }
            }
            CapacityTrack(fraction: model.disk.info?.usedFraction ?? 0)
            reclaimableLine
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }

    /// The one line in the sidebar that is allowed to be accent-colored: it is
    /// the app's entire proposition in five words.
    ///
    /// "Another" is doing the work that "X of that is reclaimable" failed at.
    /// This sits directly under "40.6 GB free of 494.4 GB", so a pronoun grabs
    /// *free* — and that reading is not just vague but impossible, since
    /// reclaimable space is routinely larger than free space. It is space in use
    /// that could be freed, i.e. space on top of what is already free, which is
    /// precisely what "another" says.
    @ViewBuilder
    private var reclaimableLine: some View {
        if model.totalReclaimableBytes > 0 {
            Text("Another \(ByteFormat.compact(model.totalReclaimableBytes)) can be reclaimed.")
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.hasNeverScanned {
            Text("Nothing scanned yet.")
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.text3)
        } else {
            Text("Nothing I'd suggest deleting.")
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.text3)
        }
    }

    // MARK: - Tiers

    private var tierCards: some View {
        VStack(spacing: 6) {
            // First, above the three. What was not measured qualifies every
            // number below it, so it has to be read before them rather than
            // found underneath them.
            //
            // Only when there is something in it: a permanently empty fourth
            // card would be a standing invitation to click on nothing.
            if !model.unplacedBlindSpots.isEmpty {
                UnscannedCard(
                    count: model.unplacedBlindSpots.count,
                    isActive: model.pane == .unscanned,
                    action: { model.pane = .unscanned })
            }
            ForEach(Tier.allCases, id: \.self) { tier in
                TierCard(
                    tier: tier,
                    itemCount: model.items(in: tier).count,
                    sizeBytes: model.reclaimable(in: tier),
                    isActive: model.activeTier == tier,
                    action: { model.pane = .tier(tier) })
            }
        }
    }

    // MARK: - Navigation

    private var navigation: some View {
        VStack(spacing: 2) {
            NavRow(
                title: "Changes",
                badge: changesBadge,
                badgeIsAccent: !(model.delta?.regrown.isEmpty ?? true),
                isActive: model.pane == .changes,
                action: { model.pane = .changes })
            NavRow(
                title: "History",
                badge: model.cleanupLog.isEmpty ? "none yet"
                                                : "\(ByteFormat.compact(model.allTimeFreedBytes)) all-time",
                badgeIsAccent: false,
                isActive: model.pane == .history,
                action: { model.pane = .history })
            NavRow(
                title: "Watching",
                badge: "\(model.watchedCount)",
                badgeIsAccent: false,
                isActive: model.pane == .watching,
                flashMessage: model.flash?.destination == .watching ? model.flash?.message : nil,
                action: { model.pane = .watching })

        }
    }


    private var changesBadge: String {
        guard let delta = model.delta else { return "first scan" }
        let regrown = delta.regrown.count
        return regrown > 0 ? "\(regrown) regrown" : "no regrowth"
    }

    // MARK: - Storage map

    @ViewBuilder
    private var storageMap: some View {
        if !model.topConsumers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Where it all went")
                StorageMapGrid(consumers: model.topConsumers)
            }
            .padding(.horizontal, 11)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Settings

    private var settingsRow: some View {
        HoverRow(isActive: false, action: { model.isShowingSettings = true }, label: "Settings") {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                Text("Settings").font(Theme.ui(13))
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private func divider(top: CGFloat, bottom: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

// MARK: - Tier card

/// One tier in the rail.
///
/// The inactive fill is a single violet at three opacities — *not* three colors
/// and *not* a gradient. Safe is faintest, Review most saturated, so the tiers
/// read as one scale of caution rather than as three unrelated categories. The
/// active card switches to the darkened brand gradient, which is the same two
/// hues at rest, so selection never introduces an unrelated navy.
private struct TierCard: View {
    let tier: Tier
    let itemCount: Int
    let sizeBytes: Int64
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var symbol: String {
        switch tier {
        case .safe:        "checkmark.circle"
        case .appManaged:  "display"
        case .reviewFirst: "info.circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? .white : Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(isActive ? Color.white.opacity(0.22) : Theme.hover,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.title)
                        .font(Theme.ui(14, weight: .bold))
                        .foregroundStyle(isActive ? .white : Theme.text)
                    Text(subtitle)
                        .font(Theme.body(12))
                        .foregroundStyle(isActive ? Color.white.opacity(0.82) : Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                Text(ByteFormat.compact(sizeBytes))
                    .font(Theme.mono(14, weight: .bold))
                    .foregroundStyle(isActive ? .white : Theme.text)
            }
            .padding(12)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .stroke(isActive ? .clear : Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isActive ? 0.20 : 0), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.transition, value: isActive)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(tier.title), \(itemCount) item\(itemCount == 1 ? "" : "s"), \(ByteFormat.compact(sizeBytes))")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var subtitle: String {
        itemCount == 0 ? "nothing here" : "\(itemCount) items · \(tier.shortHint)"
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.tierActiveGradient)
        } else {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.tierFill(tier.rawValue))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(isHovering ? Theme.hover : .clear)
                )
        }
    }
}

private extension Tier {
    /// The two- or three-word version for the tier card, where the full subtitle
    /// would wrap.
    var shortHint: String {
        switch self {
        case .safe:        "regenerates"
        case .appManaged:  "clear in the app"
        case .reviewFirst: "your data"
        }
    }
}

// MARK: - Nav rows

private struct NavRow: View {
    let title: String
    let badge: String
    let badgeIsAccent: Bool
    let isActive: Bool
    /// Present only while the row is confirming something that just landed in it.
    ///
    /// It is not drawn. The highlight is the whole visible signal — a sentence
    /// beside it restated what the colour already said, and the row is where the
    /// user will look for detail anyway. It still reaches VoiceOver, because a
    /// colour-only confirmation is no confirmation at all to a screen reader.
    var flashMessage: String? = nil
    let action: (() -> Void)?

    var body: some View {
        HoverRow(isActive: isActive, isFlashing: flashMessage != nil, action: action,
                 label: flashMessage.map { "\(title), \(badge). \($0)" } ?? "\(title), \(badge)") {
            HStack(spacing: 10) {
                Text(title).font(Theme.ui(13, weight: isActive ? .semibold : .medium))
                Spacer()
                Text(badge)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(badgeIsAccent ? Theme.accent : Theme.text3)
            }
        }
    }
}

/// The rail's shared row chrome: accent-soft fill when active, neutral hover
/// tint otherwise.
///
/// A row that navigates is a `Button`, not a tap gesture on a rectangle. The
/// visual result is identical under `.plain`, but the row gains an
/// accessibility role, keyboard focus and a press action — a gesture-only row is
/// invisible to VoiceOver and unreachable without a mouse. Rows with no
/// destination render as plain content so they don't advertise an action they
/// don't have.
private struct HoverRow<Content: View>: View {
    let isActive: Bool
    /// Briefly accent-filled to point at a row that just received something.
    /// Stronger than the active fill on purpose — it has to read as movement in
    /// peripheral vision, since the user is looking at the button they pressed
    /// on the other side of the window, not at the sidebar.
    var isFlashing: Bool = false
    var action: (() -> Void)?
    /// Stated rather than inferred, since the chrome's children are hidden.
    var label: String = ""
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        if let action {
            // The label goes on the Button, and the children are hidden rather
            // than collapsed. Applying `.accessibilityElement(children: .ignore)`
            // *outside* a Button strips its role — the row rendered fine and
            // exposed itself as AXUnknown, invisible to VoiceOver and
            // unreachable by keyboard.
            Button(action: action) { chrome.accessibilityHidden(true) }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .accessibilityLabel(label)
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        } else {
            // An inert row has no button to preserve, so collapsing is right —
            // otherwise its two Texts are read as two separate elements.
            chrome
                .onHover { isHovering = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var chrome: some View {
        content
            .foregroundStyle(isActive || isFlashing ? Theme.accent
                                                    : (isHovering ? Theme.text : Theme.text2))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFlashing ? Theme.accent.opacity(0.24)
                          : isActive ? Theme.accent.opacity(0.10)
                          : (isHovering ? Theme.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(Theme.transition, value: isActive)
            .animation(Theme.transition, value: isFlashing)
    }
}

// MARK: - Storage map

/// The mini treemap.
///
/// Every cell is neutral. An accent-filled cell was tried during design and
/// removed: it read as *selected*, and there is no selection behind it. This is
/// a picture of where the space went, not a set of controls.
private struct StorageMapGrid: View {
    let consumers: [(name: String, sizeBytes: Int64)]

    private let columnWeights: [CGFloat] = [1.4, 1, 0.8]
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - gap * 2) / columnWeights.reduce(0, +)
            HStack(alignment: .top, spacing: gap) {
                cell(consumers.first, height: 69)
                    .frame(width: unit * columnWeights[0])
                VStack(spacing: gap) {
                    cell(consumers.count > 1 ? consumers[1] : nil, height: 40)
                    cell(nil, height: 26)
                }
                .frame(width: unit * columnWeights[1])
                VStack(spacing: gap) {
                    cell(consumers.count > 2 ? consumers[2] : nil, height: 40)
                    cell(nil, height: 26)
                }
                .frame(width: unit * columnWeights[2])
            }
        }
        .frame(height: 69)
    }

    @ViewBuilder
    private func cell(_ consumer: (name: String, sizeBytes: Int64)?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.track)
            .frame(height: height)
            // Top-aligned: the cells are three different heights, and hanging
            // the labels off the bottom made them sit on three different
            // baselines. Reading across the row now starts on one line.
            .overlay(alignment: .topLeading) {
                if let consumer {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(consumer.name)
                            .font(Theme.ui(10, weight: .medium))
                            .lineLimit(1)
                        Text(ByteFormat.compact(consumer.sizeBytes))
                            .font(Theme.mono(9))
                    }
                    .foregroundStyle(Theme.text2)
                    .padding(6)
                }
            }
    }
}


/// The fourth card. Shaped like a `TierCard` so it reads as a peer of the three,
/// coloured unlike one so it does not read as a fourth degree of safety.
///
/// Where a tier card shows bytes, this shows nothing — deliberately. The whole
/// claim of the card is that these locations were never measured, and a number
/// there would be a guess dressed as a reading.
private struct UnscannedCard: View {
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? .white : Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(isActive ? Color.white.opacity(0.22) : Theme.hover,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Not scanned")
                        .font(Theme.ui(14, weight: .bold))
                        .foregroundStyle(isActive ? .white : Theme.text)
                    Text("\(count) location\(count == 1 ? "" : "s") · size unknown")
                        .font(Theme.body(12))
                        .foregroundStyle(isActive ? Color.white.opacity(0.82) : Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                Text("—")
                    .font(Theme.mono(14, weight: .bold))
                    .foregroundStyle(isActive ? Color.white.opacity(0.65) : Theme.text3)
            }
            .padding(12)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .stroke(isActive ? .clear : Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isActive ? 0.20 : 0), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.transition, value: isActive)
        .accessibilityLabel("Not scanned, \(count) location\(count == 1 ? "" : "s"), size unknown")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.unscannedActiveGradient)
        } else {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.unscannedFill)
        }
    }
}
