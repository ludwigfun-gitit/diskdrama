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
    @State private var keyError: String?
    @State private var startAtLogin = LoginItem.isEnabled
    @State private var deleteMode = Settings.shared.defaultDeletionMode
    @State private var menuBarOnly = Settings.shared.menuBarOnly
    @State private var lowGB = SettingsSheet.gbText(Settings.shared.lowThresholdBytes)
    @State private var criticalGB = SettingsSheet.gbText(Settings.shared.criticalThresholdBytes)
    /// Set only when a commit had to move the *other* value to keep the pair
    /// valid. Silently rewriting a number the user just typed, with no word
    /// about it, is how a settings pane loses trust.
    @State private var clampNote: String?

    /// Which pane is showing. Persisted for the session only — reopening
    /// Settings in the pane you last used is helpful; remembering it across
    /// launches means the app opens somewhere you have forgotten choosing.
    @State private var tab: Tab = .general
    /// Presented by this sheet, not through `model.activeSheet`.
    ///
    /// Settings is itself a sheet on the main window, so assigning `activeSheet`
    /// from inside it queued a second presentation on the same host and the Buy
    /// button did nothing — the identical mistake the onboarding card made, in a
    /// second place, because the fix there was applied to the symptom instead of
    /// to every caller that shares the cause.
    @State private var showActivation = false

    private enum Tab: String {
        case general, scanning, cleaning, explanations, licence
    }

    /// Tabs rather than one long scroll.
    ///
    /// Eleven sections in a single column meant everything after the fourth was
    /// found by scrolling past things you were not looking for, and the licence
    /// drowned in the middle of it. Visuals solves this with a top-level tab per
    /// area and a `License` tab of its own; this follows that, which also makes
    /// the sheet behave like every other macOS preferences window.
    ///
    /// Grouped by what you are trying to do, not by which feature shipped when:
    /// warnings and appearance are General, everything about where to look is
    /// Scanning, everything about removing things is Cleaning.
    var body: some View {
        VStack(spacing: 0) {
            header
            // No rule above the tabs and none below them: the tab strip already
            // reads as a divide, and `TabView` draws its own hairline along the
            // top of the content pane. Adding ours put two lines a few points
            // apart and a third doubled onto the pane's own border.
            TabView(selection: $tab) {
                pane { thresholdsSection; presentationSection; startupSection }
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(Tab.general)

                pane { scanRootsSection; exclusionsSection; hiddenBlindSpotsSection }
                    .tabItem { Label("Scanning", systemImage: "magnifyingglass") }
                    .tag(Tab.scanning)

                pane { deletionSection; ignoredSection; undeletableSection }
                    .tabItem { Label("Cleaning", systemImage: "trash") }
                    .tag(Tab.cleaning)

                pane { explanationsSection }
                    .tabItem { Label("AI Guidance", systemImage: "sparkles") }
                    .tag(Tab.explanations)

                pane { licencePane }
                    .tabItem { Label("Licence", systemImage: "key") }
                    .tag(Tab.licence)
            }
            .padding(.top, 10)
            footer
        }
        .frame(width: 580, height: 640)
        .background(Theme.panel)
        // Focus rings off across the whole sheet, not tab by tab.
        //
        // The selected tab drew a heavy blue halo the moment the sheet opened,
        // which read as an error state rather than as "this is where you are" —
        // the tab is already filled and tinted, so the ring said nothing the
        // selection did not. Disabling it once here means no control added later
        // can reintroduce it, which is how it came back the last time.
        .focusEffectDisabled()
        .background(FocusRingSuppressor())
        .sheet(isPresented: $showActivation) {
            ActivationSheet(model: model, onClose: { showActivation = false })
        }
    }

    /// Turns focus rings off in AppKit, where they are drawn.
    ///
    /// `.focusEffectDisabled()` is the SwiftUI answer and it did not finish the
    /// job here: the tab strip and the text fields are AppKit views underneath,
    /// and they keep drawing their own ring — on the fields it traced a
    /// rectangle around a control drawn as a rounded rect, which is why it
    /// looked ill-fitting rather than merely unwanted.
    ///
    /// So this walks the hosting window once the sheet is up and clears
    /// `focusRingType` on every view in it. Re-run on each layout pass because
    /// SwiftUI rebuilds NSViews as tabs change, and a view created after the
    /// sweep would arrive with its ring intact.
    private struct FocusRingSuppressor: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

        func updateNSView(_ view: NSView, context: Context) {
            DispatchQueue.main.async {
                guard let root = view.window?.contentView else { return }
                Self.clear(root)
            }
        }

        private static func clear(_ view: NSView) {
            view.focusRingType = .none
            if let control = view as? NSControl { control.focusRingType = .none }
            view.subviews.forEach(clear)
        }
    }

    /// One tab's worth of sections, scrolling if they outgrow the pane.
    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
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
                blurb: "The menubar icon takes on a colour as free space drops.") {
            VStack(spacing: 0) {
                thresholdRow("Warn below", dot: .orange, text: $lowGB, commit: commitLow)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                thresholdRow("Critical below", dot: Theme.danger, text: $criticalGB, commit: commitCritical)
            }
            .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1))

            // Only when a value actually had to move. The standing explanation
            // of why critical sits below warning was answering a question nobody
            // asks until it happens — and when it does happen, `clampNote` says
            // so about the specific number they typed.
            if let clampNote {
                Text(clampNote).settingsCaption()
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
        Section(title: "Where DiskDrama lives", blurb: nil) {
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
        Section(title: "AI guidance",
                blurb: "DiskDrama sorts everything into tiers on this Mac, offline and free. "
                     + "A model can add detail about whichever item you've selected: Apple's "
                     + "on-device model if this Mac supports it, or Claude if you save a key.") {
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
                // The field used to be cleared unconditionally, so a Keychain
                // write that failed looked precisely like one that worked: the
                // key vanished from the box and nothing else changed. `save`
                // already returns whether it succeeded — it was only ever the
                // caller discarding the answer.
                Button("Save key") {
                    if APIKeyStore.save(apiKey) {
                        keyError = nil
                        apiKey = ""
                    } else {
                        keyError = "Couldn't save the key to the Keychain. It hasn't been stored — your text is still here, so you can try again."
                    }
                    hasStoredKey = APIKeyStore.hasKey
                }
                .buttonStyle(GhostButtonStyle(height: 28, fontSize: 12.5))
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Button("Remove key") {
                        APIKeyStore.delete()
                        hasStoredKey = APIKeyStore.hasKey
                        keyError = hasStoredKey
                            ? "Couldn't remove the key from the Keychain. It's still stored."
                            : nil
                    }
                    .buttonStyle(QuietButtonStyle(height: 28))
                }
                Spacer()
            }

            if let keyError {
                Text(keyError).settingsCaption().foregroundStyle(Theme.danger)
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

    /// The licence tab, which *is* the purchase — not a door to one.
    ///
    /// It used to open PaywallSheet, a window carrying the same two buttons the
    /// tab already had. That is the user pressing Buy and being handed another
    /// Buy: the second screen added a comparison and three answers, but nothing
    /// that could not sit here, and everything it did add arrived one click
    /// after the person had already decided.
    ///
    /// So the content moved in. One screen, one Buy button, and the questions a
    /// one-time-purchase buyer actually has answered next to it rather than
    /// behind it. PaywallSheet still exists for the surfaces that genuinely
    /// interrupt — a blocked action, an expired trial — where there is no tab
    /// to put anything in.
    private var licencePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Stacked under the icon rather than beside it, sharing its left
            // edge — the blurb runs long enough that setting it in a column
            // next to a 38pt badge left it wrapping in a narrow gutter.
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: licenceSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(licenceTint)
                    .frame(width: 38, height: 38)
                    .background(licenceTint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(licenceTitle)
                        .font(Theme.display(17))
                        .foregroundStyle(Theme.text)
                    Text(licenceBlurb)
                        .font(Theme.body(12.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .licensed = model.entitlement.status {
                Button("Deactivate on this Mac") { model.licence.deactivate() }
                    .buttonStyle(GhostButtonStyle(height: 30, horizontalPadding: 13, fontSize: 13))
            } else {
                whatALicenceChanges
                purchaseQuestions
                // The caveat is about checkout, so it sits beside the button it
                // describes. Under both, it read as a note on the pair — and
                // "opens in your browser" is untrue of entering a key you
                // already have.
                HStack(alignment: .center, spacing: 12) {
                    Button(buyLabel) { PurchaseLink.openCheckout() }
                        .buttonStyle(AccentButtonStyle(height: 30, horizontalPadding: 15, fontSize: 13))
                    Text("Opens in your browser. One payment, no account.")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button("I already have a key") { showActivation = true }
                    .buttonStyle(GhostButtonStyle(height: 30, horizontalPadding: 13, fontSize: 13))
            }
        }
    }

    /// Keep-versus-locked, not a feature list — the live question is what a
    /// licence actually changes, and the app has been demonstrating the rest.
    private var whatALicenceChanges: some View {
        HStack(alignment: .top, spacing: 18) {
            licenceColumn("Works forever, free", tint: Theme.text3,
                          items: ["Scanning, and every result",
                                  "Why each thing is safe or isn't",
                                  "History, watches and blind spots"])
            licenceColumn("Needs a licence", tint: Theme.accent,
                          items: ["Delete what you've approved",
                                  "Clean a whole tier at once",
                                  "Free-space target planning"])
        }
    }

    private func licenceColumn(_ title: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(tint.opacity(0.5)).frame(width: 3.5, height: 3.5)
                    Text(item)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var purchaseQuestions: some View {
        VStack(alignment: .leading, spacing: 9) {
            licenceFAQ("Is this a subscription?",
                       "No. One payment, and the licence doesn't expire.")
            licenceFAQ("What if I reinstall, or get a new Mac?",
                       "Your key arrives by email and activates again. Nothing is tied to this machine.")
        }
        .padding(14)
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
    }

    private func licenceFAQ(_ question: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(question)
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text(answer)
                .font(Theme.body(12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A call to action, not a description of one.
    ///
    /// "See what it costs" described the next screen instead of inviting
    /// anything — and now that the lookup answers, the price can be on the button
    /// where it does the most work.
    private var buyLabel: String {
        PricingService.shared.displayPrice.map { "Buy DiskDrama — \($0)" } ?? "Buy DiskDrama"
    }

    private var licenceTitle: String {
        switch model.entitlement.status {
        case .licensed:       "Activated"
        case .trial:          "Trial"
        case .trialExpired:   "Read-only"
        }
    }

    private var licenceSymbol: String {
        switch model.entitlement.status {
        case .licensed:     "checkmark.seal"
        case .trial:        "clock"
        case .trialExpired: "lock"
        }
    }

    private var licenceTint: Color {
        switch model.entitlement.status {
        case .licensed:     Theme.accent
        case .trial:        Theme.accent
        case .trialExpired: Theme.text3
        }
    }

    private var licenceBlurb: String {
        switch model.entitlement.status {
        case .licensed:
            "One payment, no expiry. Nothing to renew and nothing to cancel."
        case .trial(let days):
            "\(days) day\(days == 1 ? "" : "s") left. Everything works until then; after that DiskDrama keeps showing you what's reclaimable but can't act on it."
        case .trialExpired:
            "DiskDrama still scans and still explains. Buying it lets it act on what it finds again."
        }
    }

    private var startupSection: some View {
        Section(title: "Starting up", blurb: nil) {
            Toggle("Start DiskDrama when I log in", isOn: Binding(
                get: { startAtLogin },
                set: { wanted in
                    startAtLogin = wanted
                    // Reflect what the system actually did, not what was asked
                    // for — a refused registration must not leave the switch on.
                    if !LoginItem.setEnabled(wanted) { startAtLogin = LoginItem.isEnabled }
                }))
            .toggleStyle(.checkbox)
            if LoginItem.needsApproval {
                HStack(spacing: 8) {
                    Text("macOS needs you to confirm this in Login Items before it takes effect.")
                        .settingsCaption()
                    Button("Open Login Items") { LoginItem.openSystemSettings() }
                        .buttonStyle(GhostButtonStyle(height: 24, horizontalPadding: 10, fontSize: 12))
                }
            }
        }
    }

    private var exclusionsSection: some View {
        Section(title: "Never look here",
                blurb: "Skipped entirely — not scanned, not counted, never recommended. "
                     + "Cloud storage starts here because opening a file that hasn't finished "
                     + "downloading can stall a scan for minutes.") {
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
                blurb: "Unreadable locations you've asked DiskDrama to stop naming. They're "
                     + "still missing from every total — the Not scanned pane still counts them.") {
            if model.hiddenBlindSpotPaths.isEmpty {
                Text("Nothing hidden.").settingsCaption()
            } else {
                PathList(paths: Array(model.hiddenBlindSpotPaths).sorted(), emptyNote: "") { path in
                    model.unhideBlindSpot(path: path)
                }
            }
        }
    }

    private var undeletableSection: some View {
        Section(title: "macOS wouldn't let these go",
                blurb: "Deletions the system refused. Remove one to let DiskDrama try again — "
                     + "worth doing after a macOS update.") {
            if model.undeletablePaths.isEmpty {
                Text("Nothing refused.").settingsCaption()
            } else {
                PathList(paths: Array(model.undeletablePaths).sorted(), emptyNote: "") { path in
                    model.forgetUndeletable(path: path)
                }
            }
        }
    }

    private var ignoredSection: some View {
        Section(title: "Never suggest these",
                blurb: "Still scanned and still counted toward your totals — DiskDrama just "
                     + "stops offering them.") {
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
                blurb: "Default selection in cleaning dialogs.") {
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
    /// Optional: a section whose title already says everything needs no
    /// paragraph under it, and an explanatory sentence that explains nothing is
    /// just something else to read past.
    let blurb: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.text)
                if let blurb {
                    Text(blurb)
                        .font(Theme.body(12.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
