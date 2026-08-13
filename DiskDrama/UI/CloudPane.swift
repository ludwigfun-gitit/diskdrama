import SwiftUI

/// What iCloud Drive actually costs this Mac, and the one action that reclaims it.
///
/// The scan never goes near these roots — walking a File Provider directory
/// blocks for minutes — so this is the only surface in the app that can answer
/// "how much of my disk is cloud content?". macOS cannot answer it either:
/// Storage Settings reports one figure for iCloud Drive and it counts only
/// *pinned* content, so the cache that actually accumulates appears nowhere.
///
/// **Nothing here is ever deleted.** Removing a download frees the local copy;
/// the file stays in iCloud and returns on demand. Deleting it would remove it
/// from every device on the account, which is why the word does not appear on
/// this screen and why this never routes through the delete sheets.
struct CloudPane: View {

    @Bindable var model: AppModel

    @State private var selectedPath: String?

    private var inventory: CloudInventory? { model.cloudInventory }

    private var folders: [CloudFolder] { inventory?.folders ?? [] }

    private var selected: CloudFolder? {
        folders.first { $0.path == selectedPath } ?? folders.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Cloud downloads", blurb: blurb) {
                Button(model.isReadingCloud ? "Reading" : (inventory == nil ? "Read now" : "Refresh")) {
                    model.refreshCloudInventory()
                }
                .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
                .disabled(model.isReadingCloud)
            }

            if let notice = model.cloudNotice { noticeBar(notice) }

            if inventory == nil {
                unreadState
            } else if folders.isEmpty {
                nothingLocalState
            } else {
                list
                if let folder = selected {
                    CloudDetail(model: model, folder: folder)
                }
            }
        }
        // On demand, per the spec: the scan must not take a dependency on a File
        // Provider's mood. Reading once when the pane is first opened is the
        // compromise — the user asked to look, which is the demand.
        .task {
            if model.cloudInventory == nil { model.refreshCloudInventory() }
        }
    }

    /// Leads with what it costs, not with what exists. The logical figure is
    /// enormous and alarming and almost entirely irrelevant — 190 GB in the
    /// cloud against 0.2 GB on the disk — so it appears only as context for the
    /// number that matters.
    private var blurb: String {
        guard let inventory else {
            return "iCloud Drive is excluded from every scan, because reading one of these folders can stall for minutes. This reads it a different way."
        }
        let local = ByteFormat.compact(inventory.downloadedBytes)
        let cloud = ByteFormat.compact(inventory.logicalBytes)
        return "\(local) of iCloud Drive is stored on this Mac, out of \(cloud) in the cloud. "
             + "Removing a download frees the local copy — the file stays in iCloud and comes back when you open it."
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(Theme.text3)
            Text(text)
                .font(Theme.body(12.5)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { model.cloudNotice = nil }
                .buttonStyle(QuietButtonStyle(height: 24, fontSize: 12))
        }
        .padding(.horizontal, 26).padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if inventory?.pinStateUnavailable == true {
                    HStack {
                        Text("Couldn't read which folders are set to Keep Downloaded, so none are marked below.")
                            .font(Theme.body(12)).foregroundStyle(Theme.text3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.rowPaddingH).padding(.top, 10)
                }
                ForEach(folders, id: \.path) { folder in
                    CloudRow(folder: folder,
                             isSelected: selected?.path == folder.path,
                             action: { selectedPath = folder.path })
                }
                footnote
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Spotlight's index is a floor, and saying so is not optional. A number
    /// presented as a measurement when it is a lower bound is the same class of
    /// mistake as the totals this app already qualifies elsewhere.
    @ViewBuilder
    private var footnote: some View {
        if let inventory {
            Text("Found by asking Spotlight, across \(inventory.fileCount.formatted()) indexed files. Anything Spotlight hasn't indexed isn't counted, so this is a floor.")
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.rowPaddingH)
                .padding(.top, 16)
        }
    }

    private var unreadState: some View {
        VStack(spacing: 7) {
            if model.isReadingCloud {
                ProgressView().controlSize(.small)
                Text("Reading iCloud Drive…").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.text2)
            } else {
                Image(systemName: "cloud").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.text3)
                Text("Not read yet").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.text2)
                Text("This takes a second or two and never opens a file.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nothingLocalState: some View {
        VStack(spacing: 7) {
            Image(systemName: "cloud").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.text3)
            Text("Nothing is stored locally").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.text2)
            Text("Every file in iCloud Drive is a placeholder here, so there's nothing to reclaim.")
                .font(Theme.body(12.5)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct CloudRow: View {
    let folder: CloudFolder
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var name: String {
        PathDisplay.friendlyName(folder.path) ?? (folder.path as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: action) { row }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("\(name), \(ByteFormat.compact(folder.physicalBytes)) on this Mac"
                                + (folder.isKeepDownloaded ? ", kept downloaded" : ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Text(PathDisplay.short(folder.path))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if folder.isKeepDownloaded { RowBadge(text: "Kept downloaded") }
            Text(ByteFormat.compact(folder.physicalBytes))
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, Theme.rowPaddingV)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(isSelected || isHovering ? Theme.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .animation(Theme.transition, value: isSelected)
    }
}


private struct CloudDetail: View {

    @Bindable var model: AppModel
    let folder: CloudFolder

    private var name: String {
        PathDisplay.friendlyName(folder.path) ?? (folder.path as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name).font(Theme.display(15)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(ByteFormat.compact(folder.physicalBytes)) · \(folder.fileCount) file\(folder.fileCount == 1 ? "" : "s") on this Mac")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }

            Text(explanation)
                .font(Theme.body(13)).lineSpacing(3).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Reveal in Finder") { FileActions.revealInFinder(path: folder.path) }
                    .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
                Spacer(minLength: 8)
                // The only action, and it is not deletion. Accent rather than
                // danger: the destructive colour is reserved for operations that
                // lose data, and this one cannot.
                Button("Remove downloads") { model.evictCloud(folders: [folder.path]) }
                    .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 15, fontSize: 12.5))
                    .disabled(model.isReadingCloud)
            }
        }
        .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var explanation: String {
        var text = "Removing these downloads frees \(ByteFormat.compact(folder.physicalBytes)) on this Mac. "
                 + "The files stay in iCloud and download again the next time you open them, which takes time and bandwidth."
        if folder.isKeepDownloaded {
            text += " This folder is set to Keep Downloaded, so iCloud will fetch it all back on its own — "
                  + "turn that off in Finder first, or the space comes straight back."
        }
        return text
    }
}
