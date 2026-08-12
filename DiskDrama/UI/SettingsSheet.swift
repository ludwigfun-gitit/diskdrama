import SwiftUI
import AppKit

/// Settings (F19, and the home of everything configurable).
///
/// Absorbs the interim API-key sheet from Step 8, which existed only so the
/// explanation layer was reachable at all.
///
/// The two "stop suggesting this" lists live here together on purpose, because
/// the difference between them is the thing people get wrong: **Ignored** is "I
/// know, stop telling me" — still scanned, still counted in the totals.
/// **Never look here** is "don't even go in there" — invisible to the scanner,
/// and its size is therefore unknown by design. Putting them side by side with
/// that stated is cheaper than explaining it twice later.
struct SettingsSheet: View {

    @Bindable var model: AppModel

    @State private var apiKey = ""
    @State private var hasStoredKey = APIKeyStore.hasKey
    @State private var scanRoots = Settings.shared.scanRoots
    @State private var exclusions = Settings.shared.exclusions
    @State private var deleteMode = Settings.shared.defaultDeletionMode
    @State private var menuBarOnly = Settings.shared.menuBarOnly
    @State private var lowGB = SettingsSheet.gbText(Settings.shared.lowThresholdBytes)
    @State private var criticalGB = SettingsSheet.gbText(Settings.shared.criticalThresholdBytes)
    /// Set only when a commit had to move the *other* value to keep the pair
    /// valid. Silently rewriting a number the user just typed, with no word
    /// about it, is how a settings pane loses trust.
    @State private var clampNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    thresholdsSection
                    presentationSection
                    explanationsSection
                    scanRootsSection
                    exclusionsSection
                    hiddenBlindSpotsSection
                    ignoredSection
                    deletionSection
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack {
            Text("Settings").font(Theme.display(17)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                // A value typed without pressing return is still a value the
                // user asked for; losing it silently on close would be worse
                // than applying it.
                commitLow()
                commitCritical()
                model.isShowingSettings = false
            }
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Sections

    private var thresholdsSection: some View {
        Section(title: "When to warn you",
                blurb: "The menubar icon takes on a colour as free space drops — amber at the "
                     + "first level, red at the second. Both are in gigabytes.") {
            VStack(spacing: 0) {
                thresholdRow("Warn below", dot: .orange, text: $lowGB, commit: commitLow)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                thresholdRow("Critical below", dot: Theme.danger, text: $criticalGB, commit: commitCritical)
            }
            .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1))

            if let clampNote {
                Text(clampNote).settingsCaption()
            } else {
                Text("Critical always stays below the warning level — a disk under the critical "
                     + "figure is under the warning figure too, so the reverse would be a "
                     + "contradiction.")
                    .settingsCaption()
            }
        }
    }

    private func thresholdRow(_ title: String, dot: Color,
                              text: Binding<String>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12.5))
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline2, lineWidth: 1))
                .onSubmit(commit)
                .accessibilityLabel(title)

            Text("GB").font(Theme.mono(12)).foregroundStyle(Theme.text3)

            Stepper("") {
                nudge(text, by: 0.5, commit: commit)
            } onDecrement: {
                nudge(text, by: -0.5, commit: commit)
            }
            .labelsHidden()
            .accessibilityLabel("\(title) stepper")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Threshold arithmetic

    /// Decimal GB, matching `Settings`' own defaults (5 GB is 5_000_000_000
    /// there) and `ByteFormat`. Mixing in binary units here would make the
    /// number shown in Settings disagree with the number in the menubar.
    private static let bytesPerGB: Double = 1_000_000_000
    /// The pair needs somewhere to go: critical must sit strictly below the
    /// warning level, so the warning level cannot itself be at the floor.
    private static let floorGB = 0.1
    private static let gapGB = 0.1

    private static func gbText(_ bytes: Int64) -> String {
        let value = Double(bytes) / bytesPerGB
        return value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private static func bytes(_ gb: Double) -> Int64 { Int64((gb * bytesPerGB).rounded()) }

    private func nudge(_ text: Binding<String>, by delta: Double, commit: () -> Void) {
        let current = Double(text.wrappedValue.trimmingCharacters(in: .whitespaces)) ?? 0
        text.wrappedValue = Self.gbText(Self.bytes(max(Self.floorGB, current + delta)))
        commit()
    }

    /// Both commits clamp rather than reject. Refusing the number and leaving
    /// the old one in place makes the user work out the rule themselves; moving
    /// the *other* value and saying so keeps their stated intent and explains
    /// what it cost.
    private func commitLow() {
        guard let typed = Double(lowGB.trimmingCharacters(in: .whitespaces)) else {
            lowGB = Self.gbText(Settings.shared.lowThresholdBytes)
            return
        }
        let low = max(Self.floorGB + Self.gapGB, typed)
        Settings.shared.lowThresholdBytes = Self.bytes(low)
        lowGB = Self.gbText(Self.bytes(low))

        if Settings.shared.criticalThresholdBytes >= Self.bytes(low) {
            let critical = max(Self.floorGB, low - Self.gapGB)
            Settings.shared.criticalThresholdBytes = Self.bytes(critical)
            criticalGB = Self.gbText(Self.bytes(critical))
            clampNote = "Critical moved to \(criticalGB) GB to stay below the warning level."
        } else {
            clampNote = nil
        }
        model.onThresholdsChanged?()
    }

    private func commitCritical() {
        guard let typed = Double(criticalGB.trimmingCharacters(in: .whitespaces)) else {
            criticalGB = Self.gbText(Settings.shared.criticalThresholdBytes)
            return
        }
        let low = Double(Settings.shared.lowThresholdBytes) / Self.bytesPerGB
        var critical = max(Self.floorGB, typed)
        if critical >= low {
            critical = max(Self.floorGB, low - Self.gapGB)
            clampNote = "Critical has to sit below the warning level, so it's been set to "
                      + "\(Self.gbText(Self.bytes(critical))) GB."
        } else {
            clampNote = nil
        }
        Settings.shared.criticalThresholdBytes = Self.bytes(critical)
        criticalGB = Self.gbText(Self.bytes(critical))
        model.onThresholdsChanged?()
    }

    private var presentationSection: some View {
        Section(title: "Where DiskDrama lives",
                blurb: "It always sits in the menu bar. Opening the window normally also puts it "
                     + "in the Dock, like any other app.") {
            Toggle("Menu bar only — no Dock icon", isOn: $menuBarOnly)
                .toggleStyle(.checkbox)
                .onChange(of: menuBarOnly) { _, new in
                    Settings.shared.menuBarOnly = new
                    model.onPresentationChanged?()
                }

            Text(menuBarOnly
                 ? "The window still opens from the menu bar. One catch: an app with no Dock icon "
                 + "doesn't own the menu bar either, so DiskDrama's own menus won't appear — "
                 + "whichever app you were last in keeps them, even while this window is focused."
                 : "The Dock icon appears while the window is open and goes away when you close it.")
                .settingsCaption()
        }
    }

    private var explanationsSection: some View {
        Section(title: "Deeper explanations",
                blurb: "DiskDrama tiers everything on its own, offline and free. For a closer look at "
                     + "whichever item you've selected it can also ask a model — Apple's on-device one "
                     + "when this Mac can run it, otherwise Claude, if you've saved a key.") {
            sourceStatus
            SecureField(hasStoredKey ? "A key is saved — paste a new one to replace it" : "sk-ant-…",
                        text: $apiKey)
                .textFieldStyle(.plain)
                .font(Theme.mono(12.5))
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.hairline2, lineWidth: 1))

            HStack(spacing: 9) {
                Button("Save key") {
                    APIKeyStore.save(apiKey)
                    hasStoredKey = APIKeyStore.hasKey
                    apiKey = ""
                }
                .buttonStyle(GhostButtonStyle(height: 28, fontSize: 12.5))
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Button("Remove key") {
                        APIKeyStore.delete()
                        hasStoredKey = false
                    }
                    .buttonStyle(QuietButtonStyle(height: 28))
                }
                Spacer()
            }

            Text(privacyCaption).settingsCaption()
        }
    }

    /// Which source is actually in use.
    ///
    /// There is no picker here — choosing between providers is a decision that
    /// hasn't been made. But saying nothing was worse than either option: with
    /// the on-device model preferred, a saved key sits in the Keychain doing
    /// nothing while the section above it implies the key is what makes the
    /// feature work. Stating which one is live costs one row and stops Settings
    /// describing an arrangement the app isn't using.
    private var sourceStatus: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if model.explanations.sourceName == nil {
                    // Nothing is running, so nothing should look lit.
                    Circle().fill(Theme.text3).frame(width: 7, height: 7)
                } else {
                    GlowDot(size: 7)
                }
            }
            .padding(.top, 5)
            Text(sourceDescription)
                .font(Theme.body(12.5)).lineSpacing(3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
    }

    private var sourceDescription: String {
        guard let source = model.explanations.sourceName else {
            return "No deeper explanations right now — the local rule table is doing all the work. "
                 + "Save a key below, or turn on Apple Intelligence if this Mac supports it."
        }
        guard model.explanations.sourceIsLocal == true else {
            return "Using \(source), through your saved key."
        }
        return hasStoredKey
            ? "Using \(source), on this Mac. Your saved key isn't being used — the on-device model "
            + "is preferred because it costs nothing and sends nothing. Remove the key and nothing changes."
            : "Using \(source), on this Mac. Nothing is sent anywhere and nothing is charged."
    }

    /// The privacy line only ever described the cloud path. When the on-device
    /// model is the one answering, "only the name, size and date are sent" is
    /// true but badly misleading — nothing is sent at all.
    private var privacyCaption: String {
        if model.explanations.sourceIsLocal == true {
            return "The on-device model runs entirely on this Mac, so nothing about your files leaves "
                 + "it. A key is only used if Apple Intelligence becomes unavailable."
        }
        return "Stored in your Keychain, on this Mac only. Only the selected folder's name, size and "
             + "date are ever sent — never file contents, never the rest of your disk."
    }

    private var scanRootsSection: some View {
        Section(title: "Where DiskDrama looks",
                blurb: "Scanning is scoped to these folders. Everything else on the disk is "
                     + "invisible to it — including anything it might otherwise offer to delete.") {
            PathList(paths: scanRoots, emptyNote: "No roots configured — DiskDrama will scan your home folder.") { path in
                scanRoots.removeAll { $0 == path }
                Settings.shared.scanRoots = scanRoots
            }
            AddFolderButton(title: "Add a folder to scan") { path in
                guard !scanRoots.contains(path) else { return }
                scanRoots.append(path)
                Settings.shared.scanRoots = scanRoots
            }
        }
    }

    private var exclusionsSection: some View {
        Section(title: "Never look here",
                blurb: "Skipped entirely — not scanned, not counted, not recommended. Their sizes "
                     + "are unknown by design; DiskDrama can't report on a folder it never opens. "
                     + "iCloud Drive and other cloud-synced storage are excluded from the start, "
                     + "because opening a file that hasn't finished downloading to this Mac can "
                     + "stall a scan for minutes. Remove either one below if you'd rather "
                     + "DiskDrama looked there too.") {
            PathList(paths: exclusions, emptyNote: "Nothing excluded.") { path in
                model.unexclude(path: path)
                exclusions = Settings.shared.exclusions
            }
            AddFolderButton(title: "Exclude a folder") { path in
                model.exclude(path: path)
                exclusions = Settings.shared.exclusions
            }
        }
    }

    private var hiddenBlindSpotsSection: some View {
        Section(title: "Stopped listing these",
                blurb: "Locations DiskDrama couldn't read and you've asked it to stop listing. "
                     + "Unlike the two lists below, this changes nothing about the scan — there "
                     + "was nothing readable to scan. They're still missing from every total, and "
                     + "the Not scanned pane still says how many; this only stops them being "
                     + "named every time.") {
            if model.hiddenBlindSpotPaths.isEmpty {
                Text("Nothing hidden.").settingsCaption()
            } else {
                PathList(paths: Array(model.hiddenBlindSpotPaths).sorted(), emptyNote: "") { path in
                    model.unhideBlindSpot(path: path)
                }
            }
        }
    }

    private var ignoredSection: some View {
        Section(title: "Never suggest these",
                blurb: "Still scanned and still counted toward your totals — DiskDrama just "
                     + "stops offering them. That's the difference from the list above.") {
            if model.ignoredPaths.isEmpty {
                Text("Nothing dismissed.").settingsCaption()
            } else {
                PathList(paths: Array(model.ignoredPaths).sorted(), emptyNote: "") { path in
                    model.unignore(path: path)
                }
            }
        }
    }

    private var deletionSection: some View {
        Section(title: "When you delete something",
                blurb: "Whichever you pick here is only the starting position — every "
                     + "confirmation still lets you change it for that one job.") {
            Picker("", selection: $deleteMode) {
                Text("Move it to the Trash").tag(DeletionMode.trash)
                Text("Remove it immediately").tag(DeletionMode.immediate)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: deleteMode) { _, new in Settings.shared.defaultDeletionMode = new }

            Text(deleteMode == .trash
                 ? "Recoverable, and the space comes back when you empty the Trash."
                 : "The space frees immediately, and there is no undo. DiskDrama defaults to the Trash for a reason.")
                .settingsCaption()
        }
    }
}

