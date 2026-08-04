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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    explanationsSection
                    scanRootsSection
                    exclusionsSection
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
            Button("Done") { model.isShowingSettings = false }
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Sections

    private var explanationsSection: some View {
        Section(title: "Deeper explanations",
                blurb: "DiskDrama tiers everything on its own, offline and free. An Anthropic API key "
                     + "lets it also ask Claude for a closer look at whichever item you've selected.") {
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

            Text("Stored in your Keychain, on this Mac only. Only the selected folder's name, size and "
                 + "date are ever sent — never file contents, never the rest of your disk.")
                .settingsCaption()
        }
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
                blurb: "Skipped entirely — not scanned, not counted, not recommended. "
                     + "Their sizes are unknown by design; DiskDrama can't report on a folder it "
                     + "never opens.") {
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
                        Text(PathDisplay.short(path))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