// MARK: - Pieces

private struct Section<Content: View>: View {
    let title: String
    let blurb: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(blurb)
                    .font(Theme.body(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct PathList: View {
    let paths: [String]
    let emptyNote: String
    let onRemove: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if paths.isEmpty {
                if !emptyNote.isEmpty {
                    Text(emptyNote).settingsCaption()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                }
            } else {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 10) {
                        // Two lines only where the path needs translating. Every
                        // other row — scan roots, folders the user chose
                        // themselves, dismissed items — is a path they already
                        // recognise, and giving it a second line would be noise.
                        if let friendly = PathDisplay.friendlyName(path) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friendly)
                                    .font(Theme.ui(13))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(PathDisplay.short(path))
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.text3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Text(PathDisplay.short(path))
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { onRemove(path) }
                            .buttonStyle(QuietButtonStyle(height: 22, fontSize: 11.5))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        if path != paths.last {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
    }
}

/// F19's "add (or drag folder in)" — the picker half. A real `NSOpenPanel`
/// rather than a text field, because a mistyped path in an exclusion list fails
/// silently and invisibly.
private struct AddFolderButton: View {
    let title: String
    let onPick: (String) -> Void

    var body: some View {
        Button(title) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let url = panel.url {
                onPick(url.path)
            }
        }
        .buttonStyle(GhostButtonStyle(height: 28, fontSize: 12.5))
    }
}

private extension View {
    func settingsCaption() -> some View {
        self.font(Theme.body(12))
            .lineSpacing(3)
            .foregroundStyle(Theme.text3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
